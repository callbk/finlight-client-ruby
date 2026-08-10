# frozen_string_literal: true

RSpec.describe Finlight::ApiClient do
  let(:server) { HttpTestServer.new }
  let(:client) do
    Finlight::Client.new(
      api_key: "test-key",
      base_url: server.url,
      timeout: 2,
      logger: test_logger
    )
  end

  after { server.close }

  it "posts params and parses the response" do
    api_keys = []
    bodies = []
    server.mount("/v2/articles") do |req, res|
      api_keys << req["X-API-KEY"]
      bodies << req.body
      HttpTestServer.respond_json(res, 200, <<~JSON)
        {"status":"ok","page":1,"pageSize":20,"articles":[
          {"link":"https://example.com/1","title":"A","publishDate":"2025-06-01 08:30:00",
           "source":"example.com","language":"en","confidence":"0.9"}]}
      JSON
    end

    response = client.articles.fetch_articles(query: "Nvidia", page_size: 20)

    expect(response.status).to eq("ok")
    expect(response.articles.size).to eq(1)
    expect(response.articles.first.confidence).to eq(0.9)
    expect(response.articles.first.publish_date).to eq(Time.utc(2025, 6, 1, 8, 30, 0))
    expect(api_keys).to eq(["test-key"])
    expect(bodies.first).to include('"query":"Nvidia"')
    expect(bodies.first).to include('"pageSize":20')
  end

  it "fetches an article by link with encoded query params and unwraps the envelope" do
    queries = []
    server.mount("/v2/articles/by-link") do |req, res|
      queries << req.request_uri.query
      HttpTestServer.respond_json(res, 200, <<~JSON)
        {"article":{"link":"https://example.com/1","title":"A",
         "publishDate":"2025-06-01T08:30:00Z","source":"example.com","language":"en"}}
      JSON
    end

    article = client.articles.fetch_article_by_link(
      link: "https://example.com/1?a=b", include_content: true
    )

    expect(article.title).to eq("A")
    expect(queries.size).to eq(1)
    expect(queries.first).to include("link=https%3A%2F%2Fexample.com%2F1%3Fa%3Db")
    expect(queries.first).to include("includeContent=true")
  end

  it "parses the sources list" do
    server.mount("/v2/sources") do |_req, res|
      HttpTestServer.respond_json(res, 200, <<~JSON)
        [{"domain":"example.com","isDefaultSource":true,"isContentAvailable":true},
         {"domain":"other.com","isDefaultSource":false}]
      JSON
    end

    sources = client.sources.get_sources
    expect(sources.size).to eq(2)
    expect(sources.first.domain).to eq("example.com")
    expect(sources.first.is_default_source).to be(true)
    expect(sources.last.is_default_source).to be(false)
  end

  it "retries retryable statuses then succeeds" do
    attempts = 0
    server.mount("/v2/sources") do |_req, res|
      attempts += 1
      if attempts < 3
        HttpTestServer.respond_json(res, 503, "{}")
      else
        HttpTestServer.respond_json(res, 200, "[]")
      end
    end

    sources = client.sources.get_sources
    expect(sources).to eq([])
    expect(attempts).to eq(3)
  end

  it "does not retry client errors" do
    attempts = 0
    server.mount("/v2/sources") do |_req, res|
      attempts += 1
      HttpTestServer.respond_json(res, 400, '{"message":"bad request"}')
    end

    expect { client.sources.get_sources }.to raise_error(Finlight::ApiError) do |e|
      expect(e.status_code).to eq(400)
      expect(e.body).to include("bad request")
    end
    expect(attempts).to eq(1)
  end

  it "throws after exhausting retries" do
    attempts = 0
    server.mount("/v2/sources") do |_req, res|
      attempts += 1
      HttpTestServer.respond_json(res, 503, "{}")
    end

    expect { client.sources.get_sources }.to raise_error(Finlight::ApiError) do |e|
      expect(e.status_code).to eq(503)
    end
    expect(attempts).to eq(3)
  end
end
