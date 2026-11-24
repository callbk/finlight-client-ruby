# frozen_string_literal: true

RSpec.describe "request parameters" do
  let(:client) { rest_client }

  def expect_local_rejection(param, &block)
    expect(&block).to raise_error(Finlight::ValidationError) { |e|
      expect(e).to be_a(ArgumentError)
      expect(e.param).to eq(param)
      expect(e.kind).to eq("validation")
    }
    expect(mock_http.requests).to eq([])
  end

  it "rejects every shape error before any request (R-REQ-3)" do
    expect_local_rejection("limit") { client.articles.search(limit: 0) }
    expect_local_rejection("limit") { client.articles.search(limit: 101) }
    expect_local_rejection("limit") { client.articles.search(limit: true) }
    expect_local_rejection("limit") { client.articles.search(limit: "20") }
    expect_local_rejection("languages") { client.articles.search(languages: []) }
    expect_local_rejection("min_relevance") { client.articles.search(min_relevance: 1.5) }
    expect_local_rejection("min_relevance") { client.articles.search(min_relevance: "0.5") }
    expect_local_rejection("min_relevance") { client.articles.search(min_relevance: Rational(1, 2)) }
    expect_local_rejection("min_relevance") { client.articles.search(min_relevance: Complex(1, 0)) }
    expect_local_rejection("min_relevance") { client.articles.search(min_relevance: Float::NAN) }
    expect_local_rejection("include") { client.articles.search(include: %w[content companies events content]) }
    expect_local_rejection("has_content") { client.articles.search(has_content: "yes") }
    expect_local_rejection("from") { client.articles.search(from: 12) }
    expect_local_rejection("ids") { client.companies.get_many([]) }
    expect_local_rejection("ids") { client.companies.get_many((1..11).to_a) }
    expect_local_rejection("ids") { client.companies.get_many([0]) }
    expect_local_rejection("ids") { client.companies.get_many(["1"]) }
    expect_local_rejection("q") { client.companies.search("x" * 201) }
    expect_local_rejection("q") { client.companies.search("") }
    expect_local_rejection("mic") { client.companies.search("NVDA", mic: "X" * 33) }
    expect_local_rejection("company_id") { client.companies.get("abc") }
    expect_local_rejection("link") { client.articles.get_by_link("") }
    expect_local_rejection("id") { client.articles.get("") }
    expect_local_rejection("event_type") { client.articles.search(event_type: ["mna"]) }
    expect_local_rejection("max_pages") { client.articles.search_all(max_pages: 0) }
  end

  it "checks stream parameters at once, before any dial" do
    stream_client = Finlight::Client.new(api_key: "k", wss_url: "ws://127.0.0.1:9")
    expect { stream_client.stream(query: 1) }.to raise_error(Finlight::ValidationError)
    expect { stream_client.stream(include: %w[a b c d]) }.to raise_error(Finlight::ValidationError)
    expect { stream_client.raw_stream(include: ["content"]) }.to raise_error(Finlight::ValidationError) { |e|
      expect(e.param).to eq("include")
    }
    expect { stream_client.raw_stream(tickers: ["X"]) }.to raise_error(Finlight::ValidationError)
    expect { stream_client.stream(payload_version: 2) }.to raise_error(Finlight::ValidationError)
    expect { stream_client.stream(on_error: 1) }.to raise_error(Finlight::ValidationError)
    # Source type filters exist for search only.
    %i[source_types exclude_source_types].each do |key|
      expect { stream_client.stream(key => ["newswire"]) }.to raise_error(Finlight::ValidationError)
      expect { stream_client.raw_stream(key => ["newswire"]) }.to raise_error(Finlight::ValidationError)
    end
  end

  it "sends unknown vocabulary values unchanged" do
    mock_http.respond({ status: 200, body: { "articles" => [], "pagination" => {} } })
    client.articles.search(event_types: ["brand_new_type"], order: "sideways", source_types: ["wire_service"],
                           exclude_source_types: [Finlight::SourceType::BLOG])
    expected = { "eventTypes" => ["brand_new_type"], "order" => "sideways", "sourceTypes" => ["wire_service"],
                 "excludeSourceTypes" => ["blog"] }
    expect(JSON.parse(mock_http.requests[0].body)).to eq(expected)
  end

  it "sends false and 0 when set, and nothing for nil" do
    mock_http.respond({ status: 200, body: { "articles" => [], "pagination" => {} } })
    client.articles.search(has_content: false, min_relevance: 0, query: nil)
    expect(mock_http.requests[0].body).to eq('{"hasContent":false,"minRelevance":0}')
  end

  it "builds the subscribe from a fixed list of keys, with payloadVersion the integer 3 (R-REQ-1)" do
    frame = FinlightInternal::Params.subscribe_frame({ query: "ticker:X" }, raw: false)
    expect(frame).to eq("payloadVersion" => 3, "query" => "ticker:X")
    expect(frame["payloadVersion"]).to be_an(Integer)
    expect(FinlightInternal::Params.subscribe_frame({ include: [] }, raw: false)).to eq("payloadVersion" => 3)
  end

  it "formats dates and times (R-REQ-2)" do
    expect(FinlightInternal::Params.time!(Time.new(2026, 11, 1, 1, 2, 3.5r, "+01:00"), "from"))
      .to eq("2026-11-01T00:02:03.500Z")
    expect(FinlightInternal::Params.time!(Date.new(2026, 11, 1), "from")).to eq("2026-11-01")
    expect(FinlightInternal::Params.time!(DateTime.new(2026, 11, 1, 5, 0, 0, "+02:00"), "from"))
      .to eq("2026-11-01T03:00:00.000Z")
    expect(FinlightInternal::Params.time!("yesterday-ish", "from")).to eq("yesterday-ish")
  end

  it "puts include and ids into one comma-joined query value and encodes the link once" do
    mock_http.respond({ status: 200, body: { "article" => Kit.load("fixtures/decode/full-article.json")["wire"] } })
    client.articles.get_by_link("https://x.example/a b?c=d&e", include: %w[content events])
    request = mock_http.requests[0]
    expect(request.query).not_to include("include[]")
    expect(request.query_pairs).to eq([["link", "https://x.example/a b?c=d&e"], %w[include content,events]])
    mock_http.reset
    mock_http.respond({ status: 200, body: { "companies" => [] } })
    client.companies.get_many([1, 2])
    expect(mock_http.requests[0].query_pairs).to eq([%w[ids 1,2]])
  end

  it "formats the same under a Turkish and a German locale" do
    old = ENV.to_h.slice("LANG", "LC_ALL")
    %w[tr_TR.UTF-8 de_DE.UTF-8].each do |locale|
      ENV["LANG"] = locale
      ENV["LC_ALL"] = locale
      params = FinlightInternal::Params
      body = params.json(params.search_body(min_relevance: 0.5, query: "I", limit: 10, from: Time.utc(2026, 1, 1)))
      expect(body).to eq('{"minRelevance":0.5,"query":"I","limit":10,"from":"2026-01-01T00:00:00.000Z"}')
    end
  ensure
    %w[LANG LC_ALL].each { |k| old.key?(k) ? ENV[k] = old[k] : ENV.delete(k) }
  end
end
