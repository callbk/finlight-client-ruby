# frozen_string_literal: true

# Smoke tests against the real API; auto-skipped when FINLIGHT_API_KEY is not
# set. Mirrors the sibling clients' integration tests.
#
#   FINLIGHT_API_KEY=sk_... bundle exec rspec spec/integration
RSpec.describe "integration smoke", :integration do
  api_key = ENV.fetch("FINLIGHT_API_KEY", nil)

  before do
    skip "FINLIGHT_API_KEY not set" if api_key.nil? || api_key.empty?
  end

  let(:client) do
    Finlight::Client.new(
      api_key: api_key,
      base_url: ENV.fetch("FINLIGHT_BASE_URL", Finlight::Config::DEFAULT_BASE_URL),
      wss_url: ENV.fetch("FINLIGHT_WSS_URL", Finlight::Config::DEFAULT_WSS_URL)
    )
  end

  it "fetches articles" do
    response = client.articles.fetch_articles(query: "market", page_size: 5)

    expect(response.status).to eq("ok")
    expect(response.articles).not_to be_empty
    article = response.articles.first
    expect(article.link).to start_with("http")
    expect(article.publish_date).to be_a(Time)
  end

  it "fetches an article by link" do
    found = client.articles.fetch_articles(query: "market", page_size: 1).articles.first
    article = client.articles.fetch_article_by_link(link: found.link)

    expect(article.link).to eq(found.link)
    expect(article.title).not_to be_nil
  end

  it "lists sources" do
    sources = client.sources.get_sources

    expect(sources).not_to be_empty
    expect(sources.first.domain).not_to be_nil
    expect(sources.any?(&:is_default_source)).to be(true)
  end
end
