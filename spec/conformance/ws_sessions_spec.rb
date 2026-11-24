# frozen_string_literal: true

RSpec.describe "Conformance S: WebSocket sessions" do
  let(:server) { WsServer.new }
  let(:clock) { FakeClock.new }

  after do
    server.close
  end

  def run_session(name)
    engine = SessionEngine.new(Kit.load("ws-sessions/#{name}"), server, clock)
    begin
      engine.run
    ensure
      engine.close
    end
    # Stopping leaves nothing behind: no socket, no timer, no background thread.
    wait_until("background threads to end") { finlight_threads.empty? }
    expect(engine.stream.closed?).to be(true)
    engine
  end

  Kit.fixtures("ws-sessions").each do |id, name|
    it "#{id} #{Kit.case_titles[id]}", kit_case: id do
      engine = run_session(name)
      case id
      when "S-18"
        expect(engine.reconnects.last.reason).to eq("rotation")
        expect(engine.reconnects.last.connection).to eq(2)
        old = server.all[0]
        new = server.all[1]
        expect(old.wait_closed(5)).to be(true) # the old connection closes after the new one subscribed
        expect(new).not_to equal(old)
        expect(engine.items.empty?).to be(true)
      when "S-16"
        expect(engine.reconnects.last.reason).to eq("watchdog")
      when "S-10"
        expect(engine.reconnects.last.reason).to eq("quota_exceeded")
      end
    end
  end

  it "S-10 keeps waiting hour by hour while the quota is still exhausted", kit_case: "S-10" do
    engine = SessionEngine.new(Kit.load("ws-sessions/preempted-quota-exceeded.json"), server, clock)
    begin
      fx_steps = Kit.load("ws-sessions/preempted-quota-exceeded.json")["steps"]
      # Play the fixture up to the first report.
      fx_steps.take_while { |s| s["outcome"] != "reported" }.each_with_index do |step, i|
        engine.public_send(:"step_#{step["step"]}", step, fx_steps[(i + 1)..])
      end
      engine.check_quota_report({ "error" => "PreemptedError", "reason" => "quota_exceeded", "newLeaseId" => nil }, 1)
      [2, 3].each do |attempt|
        server.plan(SessionEngine::QUOTA_REFUSAL)
        before = server.dial_count
        clock.advance(3599.0)
        sleep 0.02
        expect(server.dial_count).to eq(before)
        clock.advance(1.0)
        wait_until("the hourly dial") { server.dial_count > before }
        engine.check_quota_report({ "error" => "FinlightApiError", "apiKind" => "forbidden", "status" => 403 },
                                  attempt)
        expect(engine.done?).to be(false)
      end
      before = server.dial_count
      clock.advance(3600.0) # the quota is back: accepted, the same subscribe again
      wait_until("the dial after the quota came back") { server.dial_count > before }
      conn = server.next_connection
      expect(conn.recv).to eq(engine.sdk_frame(SessionEngine::DEFAULT_FRAME.merge(
                                                 "include" => %w[companies
                                                                 events], "language" => "en", "includeUpdates" => true
                                               )))
    ensure
      engine.close
    end
  end

  def run_subscribe_fixture(name, raw:)
    fx = Kit.load("fixtures/requests/#{name}")
    nonce = fx["frame"]["clientNonce"]
    client = Finlight::Client.new(api_key: Kit::KEY, wss_url: server.url, clock: clock)
    admitted = []
    errors = []
    args = Kit.snake_args(fx["sdk"]["args"])
    hooks = { on_admitted: ->(i) { admitted << i }, on_error: ->(e) { errors << e } }
    stream = raw ? client.raw_stream(**args, **hooks) : client.stream(**args, **hooks)
    stream.instance_variable_set(:@nonce_factory, -> { nonce })
    items = Thread::Queue.new
    consumer = Thread.new { stream.each { |e| items << e } }
    begin
      conn = server.next_connection
      text = conn.inbox.pop(timeout: 3)
      got = JSON.parse(text)
      expect(got).to eq(fx["frame"]) # exactly this object (key order free)
      expect(got["payloadVersion"]).to be_an(Integer)
      expect(got).not_to have_key("action")
      fx["server"]["frames"].each { |frame| conn.send_frame(frame) }
      wait_until("connection.admitted") { admitted.size == 1 }
      sleep 0.05
      expect(admitted[0].client_nonce).to eq(nonce)
      expect(errors).to eq([])
      if raw
        expect(items.empty?).to be(true)
      else
        event = items.pop(timeout: 3)
        expect([event.kind, event.data.id]).to eq(["created", fx["server"]["frames"][1]["data"]["id"]])
      end
    ensure
      stream.close
      consumer.join(5)
    end
  end

  it "R-13 #{Kit.case_titles["R-13"]}", kit_case: "R-13" do
    run_subscribe_fixture("ws-subscribe-enriched.json", raw: false)
  end

  it "R-14 #{Kit.case_titles["R-14"]}", kit_case: "R-14" do
    run_subscribe_fixture("ws-subscribe-raw.json", raw: true)
  end
end
