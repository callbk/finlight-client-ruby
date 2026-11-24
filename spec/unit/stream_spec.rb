# frozen_string_literal: true

RSpec.describe "streams" do
  let(:server) { WsServer.new }
  let(:clock) { FakeClock.new }
  let(:article) { Kit.load("fixtures/decode/full-article.json")["wire"] }
  let(:raw_article) { Kit.load("fixtures/decode/raw-skeleton.json")["wire"] }
  let(:admitted_frame) do
    { "event" => "connection.admitted", "payloadVersion" => 3,
      "data" => { "leaseId" => "l", "serverNow" => 1, "clientNonce" => "n" } }
  end

  after do
    server.close
    wait_until("background threads to end") { finlight_threads.empty? }
  end

  def client(**options)
    Finlight::Client.new(api_key: Kit::KEY, wss_url: server.url, clock: clock, **options)
  end

  # Runs the stream on a thread; returns [stream, items queue, thread]. The thread's value is the
  # terminal error (or nil).
  def consume(stream)
    items = Thread::Queue.new
    thread = Thread.new do
      stream.each { |event| items << event }
      nil
    rescue StandardError => e
      e
    end
    [items, thread]
  end

  it "uses the contract defaults: ping 25 s, watchdog 60 s, rotation 115 min (R-WS-4)" do
    config = Finlight::Config.new(api_key: "k")
    expect([config.ping_interval, config.watchdog_timeout, config.rotation_interval]).to eq([25.0, 60.0, 6900.0])
    expect(config.max_message_bytes).to be >= 16 * 1024 * 1024
    expect(config.dedupe_cache_size).to eq(1000)
    expect(config.quota_reconnect).to be(true)
    expect(config.quota_reconnect_interval).to eq(3600.0)
  end

  it "can be iterated once; leaving the loop closes the socket with 1000 and stops every thread" do
    stream = client.stream(query: "x")
    received = []
    thread = Thread.new do
      stream.each do |event|
        received << event
        break
      end
    end
    conn = server.next_connection
    conn.recv
    conn.send_frame(admitted_frame)
    conn.send_frame({ "event" => "article.created", "payloadVersion" => 3, "data" => article })
    thread.join(3)
    expect(received.size).to eq(1)
    expect(conn.wait_closed(3)).to be(true)
    expect(stream.closed?).to be(true)
    wait_until("threads to end") { finlight_threads.empty? }
    expect(clock.pending).to eq(0)
    expect { stream.each { nil } }.to raise_error(Finlight::ValidationError)
  end

  it "close from another thread ends the iteration" do
    stream = client.stream(query: "x")
    _items, thread = consume(stream)
    server.next_connection.recv
    stream.close
    expect(thread.join(3)).to be_truthy
    expect(thread.value).to be_nil
  end

  it "keeps running when a hook raises, and logs it" do
    log = StringIO.new
    stream = client(logger: Logger.new(log)).stream(query: "x", on_admitted: ->(_) { raise "hook bug" })
    items, thread = consume(stream)
    conn = server.next_connection
    conn.recv
    conn.send_frame(admitted_frame)
    conn.send_frame({ "event" => "article.created", "payloadVersion" => 3, "data" => article })
    expect(items.pop(timeout: 3).data.id).to eq(article["id"])
    expect(log.string).to include("on_admitted raised RuntimeError")
    stream.close
    thread.join(3)
  end

  it "passes firstSeenAt on raw reconnects and drops the replayed initial push (R-WS-5, R-WS-6)" do
    reconnects = []
    stream = client.raw_stream(query: "x", on_reconnect: ->(info) { reconnects << info })
    items, thread = consume(stream)
    conn = server.next_connection
    expect(conn.recv).not_to have_key("include")
    expect(conn.path).to eq("/raw")
    conn.send_frame(admitted_frame)
    conn.send_frame({ "event" => "article.created", "payloadVersion" => 3, "data" => raw_article })
    expect(items.pop(timeout: 3).kind).to eq("created")
    conn.close(1001) # an unexpected close: reconnect
    wait_until("the redial") { server.dial_count == 2 || clock.next_deadline }
    clock.advance(clock.next_deadline - clock.now) if server.dial_count < 2
    conn2 = server.next_connection
    conn2.recv
    conn2.send_frame({ "event" => "article.created", "payloadVersion" => 3, "data" => raw_article })
    conn2.send_frame({ "event" => "article.updated", "payloadVersion" => 3, "data" => raw_article })
    expect(items.pop(timeout: 3).kind).to eq("updated") # the replayed created was dropped
    expect(reconnects.size).to eq(1)
    expect(reconnects[0].reason).to eq("closed")
    expect(reconnects[0].last_seen_at).to eq(raw_article["firstSeenAt"])
    expect(stream.last_seen_at).to eq(raw_article["firstSeenAt"])
    stream.close
    thread.join(3)
  end

  it "uses availableAt, else firstSeenAt, as last_seen_at on enriched streams" do
    stream = client.stream(query: "x")
    items, thread = consume(stream)
    conn = server.next_connection
    conn.recv
    conn.send_frame({ "event" => "article.created", "payloadVersion" => 3, "data" => article })
    items.pop(timeout: 3)
    expect(stream.last_seen_at).to eq(article["availableAt"])
    stream.close
    thread.join(3)
  end

  it "ends with ApiError on close code 1008" do
    stream = client.stream(query: "x")
    _items, thread = consume(stream)
    conn = server.next_connection
    conn.recv
    conn.close(1008)
    error = thread.value
    expect(error).to be_a(Finlight::ApiError)
    expect(error.message).to include("1008")
  end

  it "treats a 401 without body as terminal and a 403 without body as a long wait plus a report (R-WS-2)" do
    server.plan([401, ""])
    _items, thread = consume(client.stream(query: "x"))
    expect(thread.value).to be_a(Finlight::UnauthorizedError)

    errors = []
    server.plan([403, ""])
    stream = client.stream(query: "x", on_error: ->(e) { errors << e })
    _items, thread = consume(stream)
    wait_until("the report") { errors.any? }
    expect(errors[0]).to be_a(Finlight::ForbiddenError)
    dials = server.dial_count
    clock.advance(59.9)
    sleep 0.02
    expect(server.dial_count).to eq(dials)
    stream.close
    thread.join(3)
  end

  it "reports a dial 429 and waits at least 60 s" do
    errors = []
    reconnects = []
    server.plan([429, '{"message":"Too Many Requests"}'])
    stream = client.stream(query: "x", on_error: ->(e) { errors << e }, on_reconnect: ->(i) { reconnects << i })
    _items, thread = consume(stream)
    wait_until("the report") { errors.any? }
    expect(errors[0]).to be_a(Finlight::RateLimitedError)
    clock.advance(59.9)
    sleep 0.02
    expect(server.dial_count).to eq(1)
    clock.advance(clock.next_deadline - clock.now)
    server.next_connection.recv
    sleep 0.05
    expect(reconnects).to eq([]) # the first connection is no reconnect, even after a refused dial
    stream.close
    thread.join(3)
  end

  it "fires on_reconnect only after the first connection and keeps the dial reason (sdk-style 6.1)" do
    reconnects = []
    server.plan([503, ""])
    stream = client.stream(query: "x", on_reconnect: ->(i) { reconnects << i })
    _items, thread = consume(stream)
    wait_until("the redial wait") { clock.next_deadline }
    clock.advance(clock.next_deadline - clock.now)
    conn = server.next_connection
    conn.recv
    conn.send_frame(admitted_frame)
    sleep 0.05
    expect(reconnects).to eq([]) # first dial refused, then admitted: no on_reconnect

    server.plan([429, '{"message":"Too Many Requests"}'])
    conn.close(1001)
    wait_until("the 429 dial") { server.dial_count == 3 || clock.next_deadline }
    clock.advance(clock.next_deadline - clock.now) if server.dial_count < 3
    wait_until("the 429 dial") { server.dial_count == 3 }
    wait_until("the long wait") { clock.next_deadline }
    clock.advance(clock.next_deadline - clock.now)
    server.next_connection.recv
    wait_until("the reconnect hook") { reconnects.any? }
    expect(reconnects.map { |i| [i.reason, i.connection] }).to eq([["rate_limited", 2]])
    stream.close
    thread.join(3)
  end

  it "delivers the raw frame of unknown events as kind other" do
    stream = client.stream(query: "x")
    items, thread = consume(stream)
    conn = server.next_connection
    conn.recv
    conn.send_frame({ "event" => "connection.draining", "payloadVersion" => 3, "data" => { "inMs" => 1 } })
    conn.send_frame({ "action" => "sendArticle", "data" => { "link" => "x" } }) # v2: never an article
    conn.send_frame({ "event" => "article.created", "payloadVersion" => 3, "data" => article })
    other = items.pop(timeout: 3)
    expect([other.kind, other.event, other.data]).to eq(["other", "connection.draining", nil])
    expect(other.raw_json["data"]).to eq({ "inMs" => 1 })
    expect(items.pop(timeout: 3).kind).to eq("created")
    stream.close
    thread.join(3)
  end

  it "closes the socket of a dial that is still waiting for the upgrade answer when the stream closes (R-WS-6)" do
    listener = TCPServer.new("127.0.0.1", 0)
    stream = Finlight::Client.new(api_key: Kit::KEY, wss_url: "ws://127.0.0.1:#{listener.addr[1]}", clock: clock,
                                  connect_timeout: 30).stream(query: "x")
    _items, thread = consume(stream)
    socket = listener.accept # the upgrade request arrives, the answer never comes
    stream.close
    thread.join(3)
    eof = false
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    until eof || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      begin
        socket.read_nonblock(4096) # drain the upgrade request
      rescue IO::WaitReadable
        socket.wait_readable(0.1)
      rescue EOFError, Errno::ECONNRESET
        eof = true
      end
    end
    expect(eof).to be(true)
  ensure
    socket&.close
    listener&.close
  end

  it "runs several streams of one client at once, and client.close stops them" do
    c = client
    streams = [c.stream(query: "a"), c.raw_stream(query: "b")]
    threads = streams.map { |s| consume(s)[1] }
    2.times { server.next_connection.recv }
    c.close
    threads.each { |t| expect(t.join(3)).to be_truthy }
    expect(streams.map(&:closed?)).to eq([true, true])
  end
end
