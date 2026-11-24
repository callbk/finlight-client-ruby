# frozen_string_literal: true

RSpec.describe "Conformance E: errors and retry classes" do
  classes = {
    "VALIDATION_FAILED" => Finlight::ValidationFailedError, "CURSOR_INVALID" => Finlight::CursorInvalidError,
    "CURSOR_MISMATCH" => Finlight::CursorMismatchError, "UNAUTHORIZED" => Finlight::UnauthorizedError,
    "FORBIDDEN" => Finlight::ForbiddenError, "NOT_FOUND" => Finlight::NotFoundError,
    "RATE_LIMITED" => Finlight::RateLimitedError, "INTERNAL_ERROR" => Finlight::InternalServerError
  }

  Kit.fixtures("fixtures/errors", exclude: ["retry-classes.json"]).each do |id, name|
    it "#{id} #{Kit.case_titles[id]}", kit_case: id do
      fx = Kit.load("fixtures/errors/#{name}")
      req = fx["request"]
      resp = fx["response"]
      expect_ = fx["expect"]
      mock_http.respond({ status: resp["status"], headers: resp["headers"], body: resp["body"] })
      # E-12 sends no key; the SDK always sends one, the server answer is what is tested.
      client = rest_client(api_key: req["headers"].fetch("X-API-KEY", "sk_missing"))
      body = if req.key?("rawBody") then req["rawBody"]
             elsif req.key?("body") then JSON.generate(req["body"])
             end
      query = req["query"] ? URI.decode_www_form(req["query"]) : nil
      http = client.articles.instance_variable_get(:@http)

      error = nil
      begin
        http.call(req["method"], req["path"], query: query, body: body)
      rescue Finlight::ApiError => e
        error = e
      end
      expect(error).not_to be_nil
      expect(error.status).to eq(resp["status"])
      expect(error.kind).to eq("api")
      expect(error).to be_a(Finlight::Error)
      expect(error.api_kind).to eq(expect_["apiKind"])
      sent_ids = mock_http.requests.map { |r| r.header("X-Request-Id") }.uniq
      expect(sent_ids.size).to eq(1) # one X-Request-Id per logical call, the same on every retry

      case expect_["code"]
      when "NESTJS_FALLBACK"
        expect(error.code).to be_nil
        expect(error.detail).to eq(resp["body"]["message"])
        expect(error.request_id).to eq(sent_ids[0])
        expect(error).to be_a(Finlight::ValidationFailedError) if resp["status"] == 400
        expect(error).to be_a(Finlight::NotFoundError) if resp["status"] == 404
      when nil
        expect(error.class).to eq(Finlight::ApiError)
        expect(error.code).to be_nil
        expect(error.raw).to eq(resp["body"])
        expect(error.raw_json).to be_nil
        expect(error.request_id).to eq(sent_ids[0])
      else
        expect(error.class).to eq(classes.fetch(expect_["code"]))
        expect(error.code).to eq(expect_["code"])
        expect(error.detail).to eq(resp["body"]["detail"])
        expect(error.title).to eq(resp["body"]["title"])
        expect(error.type).to eq(resp["body"]["type"])
        expect(error.request_id).to eq(resp["body"]["requestId"])
        want = resp["body"].fetch("errors", []).map { |e| [e["field"], e["issue"], e["allowedValues"]] }
        expect(error.errors.map { |e| [e.field, e.issue, e.allowed_values] }).to eq(want)
        expect(error.raw_json).to eq(resp["body"])
      end

      attempts = mock_http.requests.size
      case expect_["retry"]
      when "never"
        expect(attempts).to eq(1)
        expect(recording_clock.sleeps).to eq([])
      when "once-after-burst-wait"
        expect(error).to be_a(Finlight::RateLimitedError)
        expect(error.limit_type).to eq("burst")
        expect(error.retry_after).to eq(7.0)
        expect(attempts).to eq(2)
        expect(recording_clock.sleeps).to eq([7.0])
      when "backoff"
        expect(attempts).to eq(4)
        expect(recording_clock.sleeps.size).to eq(3)
        expect(recording_clock.sleeps).to eq(recording_clock.sleeps.sort)
      else raise "unknown retry class"
      end

      case id
      when "E-02" then expect(error.errors.size).to be > 1
      when "E-18"
        expect(error.limit_type).to eq("monthly")
        expect(error.retry_after).to be_nil
      when "E-23" then expect(error.request_id).to start_with("req_")
      end
    end
  end

  it "E-19 burst retry can be turned off", kit_case: "E-19" do
    fx = Kit.load("fixtures/errors/rate-limited-burst.json")
    mock_http.respond({ status: 429, headers: fx["response"]["headers"], body: fx["response"]["body"] })
    client = rest_client(retry_on_burst: "off")
    expect { client.articles.search }.to raise_error(Finlight::RateLimitedError)
    expect(mock_http.requests.size).to eq(1)
    expect(recording_clock.sleeps).to eq([])
  end

  it "E-19 waits 10 s when Retry-After is missing, and the retry does not count against max_retries",
     kit_case: "E-19" do
    fx = Kit.load("fixtures/errors/rate-limited-burst.json")
    headers = fx["response"]["headers"].except("retry-after")
    internal = Kit.load("fixtures/errors/internal-error.json")["response"]
    mock_http.respond({ status: 429, headers: headers, body: fx["response"]["body"] },
                      { status: 500, headers: internal["headers"], body: internal["body"] })
    expect { rest_client(max_retries: 1).articles.search }.to raise_error(Finlight::InternalServerError)
    expect(mock_http.requests.size).to eq(3)
    expect(recording_clock.sleeps[0]).to eq(10.0)
  end

  it "E-18 a monthly 429 stops search_all at once", kit_case: "E-18" do
    fx = Kit.load("fixtures/errors/rate-limited-monthly.json")
    mock_http.respond({ status: 429, headers: fx["response"]["headers"], body: fx["response"]["body"] })
    result = rest_client.articles.search_all(query: "x")
    expect { result.to_a }.to raise_error(Finlight::RateLimitedError) { |e| expect(e.limit_type).to eq("monthly") }
    expect(mock_http.requests.size).to eq(1)
    expect(recording_clock.sleeps).to eq([])
  end
end
