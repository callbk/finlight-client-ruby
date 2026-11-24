# frozen_string_literal: true

RSpec.describe "logging and secrets (R-LOG-1)" do
  key = "sk_secret_test_key_0123456789abcdef"
  secret = "whsec_test_secret_value"

  def current_trap(signal)
    previous = Signal.trap(signal, "DEFAULT")
    Signal.trap(signal, previous)
    previous
  end

  it "never puts the API key, the webhook secret or a signature into logs, errors or inspect output" do
    log = StringIO.new
    logger = Logger.new(log, level: Logger::DEBUG)
    texts = []
    client = Finlight::Client.new(api_key: key, base_url: mock_http.url, logger: logger, clock: RecordingClock.new)
    texts << client.inspect << client.config.inspect << client.articles.inspect << client.companies.inspect

    mock_http.respond({ status: 401, headers: { "content-type" => "application/problem+json" },
                        body: { "code" => "UNAUTHORIZED", "type" => "t", "detail" => "Invalid API key" } })
    begin
      client.articles.search(query: "x")
    rescue Finlight::Error => e
      texts << e.message << e.inspect << e.full_message
    end
    mock_http.reset
    mock_http.respond({ status: 502, body: "<html>bad gateway</html>" })
    begin
      client.sources.list
    rescue Finlight::Error => e
      texts << e.message << e.inspect
    end

    server = WsServer.new
    begin
      server.plan([401, '{"message":"Invalid API key"}'])
      stream = Finlight::Client.new(api_key: key, wss_url: server.url, logger: logger).stream(query: "x")
      texts << stream.inspect
      begin
        stream.each { nil }
      rescue Finlight::Error => e
        texts << e.message << e.inspect
      end
    ensure
      server.close
    end

    signature = "sha256=#{"ab" * 32}"
    begin
      Finlight::Webhooks.construct_event_from_values("{}", signature, "2026-11-23T21:04:05.123Z", secret)
    rescue Finlight::Error => e
      texts << e.message << e.inspect
    end

    texts << log.string
    expect(log.string).not_to be_empty
    texts.each do |text|
      expect(text).not_to include(key)
      expect(text).not_to include(secret)
      expect(text).not_to include("ab" * 32)
    end
  end

  it "is silent without a logger and installs no global handlers" do
    before = %w[INT TERM].to_h { |s| [s, current_trap(s)] }
    expect do
      client = Finlight::Client.new(api_key: key, base_url: mock_http.url, clock: RecordingClock.new)
      mock_http.respond({ status: 500, body: "x" })
      begin
        client.sources.list
      rescue Finlight::Error
        nil
      end
      client.stream(query: "x").close
    end.not_to output.to_stdout
    expect(%w[INT TERM].to_h { |s| [s, current_trap(s)] }).to eq(before)
  end

  it "has one kind per error class and a common base" do
    errors = [
      Finlight::ApiError.new, Finlight::ValidationError.new("x"), Finlight::NetworkError.new("x"),
      Finlight::TimeoutError.new("x"), Finlight::DecodeError.new("x"),
      Finlight::WebhookVerificationError.new(reason: "signature_mismatch"), Finlight::PreemptedError.new
    ]
    expect(errors).to all(be_a(Finlight::Error))
    expect(errors.map(&:kind)).to eq(%w[api validation network timeout decode webhook_verification preempted])
    expect(Finlight::WrongPayloadVersion.ancestors).not_to include(Exception)
    expect(Finlight::ValidationError.ancestors).to include(ArgumentError)
    apis = [Finlight::ValidationFailedError, Finlight::CursorInvalidError, Finlight::CursorMismatchError,
            Finlight::UnauthorizedError, Finlight::ForbiddenError, Finlight::NotFoundError,
            Finlight::RateLimitedError, Finlight::InternalServerError, Finlight::ApiError]
    expect(apis.map { |c| c.new.api_kind }).to eq(%w[validation_failed cursor_invalid cursor_mismatch unauthorized
                                                     forbidden not_found rate_limited internal_error other])
  end
end

RSpec.describe "configuration (R-CONFIG-1)" do
  it "checks the api key in every constructor" do
    expect { Finlight::Client.new }.to raise_error(Finlight::ValidationError)
    expect { Finlight::Client.new(api_key: "") }.to raise_error(Finlight::ValidationError)
    expect { Finlight::Client.new(api_key: "  ") }.to raise_error(Finlight::ValidationError)
    expect { Finlight::Config.new(api_key: nil) }.to raise_error(Finlight::ValidationError)
    expect { Finlight::Client.new(api_key: "k", bogus: 1) }.to raise_error(Finlight::ValidationError)
    expect { Finlight::Client.new(api_key: "k", retry_on_burst: "twice") }.to raise_error(Finlight::ValidationError)
    expect { Finlight::Client.new(api_key: "k", max_message_bytes: 1024) }.to raise_error(Finlight::ValidationError)
  end

  it "has the documented defaults and accepts a Config object" do
    config = Finlight::Config.new(api_key: "k")
    expect(config.base_url).to eq("https://api.finlight.me")
    expect(config.wss_url).to eq("wss://wss.finlight.me")
    expect(config.ws_url(true)).to eq("wss://wss.finlight.me/raw")
    expect(config.timeout).to eq(30.0)
    expect(config.total_timeout).to be_nil
    expect(config.max_retries).to eq(3)
    expect(config.retry_on_burst).to eq("once")
    expect(config.burst_wait).to eq(10.0)
    expect(config.max_pages).to eq(10)
    expect(config.max_response_bytes).to eq(32 * 1024 * 1024)
    expect(config.company_cache_size).to eq(256)
    expect(config.search_failed_threshold).to eq(5)
    expect(Finlight::Client.new(config: config).config).to equal(config)
    expect(config.with(wss_url: "ws://x/").ws_url(true)).to eq("ws://x/raw")
    expect(Finlight::Client.new(api_key: "k", retry_on_burst: :off).config.retry_on_burst).to eq("off")
  end

  it "takes the version from one constant" do
    expect(Finlight::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
    expect(Finlight::USER_AGENT).to eq("finlight-client-ruby/#{Finlight::VERSION}")
    spec = Gem::Specification.load(File.join(Kit::ROOT, "finlight-client.gemspec"))
    expect(spec.version.to_s).to eq(Finlight::VERSION)
  end
end
