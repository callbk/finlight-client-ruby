# frozen_string_literal: true

require "json"

# End-to-end tests of the streaming protocol against an in-process WebSocket
# server, mirroring the Go, .NET and Java clients' coverage.
RSpec.describe "WebSocket protocol" do
  # Keeps reconnect tests quick; mirrors the sibling clients' fast options.
  def fast_options
    { base_reconnect_delay: 0.01, max_reconnect_delay: 0.05, logger: test_logger }
  end

  def config_for(server)
    Finlight::Config.new(api_key: "test-key", wss_url: server.url, timeout: 5)
  end

  def handshake?(message)
    !JSON.parse(message).key?("action")
  end

  def join!(thread)
    thread.join(15) or raise "timed out waiting for the stream to end"
  end

  after { @server&.close }

  it "performs the handshake, deduplicates articles and honors preempt" do
    headers = {}
    handshake = nil
    @server = WsTestServer.new(
      on_open: lambda { |conn|
        headers["x-api-key"] = conn.header("x-api-key")
        headers["x-client-version"] = conn.header("x-client-version")
        headers["x-takeover"] = conn.header("x-takeover")
      },
      on_message: lambda { |conn, message|
        next unless handshake?(message)

        handshake = JSON.parse(message)
        conn.send_text(JSON.generate(
                         action: "admit", leaseId: "lease-1",
                         clientNonce: handshake["clientNonce"]
                       ))
        conn.send_text(WsTestServer.article_message("https://example.com/a"))
        conn.send_text(WsTestServer.article_message("https://example.com/a"))
        conn.send_text(WsTestServer.article_message("https://example.com/b"))
        conn.send_text(JSON.generate(action: "preempted", reason: "test over"))
      }
    )

    client = Finlight::ArticleWebSocketClient.new(
      config_for(@server), takeover: true, **fast_options
    )
    received = []
    join!(client.connect_async(query: "nvidia") { |article| received << article })

    expect(received.map(&:link)).to eq(["https://example.com/a", "https://example.com/b"])
    expect(headers["x-api-key"]).to eq("test-key")
    expect(headers["x-client-version"]).to start_with("ruby/finlight-client@")
    expect(headers["x-takeover"]).to eq("true")
    expect(handshake["query"]).to eq("nvidia")
    expect(handshake["clientNonce"].length).to eq(36)
    expect(@server.errors).to eq([])
  end

  it "does not deduplicate the raw stream and uses the /raw path" do
    @server = WsTestServer.new(
      on_message: lambda { |conn, message|
        next unless handshake?(message)

        conn.send_text(WsTestServer.article_message("https://example.com/a"))
        conn.send_text(WsTestServer.article_message("https://example.com/a"))
        conn.send_text(JSON.generate(action: "preempted", reason: "test over"))
      }
    )

    client = Finlight::RawArticleWebSocketClient.new(config_for(@server), **fast_options)
    received = []
    join!(client.connect_async { |article| received << article })

    expect(received.size).to eq(2)
    expect(@server.resource_paths).to eq(["/raw"])
    expect(@server.errors).to eq([])
  end

  it "stops reconnecting and raises on the blocked close code" do
    @server = WsTestServer.new(
      on_message: lambda { |conn, message|
        conn.close(1008, "blocked") if handshake?(message)
      }
    )

    client = Finlight::ArticleWebSocketClient.new(config_for(@server), **fast_options)
    thread = client.connect_async { |_article| }

    expect { join!(thread) }.to raise_error(Finlight::BlockedError)
  end

  it "reconnects after a server close" do
    @server = WsTestServer.new(
      on_message: lambda { |conn, message|
        next unless handshake?(message)

        if conn.index == 1
          conn.send_text(WsTestServer.article_message("https://example.com/first"))
          conn.close(1000, "server restart")
        else
          conn.send_text(WsTestServer.article_message("https://example.com/second"))
          conn.send_text(JSON.generate(action: "preempted", reason: "test over"))
        end
      }
    )

    client = Finlight::ArticleWebSocketClient.new(config_for(@server), **fast_options)
    received = []
    join!(client.connect_async { |article| received << article })

    expect(received.map(&:link)).to eq(
      ["https://example.com/first", "https://example.com/second"]
    )
    expect(@server.errors).to eq([])
  end

  it "sends application-level pings and handles pongs" do
    ping_time = nil
    @server = WsTestServer.new(
      on_message: lambda { |conn, message|
        msg = JSON.parse(message)
        next unless msg["action"] == "ping"

        ping_time = msg["t"]
        conn.send_text(JSON.generate(action: "pong", t: msg["t"]))
        conn.send_text(JSON.generate(action: "preempted", reason: "test over"))
      }
    )

    client = Finlight::ArticleWebSocketClient.new(
      config_for(@server), ping_interval: 0.1, **fast_options
    )
    join!(client.connect_async { |_article| })

    expect(ping_time).to be > 0
  end

  it "delays the reconnect after an admin kick" do
    open_times = []
    @server = WsTestServer.new(
      on_open: ->(_conn) { open_times << Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      on_message: lambda { |conn, message|
        next unless handshake?(message)

        if conn.index == 1
          conn.send_text(JSON.generate(action: "admin_kick", retryAfter: 400))
        else
          conn.send_text(JSON.generate(action: "preempted", reason: "test over"))
        end
      }
    )

    client = Finlight::ArticleWebSocketClient.new(config_for(@server), **fast_options)
    join!(client.connect_async { |_article| })

    expect(open_times.size).to eq(2)
    gap = open_times[1] - open_times[0]
    expect(gap).to be >= 0.3, "reconnect after admin_kick came too early: #{(gap * 1000).round}ms"
    expect(@server.errors).to eq([])
  end

  it "proactively rotates the connection before the server lifetime cap" do
    # The real client rotates after 115 minutes (2h AWS cap minus margin);
    # replayed here with a tiny connection_lifetime.
    close_events = []
    @server = WsTestServer.new(
      on_message: lambda { |conn, message|
        next unless handshake?(message)

        if conn.index == 1
          conn.send_text(WsTestServer.article_message("https://example.com/before-rotation"))
          # Then stay silent: the client must initiate the rotation itself.
        else
          conn.send_text(WsTestServer.article_message("https://example.com/after-rotation"))
          conn.send_text(JSON.generate(action: "preempted", reason: "test over"))
        end
      },
      on_close: ->(conn, code, reason) { close_events << [conn.index, code, reason] }
    )

    client = Finlight::ArticleWebSocketClient.new(
      config_for(@server), connection_lifetime: 0.3, **fast_options
    )
    received = []
    join!(client.connect_async { |article| received << article })

    expect(received.map(&:link)).to eq(
      ["https://example.com/before-rotation", "https://example.com/after-rotation"]
    )
    expect(close_events).to include([1, 4000, "Proactive rotation"])
    expect(@server.errors).to eq([])
  end

  it "ends the stream on stop" do
    @server = WsTestServer.new(
      on_message: lambda { |conn, message|
        conn.send_text(WsTestServer.article_message("https://example.com/only")) if handshake?(message)
      }
    )

    client = Finlight::ArticleWebSocketClient.new(config_for(@server), **fast_options)
    received = []
    thread = client.connect_async do |article|
      received << article
      client.stop
    end

    join!(thread)
    expect(received.size).to eq(1)
  end
end
