# frozen_string_literal: true

require "openssl"
require "rack"
require "rack/mock"

# R-TEST-1: the five standard examples run against the local mocks.
RSpec.describe "examples" do
  root = File.join(Kit::ROOT, "examples")

  around do |example|
    saved = ENV.to_h.slice("FINLIGHT_API_KEY", "FINLIGHT_BASE_URL", "FINLIGHT_WSS_URL")
    ENV["FINLIGHT_API_KEY"] = "sk_example"
    example.run
  ensure
    %w[FINLIGHT_API_KEY FINLIGHT_BASE_URL FINLIGHT_WSS_URL].each do |k|
      saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k)
    end
  end

  def body_of(name)
    Kit.load("fixtures/requests/#{name}")["response"]["body"]
  end

  def serve_rest
    not_found = Kit.load("fixtures/errors/not-found-id.json")["response"]
    mock_http
      .route(%r{\A/v3/articles/search\z}, { status: 200, body: body_of("search-minimal.json") })
      .route(%r{\A/v3/articles/by-link\z}, { status: 200, body: body_of("get-by-link.json") })
      .route(%r{\A/v3/articles/does-not-exist\z}, { status: 404, headers: not_found["headers"],
                                                    body: not_found["body"] })
      .route(%r{\A/v3/articles/[^/]+\z}, { status: 200, body: body_of("get-by-id.json") })
      .route(%r{\A/v3/companies\z}, { status: 200, body: body_of("companies-search.json") })
      .route(%r{\A/v3/companies/\d+\z}, { status: 200, headers: { "ETag" => '"abc"' },
                                          body: body_of("companies-get.json") })
      .route(%r{\A/v3/sources\z}, { status: 200, body: body_of("sources-list-full.json") })
    ENV["FINLIGHT_BASE_URL"] = mock_http.url
  end

  it "search" do
    serve_rest
    load File.join(root, "search.rb")
    expect { SearchExample.run }.to output(/has more: false/).to_stdout
    expect(JSON.parse(mock_http.requests[0].body))
      .to eq("query" => "ticker:NVDA", "languages" => ["en"], "include" => %w[companies events], "limit" => 10)
  end

  it "search_all" do
    serve_rest
    load File.join(root, "search_all.rb")
    expect { SearchAllExample.run }.to output(/5 articles from 1 pages/).to_stdout
  end

  it "lookup" do
    serve_rest
    load File.join(root, "lookup.rb")
    expect { LookupExample.run }.to output(/by id:.*not found:.*etag: "abc".*3 sources/m).to_stdout
  end

  it "stream" do
    server = WsServer.new
    ENV["FINLIGHT_WSS_URL"] = server.url
    frames = Kit.load("fixtures/requests/ws-subscribe-enriched.json")["server"]["frames"]
    load File.join(root, "stream.rb")
    out = StringIO.new
    runner = Thread.new do
      $stdout = out
      StreamExample.run(max_events: 1)
    ensure
      $stdout = STDOUT
    end
    conn = server.next_connection
    subscribe = conn.recv
    expect(subscribe["payloadVersion"]).to eq(3)
    expect(subscribe["include"]).to eq(["companies"])
    frames.each { |frame| conn.send_frame(frame) }
    expect(runner.join(5)).to be_truthy
    expect(out.string).to include("admitted, lease").and include("created EU8JwpsZ8iJehuyPZjMqRz")
    expect(conn.wait_closed(3)).to be(true)
  ensure
    server&.close
  end

  it "webhook_endpoint (Rack::MockRequest)" do
    load File.join(root, "webhook_endpoint.rb")
    secret = "0123456789abcdef" * 4
    handled = Thread::Queue.new
    app = WebhookEndpoint.new(secret: secret) { |kind, item| handled << [kind, item] }
    request = Rack::MockRequest.new(app)
    post = lambda do |body, good: true|
      ts = FinlightInternal::TimeParse.format(Time.now)
      sig = good ? OpenSSL::HMAC.hexdigest("SHA256", secret, "#{ts}.#{body}") : "0" * 64
      request.post("/hook", input: body, "CONTENT_TYPE" => "application/json",
                            "HTTP_X_WEBHOOK_TIMESTAMP" => ts, "HTTP_X_WEBHOOK_SIGNATURE" => "sha256=#{sig}")
    end
    envelope = { "eventId" => "evt_test0123456789abcdef01", "event" => "article.created",
                 "occurredAt" => "2026-11-23T21:04:05.123Z", "payloadVersion" => 3, "subscriptionId" => "s",
                 "data" => Kit.load("fixtures/decode/full-article.json")["wire"] }
    body = JSON.generate(envelope)
    expect(post.call(body).status).to eq(204)
    expect(post.call(body).status).to eq(204) # duplicate: answered, not processed again
    expect(post.call(JSON.generate({ "link" => "https://x.example/a", "title" => "t" })).status).to eq(204)
    expect(post.call(body, good: false).status).to eq(400)
    kinds = 2.times.map { handled.pop(timeout: 3) }
    expect(kinds.map(&:first)).to eq(%i[event legacy])
    expect(kinds[0][1].test?).to be(true)
    expect(handled.pop(timeout: 0.1)).to be_nil
  end
end
