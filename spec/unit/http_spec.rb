# frozen_string_literal: true

require "socket"

RSpec.describe "REST transport, errors and retries" do
  let(:problem) { { "content-type" => "application/problem+json" } }

  def rate_limited(body_extra, headers = {})
    { status: 429, headers: problem.merge(headers),
      body: { "type" => "https://docs.finlight.me/errors/rate-limited", "title" => "Too many requests",
              "status" => 429, "code" => "RATE_LIMITED", "requestId" => "r" }.merge(body_extra) }
  end

  it "sorts every 429 at one place: limitType first, then the exact detail text (R-ERR-1)" do
    cases = [
      [{ "limitType" => "monthly", "detail" => "Exceeded rate limit" }, "monthly"],
      [{ "limitType" => "burst", "detail" => "x" }, "burst"],
      [{ "detail" => "Throttling Exception: Exceeded token limit of 1000" }, "monthly"],
      [{ "detail" => "Throttling Exception: Exceeded rate limit of 5 requests" }, "burst"],
      [{ "detail" => "exceeded rate limit" }, "unknown"]
    ]
    cases.each do |extra, want|
      body = JSON.generate({ "code" => "RATE_LIMITED", "type" => "t" }.merge(extra))
      error = FinlightInternal::ErrorParser.from_response(429, "application/problem+json", body, sent_request_id: "x")
      expect(error).to be_a(Finlight::RateLimitedError)
      expect(error.limit_type).to eq(want), extra.inspect
    end
  end

  it "reads the NestJS form with a String array message" do
    error = FinlightInternal::ErrorParser.from_response(
      400, "application/json", '{"statusCode":400,"message":["a is wrong","b is wrong"],"error":"Bad Request"}',
      sent_request_id: "sent-id"
    )
    expect(error).to be_a(Finlight::ValidationFailedError)
    expect(error.detail).to eq("a is wrong; b is wrong")
    expect(error.errors.map(&:issue)).to eq(["a is wrong", "b is wrong"])
    expect(error.request_id).to eq("sent-id")
    expect(error.code).to be_nil
  end

  it "never retries an unknown 429 and never waits on a monthly one" do
    mock_http.respond(rate_limited({ "detail" => "something else" }))
    expect { rest_client.articles.search }.to raise_error(Finlight::RateLimitedError) { |e|
      expect(e.limit_type).to eq("unknown")
    }
    expect(mock_http.requests.size).to eq(1)
    expect(recording_clock.sleeps).to eq([])
  end

  it "keeps the X-Request-Id across retries and uses a new one per call" do
    mock_http.respond({ status: 503, body: "busy" }, { status: 200, body: { "sources" => [] } })
    rest_client.sources.list
    ids = mock_http.requests.map { |r| r.header("X-Request-Id") }
    expect(ids.size).to eq(2)
    expect(ids.uniq.size).to eq(1)
    mock_http.reset
    mock_http.respond({ status: 200, body: { "sources" => [] } })
    rest_client.sources.list
    expect(mock_http.requests[0].header("X-Request-Id")).not_to eq(ids[0])
  end

  it "retries network errors up to max_retries and wraps them, keeping the cause" do
    port = TCPServer.new("127.0.0.1", 0).then do |s|
      p = s.addr[1]
      s.close
      p
    end
    client = rest_client(base_url: "http://127.0.0.1:#{port}", max_retries: 2)
    expect { client.sources.list }.to raise_error(Finlight::NetworkError) { |e|
      expect(e.kind).to eq("network")
      expect(e.cause).to be_a(SystemCallError)
    }
    expect(recording_clock.sleeps.size).to eq(2)
  end

  it "reports a timeout as TimeoutError, a NetworkError" do
    listener = TCPServer.new("127.0.0.1", 0)
    client = rest_client(base_url: "http://127.0.0.1:#{listener.addr[1]}", timeout: 0.2, max_retries: 0)
    expect { client.sources.list }.to raise_error(Finlight::TimeoutError) { |e|
      expect(e).to be_a(Finlight::NetworkError)
      expect(e.kind).to eq("timeout")
    }
  ensure
    listener&.close
  end

  it "passes a caller Timeout.timeout(x, Timeout::Error) through unchanged after one attempt (R-RETRY-1)" do
    listener = TCPServer.new("127.0.0.1", 0)
    accepted = Queue.new
    acceptor = Thread.new do
      loop { accepted << listener.accept }
    rescue IOError
      nil
    end
    client = rest_client(base_url: "http://127.0.0.1:#{listener.addr[1]}", timeout: 5, max_retries: 3)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { Timeout.timeout(0.3, Timeout::Error) { client.articles.search(query: "x") } }
      .to raise_error(Timeout::Error) { |e| expect(e).not_to be_a(Finlight::Error) }
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
    expect(accepted.size).to eq(1)
    expect(recording_clock.sleeps).to eq([])
  ensure
    listener&.close
    acceptor&.join(1)
    acceptor&.kill
    accepted&.size&.times { accepted.pop.close }
  end

  it "passes a caller Timeout::Error raised inside an injected HTTP client through unchanged" do
    calls = 0
    fake = lambda do |*|
      calls += 1
      raise Timeout::Error, "caller abort"
    end
    client = Finlight::Client.new(api_key: "k", http_client: fake, clock: recording_clock, max_retries: 3)
    expect { client.sources.list }.to raise_error(Timeout::Error, "caller abort")
    expect(calls).to eq(1)
  end

  it "stops at total_timeout, burst wait included" do
    mock_http.respond(rate_limited({ "limitType" => "burst" }, "retry-after" => "9"))
    expect { rest_client(total_timeout: 5).articles.search }.to raise_error(Finlight::RateLimitedError)
    expect(recording_clock.sleeps).to eq([])
  end

  it "ends a burst wait at once when the caller cancels the thread, and does not retry" do
    mock_http.respond(rate_limited({ "limitType" => "burst" }, "retry-after" => "30"))
    client = Finlight::Client.new(api_key: Kit::KEY, base_url: mock_http.url) # system clock: a real wait
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    worker = Thread.new do
      client.articles.search
    rescue Interrupt => e
      e
    end
    wait_until("the first attempt") { mock_http.requests.size == 1 }
    sleep 0.05
    worker.raise(Interrupt)
    expect(worker.value).to be_a(Interrupt)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
    expect(mock_http.requests.size).to eq(1)
  end

  it "caps the response size" do
    mock_http.respond({ status: 200, body: "x" * 5000 })
    expect { rest_client(max_response_bytes: 1000).sources.list }.to raise_error(Finlight::DecodeError)
  end

  it "joins base URLs with or without a trailing slash (R-CONFIG-1)" do
    mock_http.respond({ status: 200, body: { "sources" => [] } })
    rest_client(base_url: "#{mock_http.url}/").sources.list
    rest_client(base_url: "#{mock_http.url}//").sources.list
    expect(mock_http.requests.map(&:path)).to eq(%w[/v3/sources /v3/sources])
  end

  it "uses an injected HTTP client and wraps its errors" do
    calls = []
    fake = lambda do |method, url, headers, body|
      calls << [method, url, headers, body]
      [200, { "Content-Type" => "application/json" }, '{"sources":[{"domain":"a.example"}]}']
    end
    list = Finlight::Client.new(api_key: "k", http_client: fake).sources.list
    expect(list.map(&:domain)).to eq(["a.example"])
    expect(calls[0][0..1]).to eq(["GET", "https://api.finlight.me/v3/sources"])
    expect(calls[0][2]["User-Agent"]).to eq("finlight-client-ruby/#{Finlight::VERSION}")
    broken = ->(*) { raise IOError, "boom" }
    client = Finlight::Client.new(api_key: "k", http_client: broken, max_retries: 0)
    expect { client.sources.list }.to raise_error(Finlight::NetworkError) { |e| expect(e.cause).to be_a(IOError) }
  end

  it "skips a broken list entry, logs it and keeps it in skipped (R-MODELS-1)" do
    log = StringIO.new
    full = Kit.load("fixtures/decode/full-article.json")["wire"]
    broken = full.merge("title" => nil)
    mock_http.respond({ status: 200, body: { "articles" => [full, broken, full.merge("id" => "other")],
                                             "pagination" => { "limit" => 3, "returned" => 3, "hasMore" => false,
                                                               "nextCursor" => nil } } })
    page = rest_client(logger: Logger.new(log)).articles.search
    expect(page.articles.map(&:id)).to eq([full["id"], "other"])
    expect(page.skipped.size).to eq(1)
    expect(page.skipped[0].index).to eq(1)
    expect(page.skipped[0].raw["title"]).to be_nil
    expect(page.skipped[0].reason).to include("$.articles[1].title")
    expect(log.string).to include("WARN")
  end

  it "fails a single lookup without link with DecodeError" do
    full = Kit.load("fixtures/decode/full-article.json")["wire"]
    mock_http.respond({ status: 200, body: { "article" => full.except("link") } })
    expect { rest_client.articles.get("x") }.to raise_error(Finlight::DecodeError) { |e|
      expect(e.path).to eq("$.article.link")
      expect(e.kind).to eq("decode")
    }
  end

  it "treats a 404 on lookups as NotFoundError, not an empty result" do
    fx = Kit.load("fixtures/errors/not-found-company.json")["response"]
    mock_http.respond({ status: 404, headers: fx["headers"], body: fx["body"] })
    expect { rest_client.companies.get(999_999) }.to raise_error(Finlight::NotFoundError)
  end
end
