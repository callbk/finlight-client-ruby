# frozen_string_literal: true

RSpec.describe "Conformance R: requests" do
  def serve(fixture)
    resp = fixture["response"]
    mock_http.respond({ status: resp["status"], headers: resp["headers"], body: resp["body"] })
  end

  def call(client, sdk)
    args = sdk["args"].dup
    case sdk["method"]
    when "articles.search" then client.articles.search(**Kit.snake_args(args))
    when "articles.get" then client.articles.get(args.delete("id"), **Kit.snake_args(args))
    when "articles.getByLink" then client.articles.get_by_link(args.delete("link"), **Kit.snake_args(args))
    when "companies.search" then client.companies.search(args.delete("q"), **Kit.snake_args(args))
    when "companies.getMany" then client.companies.get_many(args["ids"])
    when "companies.get" then client.companies.get(args.delete("companyId"), **Kit.snake_args(args))
    when "sources.list" then client.sources.list
    else raise "unknown method #{sdk["method"]}"
    end
  end

  def check_request(fixture)
    expect(mock_http.requests.size).to eq(1)
    request = mock_http.requests[0]
    want = fixture["request"]
    expect(request.method).to eq(want["method"])
    expect(request.path).to eq(want["path"])
    expect(request.query_pairs).to eq(URI.decode_www_form(want.fetch("query", "")))
    expect(request.query.to_s).not_to include("include[]")
    expect(request.header("X-API-KEY")).to eq(want["headers"]["X-API-KEY"])
    expect(request.header("If-None-Match")).to eq(want["headers"]["If-None-Match"]) if
      want["headers"].key?("If-None-Match")
    expect(request.header("User-Agent")).to eq("finlight-client-ruby/#{Finlight::VERSION}")
    expect(request.header("x-client-version")).to eq(Finlight::VERSION)
    expect(request.header("X-Request-Id")).to match(/\A[0-9a-f-]{36}\z/)
    if want.key?("body")
      expect(request.header("Content-Type")).to eq("application/json")
      expect(JSON.parse(request.body)).to eq(want["body"])
    end
    request
  end

  cases = Kit.fixtures("fixtures/requests", exclude: %w[ws-subscribe-enriched.json ws-subscribe-raw.json])
  cases.each do |id, name|
    it "#{id} #{Kit.case_titles[id]}", kit_case: id do
      fx = Kit.load("fixtures/requests/#{name}")
      client = rest_client(api_key: fx["request"]["headers"]["X-API-KEY"])
      serve(fx)

      if id == "R-12"
        expect { call(client, fx["sdk"]) }.to raise_error(Finlight::ValidationError) { |e|
          expect(e.param).to eq("event_type")
          expect(e.message).to include("event_type")
          expect(e).to be_a(ArgumentError)
        }
        expect(mock_http.requests).to eq([])
        next
      end

      result = call(client, fx["sdk"])
      request = check_request(fx)
      body = fx["response"]["body"]
      case id
      when "R-01", "R-03"
        expect(request.body).to eq(JSON.generate(fx["request"]["body"]))
        expect(result.articles.map(&:id)).to eq(body["articles"].map { |a| a["id"] })
        expect(result.pagination.has_more).to be(false)
        expect(result.pagination.next_cursor).to be_nil
      when "R-02"
        expect(result.articles.map(&:id)).to eq(body["articles"].map { |a| a["id"] })
        expect(result.articles[0].companies_present?).to be(true)
        expect(result.articles[0].content_present?).to be(true)
      when "R-04", "R-05"
        expect(result).to be_a(Finlight::Article)
        expect(result.id).to eq(body["article"]["id"])
        expect(result.link).to eq(body["article"]["link"])
      when "R-06", "R-07"
        expect(result).to be_a(Finlight::CompanyList)
        expect(result.map(&:company_id)).to eq(body["companies"].map { |c| c["companyId"] })
        expect(result.skipped).to eq([])
        if id == "R-07"
          expect(result[1].primary_listing).to be_nil
          expect(result[1].listings).to eq([])
          expect(result[1].isins).to eq([])
        end
      when "R-08"
        expect(result).to be_a(Finlight::CompanyRecord)
        expect(result.cache_info.etag).to eq(fx["response"]["headers"]["etag"])
        expect(result.cache_info.cache_control).to eq(fx["response"]["headers"]["cache-control"])
        expect(result.cache_info.not_modified).to be(false)
        expect(request.header("If-None-Match")).to be_nil # no caller ifNoneMatch: no conditional request
        mics = result.listings.map(&:mic)
        expect(mics.uniq).to eq(mics)
        expect(result.listings[0].mic).to eq(result.primary_listing.mic)
        expect(result.listings.map(&:active)).to all(satisfy { |v| [true, false].include?(v) })
      when "R-09"
        expect(result).to be_nil # the caller's ETag: "not modified"
      when "R-10"
        expect(result).to be_a(Finlight::SourceList)
        expect(result.map(&:has_content)).to all(satisfy { |v| [true, false].include?(v) })
        expect(result.to_h { |s| [s.domain, s.is_custom] }["custom.example.net"]).to be(true)
        expect(result.map(&:is_default)).to eq(body["sources"].map { |s| s["isDefault"] })
      when "R-11"
        expect(result.map(&:has_content)).to all(be_nil)
        expect(result.map { |s| s.raw_json.key?("hasContent") }).to all(be(false))
      else raise "no assertions for #{id}"
      end
    end
  end

  it "R-02 native Time and Date values serialize like the kit", kit_case: "R-02" do
    fx = Kit.load("fixtures/requests/search-all-parameters.json")
    serve(fx)
    args = Kit.snake_args(fx["sdk"]["args"])
    args[:from] = Time.new(2026, 11, 1, 1, 0, 0, "+01:00")
    args[:to] = Time.utc(2026, 11, 23)
    rest_client.articles.search(**args)
    expect(JSON.parse(mock_http.requests[0].body)).to eq(fx["request"]["body"])
  end

  it "R-08 the SDK keeps no company cache: a second get sends no If-None-Match", kit_case: "R-08" do
    ok = Kit.load("fixtures/requests/companies-get.json")
    client = rest_client
    serve(ok)
    client.companies.get(900_001)
    second = client.companies.get(900_001)
    expect(mock_http.requests.size).to eq(2)
    expect(mock_http.requests.map { |r| r.header("If-None-Match") }).to eq([nil, nil])
    expect(second.cache_info.etag).to eq(ok["response"]["headers"]["etag"])
  end

  it "R-09 a 304 with the caller's ETag returns nil, never a stored record", kit_case: "R-09" do
    ok = Kit.load("fixtures/requests/companies-get.json")
    not_modified = Kit.load("fixtures/requests/companies-get-not-modified.json")
    client = rest_client
    serve(ok)
    first = client.companies.get(900_001)
    mock_http.reset
    serve(not_modified)
    expect(client.companies.get(900_001, if_none_match: first.cache_info.etag)).to be_nil
    expect(mock_http.requests[0].header("If-None-Match")).to eq(first.cache_info.etag)
  end
end
