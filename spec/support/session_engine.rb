# frozen_string_literal: true

# Replays a ws-sessions/*.json fixture against the SDK: server steps are played by an in-process
# WebSocket server, client steps are read from what the SDK really sent, time moves on a fake clock.
#
# Steps the SDK can never produce are not sent (a truncated frame, a legacy key, a re-subscribe on
# the same connection, a ping before the subscribe, a ping on $default); the server answers in the
# fixture still are.
class SessionEngine
  include RSpec::Matchers

  FORBIDDEN = %w[includeContent includeEntities extended].freeze
  ENRICHED_KEYS = %w[include query sources excludeSources optInSources sourceTypes excludeSourceTypes language
                     tickers countries categories excludeEmptyContent includeUpdates].freeze
  RAW_KEYS = %w[query sources excludeSources sourceTypes excludeSourceTypes language includeUpdates].freeze
  DEFAULT_FRAME = { "payloadVersion" => 3, "query" => "ticker:XMPL", "clientNonce" => "c-kit-1" }.freeze
  QUOTA_REFUSAL = [403, '{"message":"WebSocket quota exceeded for the current period"}'].freeze

  attr_reader :stream, :items, :errors, :admitted, :reconnects, :quota_waits, :terminal, :server, :clock

  def initialize(fixture, server, clock)
    @fx = fixture
    @server = server
    @clock = clock
    @raw = fixture["endpoint"] == "raw"
    @steps = fixture["steps"]
    @client_config = fixture.fetch("clientConfig", {})
    @items = Thread::Queue.new
    @errors = []
    @admitted = []
    @admitted_seen = 0
    @reconnects = []
    @quota_waits = []
    @terminal = nil
    @done = false
    @conn = nil
    @subscribed = {}
    @dials_consumed = 0
    first = @steps.find { |s| s["step"] == "clientSends" && subscribe?(s["frame"]) }
    @first_frame = first ? first["frame"] : DEFAULT_FRAME
    server.auto_pong = @steps.none? { |s| s["step"] == "clientSends" && s.key?("match") }
  end

  def done?
    @done
  end

  def subscribe?(frame)
    frame.is_a?(Hash) && frame.key?("payloadVersion") && !frame.key?("action") && !frame.key?("type")
  end

  # The frame the SDK can send for this fixture frame (legacy keys and a raw include cannot be sent).
  def sdk_frame(frame)
    out = frame.except(*FORBIDDEN)
    out.delete("include") if @raw
    out
  end

  def api_key
    dial = @steps.find { |s| s["step"] == "dial" }
    key = dial.fetch("expectRequestHeaders", {})["x-api-key"]
    key.nil? || key.empty? ? Kit::KEY : key
  end

  def start
    allowed = @raw ? RAW_KEYS : ENRICHED_KEYS
    args = @first_frame.slice(*allowed).to_h { |k, v| [Kit.snake(k).to_sym, v] }
    options = { api_key: api_key, base_url: "http://127.0.0.1:9", wss_url: @server.url, clock: @clock }
    options[:quota_reconnect] = @client_config["quotaReconnect"] if @client_config.key?("quotaReconnect")
    client = Finlight::Client.new(**options)
    hooks = {
      on_admitted: ->(info) { @admitted << info },
      on_error: ->(error) { @errors << error },
      on_reconnect: ->(info) { @reconnects << info },
      on_quota_wait: ->(info) { @quota_waits << info }
    }
    @stream = @raw ? client.raw_stream(**args, **hooks) : client.stream(**args, **hooks)
    nonce = @first_frame.fetch("clientNonce", "c-kit-1")
    @stream.instance_variable_set(:@nonce_factory, -> { nonce })
    @consumer = Thread.new do
      @stream.each { |event| @items << event }
    rescue StandardError => e
      @terminal = e
    ensure
      @done = true
    end
  end

  def close
    @stream&.close
    @consumer&.join(5)
  end

  def run
    @steps.each_with_index do |step, index|
      public_send(:"step_#{step["step"]}", step, @steps[(index + 1)..])
    end
  end

  # -- helpers ---------------------------------------------------------------------

  def wait(what, timeout: 3, &block)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until block.call
      raise "timed out waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.002
    end
  end

  def settle(seconds = 0.05)
    sleep seconds
  end

  # Moves fake time until the client dials again; returns the fake seconds waited.
  def wait_for_dial(before, max_fake: 4000.0)
    20.times do
      return 0.0 if @server.dial_count > before

      sleep 0.002
    end
    waited = 0.0
    while @server.dial_count <= before
      raise "client did not dial again" if waited > max_fake

      deadline = @clock.next_deadline
      step = deadline ? [deadline - @clock.now, 0.001].max : 0.5
      @clock.advance(step)
      waited += step
      10.times do
        break if @server.dial_count > before

        sleep 0.002
      end
    end
    waited
  end

  def session_last_pong
    sessions = @stream.instance_variable_get(:@sessions)
    sessions.last&.last_pong
  end

  # -- steps -----------------------------------------------------------------------

  def step_dial(step, _rest)
    status = step["server"]["status"]
    @server.plan(status == 101 ? nil : [status, step["server"].fetch("body", "")])
    start if @stream.nil?
    wait_for_dial(@dials_consumed)
    dial = @server.dials[@dials_consumed]
    @dials_consumed += 1
    expect(dial[:path]).to eq(@raw ? "/raw" : "/")
    names = dial[:headers].map(&:first)
    expect(names).to include("x-api-key") # exactly lowercase
    expect(dial[:request_line]).not_to include("apiKey")
    step.fetch("expectRequestHeaders", {}).each do |name, value|
      value = Kit::KEY if name == "x-api-key" && value.empty?
      expect(dial[:headers].to_h[name]).to eq(value)
    end
    expect(dial[:headers].to_h["x-client-version"]).to eq(Finlight::VERSION)
    @conn = @server.next_connection if status == 101
  end

  def step_clientSends(step, _rest)
    if step.key?("match")
      loop do
        message = @conn.recv(skip_pings: false)
        next unless message.is_a?(Hash) && step["match"].all? { |k, v| message[k] == v }

        expect(message["t"]).to be_a(Integer)
        return
      end
    end
    frame = step["frame"]
    return unless subscribe?(frame) # truncated frame, keep-alive ping, ping on $default: not sent by the SDK
    return if @subscribed[@conn] # a re-subscribe on the same connection: the SDK never sends one

    got = @conn.recv
    expect(got).to eq(sdk_frame(frame))
    expect(got["payloadVersion"]).to be_an(Integer).and eq(3)
    expect(got.keys & FORBIDDEN).to eq([])
    @subscribed[@conn] = true
  end

  def step_serverSends(step, _rest)
    frame = step["frame"]
    @clock.advance(1.0) if frame["action"] == "pong" || frame["event"] == "connection.pong"
    @conn.send_frame(frame)
    settle(0.02)
  end

  def step_serverCloses(_step, _rest)
    @conn.close(1001)
    settle(0.02)
  end

  def step_advance(step, _rest)
    @clock.advance(step["ms"] / 1000.0) { await_pongs if @server.auto_pong }
  end

  # With the server answering pings, wait until each answer reached the client before time moves on.
  def await_pongs
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
    loop do
      sessions = @stream.instance_variable_get(:@sessions)
      pending = sessions.any? { |s| s.last_pong < s.instance_variable_get(:@last_ping) && !s.retiring }
      break unless pending && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

      sleep 0.0005
    end
  end

  def step_expect(step, rest)
    public_send(:"expect_#{step["outcome"]}", step, rest)
  end

  # -- expectations ----------------------------------------------------------------

  def expect_admitted(step, _rest)
    wait("connection.admitted") { @admitted.size > @admitted_seen }
    info = @admitted[@admitted_seen]
    @admitted_seen += 1
    expect(info).to be_a(Finlight::AdmittedInfo)
    expect(info.server_now).to be_an(Integer)
    expect(info.client_nonce).to eq(step["clientNonce"]) if step.key?("clientNonce")
    expect(info.lease_id).to eq(step["leaseId"]) if step.key?("leaseId")
  end

  def expect_noAdmitted(_step, _rest)
    settle
    expect(@admitted.size).to eq(@admitted_seen)
    expect(@terminal).to be_nil
    expect(@done).to be(false)
  end

  def expect_item(step, _rest)
    event = @items.pop(timeout: 3)
    raise "timed out waiting for an item" if event.nil?

    expect(event).to be_a(Finlight::StreamEvent)
    expect(event.kind).to eq(step["kind"])
    expect(event.data).to be_a(Finlight::Article)
    expect(event.data.id).to eq(step["id"]) if step.key?("id")
    expect(event.raw_json["data"]["id"]).to eq(event.data.id)
    return unless @raw

    article = event.data
    expect(article.available_at).to be_nil
    expect([article.content_present?, article.sentiment_present?, article.companies_present?,
            article.events_present?]).to eq([false, false, false, false])
  end

  def expect_duplicateDropped(_step, _rest)
    settle
    expect(@items.empty?).to be(true)
  end

  def expect_logOnly(step, _rest)
    dials = @server.dial_count
    wait("the reported error") { @errors.any? { |e| e.respond_to?(:code) && e.code == step["code"] } } if
      step.key?("code")
    settle
    expect(@terminal).to be_nil
    expect(@done).to be(false)
    until @items.empty?
      other = @items.pop
      expect(other.kind).to eq("other") # unknown events surface as "other"
      expect(other.data).to be_nil
      expect(other.raw_json["event"]).to eq(other.event)
    end
    expect(@server.dial_count).to eq(dials)
  end

  def expect_liveness(_step, _rest)
    wait("the pong to refresh the watchdog") { session_last_pong == @clock.now }
    expect(@terminal).to be_nil
  end

  def expect_terminalError(step, _rest)
    wait("the stream to end", timeout: 5) { @done }
    error = @terminal
    case step["error"]
    when "FinlightApiError"
      expect(error).to be_a(Finlight::ApiError)
      expect(error.api_kind).to eq(step["apiKind"])
      expect(error.status).to eq(step["status"]) if step.key?("status")
      expect(error.code).to eq(step["code"]) if step.key?("code")
      expect(error).to be_a(Finlight::UnauthorizedError) if step["apiKind"] == "unauthorized"
      expect(error).to be_a(Finlight::ForbiddenError) if step["apiKind"] == "forbidden"
      if step["apiKind"] == "validation_failed"
        expect(error).to be_a(Finlight::ValidationFailedError)
        expect(error.errors).not_to be_empty
        expect(error.errors[0].field).to be_a(String)
        expect(error.errors[0].constraints).to be_a(Hash)
        expect(error.errors[0].issue).to be_a(String)
      end
    when "PreemptedError"
      expect(error).to be_a(Finlight::PreemptedError)
      expect(error.reason).to eq(step["reason"])
      expect(error.new_lease_id).to eq(step["newLeaseId"])
    else raise "unknown terminal error #{step["error"]}"
    end
  end

  def check_quota_report(want, attempt)
    wait("the quota report") { @quota_waits.size >= attempt }
    info = @quota_waits[attempt - 1]
    expect(info).to be_a(Finlight::QuotaWaitInfo)
    expect(info.attempt).to eq(attempt)
    expect(info.next_attempt_in).to eq(3600.0)
    case want["error"]
    when "PreemptedError"
      expect(info.error).to be_a(Finlight::PreemptedError)
      expect(info.error.reason).to eq(want["reason"])
      expect(info.error.new_lease_id).to eq(want["newLeaseId"])
    when "FinlightApiError"
      expect(info.error).to be_a(Finlight::ForbiddenError)
      expect(info.error.api_kind).to eq(want["apiKind"])
      expect(info.error.status).to eq(want["status"])
    end
    # A quota wait goes only to on_quota_wait, never to on_error.
    expect(@errors.grep(Finlight::PreemptedError)).to eq([])
    expect(@errors.select { |e| e.is_a?(Finlight::ApiError) && e.detail.to_s.start_with?("WebSocket quota") }).to eq([])
  end

  def expect_reported(step, _rest)
    expect(step["hook"]).to eq("onQuotaWait")
    check_quota_report(step, step.fetch("attempt", 1))
    expect(@terminal).to be_nil
    expect(@done).to be(false)
  end

  def expect_noReconnect(_step, _rest)
    dials = @server.dial_count
    if @done
      @clock.advance(120.0) # after a terminal error nothing may dial again
    else
      settle
    end
    expect(@server.dial_count).to eq(dials)
  end

  def expect_reconnect(step, rest)
    expect(@terminal).to be_nil
    check_quota_report(step["reported"], step["reported"].fetch("attempt", 1)) if step.key?("reported")
    return if rest.first && rest.first["step"] == "dial" # the next dial step waits for the new connection

    before = @dials_consumed
    if %w[long quota].include?(step["backoff"])
      minimum = step.fetch("firstRetryMinMs", 60_000) / 1000.0
      expect(@server.dial_count).to eq(before)
      @clock.advance(minimum - 0.001)
      settle(0.02)
      expect(@server.dial_count).to eq(before), "redialed before the minimum wait"
    end
    wait_for_dial(before)
    @dials_consumed = before + 1
    wait("the takeover hint") { @errors.any? { |e| e.message.include?("takeover") } } if step["hint"] == "takeover"
    if step["resubscribe"]
      @conn = @server.next_connection
      expect(@conn.recv).to eq(sdk_frame(@first_frame))
      @subscribed[@conn] = true
    end
    if step.key?("reason")
      wait("the reconnect hook") { @reconnects.any? }
      expect(@reconnects.last.reason).to eq(step["reason"])
    end
    search_failed_until(step["surfaceAfterConsecutive"]) if step.key?("surfaceAfterConsecutive")
  end

  # S-14: SEARCH_FAILED goes to on_error only after `threshold` failures in a row.
  def search_failed_until(threshold)
    surfaced = -> { @errors.count { |e| e.respond_to?(:code) && e.code == "SEARCH_FAILED" } }
    expect(surfaced.call).to eq(0)
    (2..threshold).each do |n|
      @conn.send_frame({ "event" => "connection.admitted", "payloadVersion" => 3,
                         "data" => { "leaseId" => "l", "serverNow" => 1, "clientNonce" => "c-kit-1" } })
      @conn.send_frame({ "event" => "connection.error", "payloadVersion" => 3,
                         "data" => { "code" => "SEARCH_FAILED", "message" => "Search temporarily unavailable" } })
      @conn.close(1001)
      if n == threshold
        wait("SEARCH_FAILED on on_error") { surfaced.call == 1 }
      else
        settle(0.02)
        expect(surfaced.call).to eq(0)
      end
      before = @dials_consumed
      wait_for_dial(before)
      @dials_consumed = before + 1
      @conn = @server.next_connection
      @conn.recv
    end
    expect(@terminal).to be_nil
  end
end
