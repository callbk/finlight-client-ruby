# frozen_string_literal: true

# Live tests against the finlight dev environment. Never part of the normal test command.
#
#   FINLIGHT_LIVE=1 FINLIGHT_API_KEY=... FINLIGHT_BASE_URL=https://api.dev.finlight.me \
#     FINLIGHT_WSS_URL=wss://wss.dev.finlight.me bundle exec rspec spec/live
#
# All three variables are required (no default points to prod) and a prod host is refused.
# The load stays small. Each run needs the owner's okay.
RSpec.describe "live dev API", :live do
  before(:all) do
    missing = %w[FINLIGHT_API_KEY FINLIGHT_BASE_URL FINLIGHT_WSS_URL].select { |k| ENV[k].to_s.strip == "" }
    raise "live tests need #{missing.join(", ")}" unless missing.empty?

    [ENV.fetch("FINLIGHT_BASE_URL"), ENV.fetch("FINLIGHT_WSS_URL")].each do |url|
      host = URI.parse(url).host.to_s
      raise "refusing a prod host: #{host}" unless host.include?(".dev.")
    end
  end

  let(:client) do
    Finlight::Client.new(api_key: ENV.fetch("FINLIGHT_API_KEY"), base_url: ENV.fetch("FINLIGHT_BASE_URL"),
                         wss_url: ENV.fetch("FINLIGHT_WSS_URL"), max_retries: 1)
  end

  it "searches, pages and looks up" do
    page = client.articles.search(query: "ticker:AAPL", languages: ["en"], include: ["companies"], limit: 2)
    expect(page.articles).not_to be_empty
    expect(page.skipped).to eq([])
    article = page.articles.first
    expect(article.companies_present?).to be(true).or be(false)
    expect(client.articles.get_by_link(article.link).id).to eq(article.id)
    expect(client.articles.get(article.id).link).to eq(article.link)
    all = client.articles.search_all(query: "ticker:AAPL", limit: 2, max_pages: 2)
    expect(all.count).to be <= 4
    expect(all.pages_fetched).to be <= 2
    expect { client.articles.get("AAAAAAAAAAAAAAAAAAAAAA") }.to raise_error(Finlight::NotFoundError)
    sources = client.sources.list
    expect(sources.size).to be > 0
    expect(sources.skipped).to eq([])
  end

  it "looks up companies (or is told it may not)" do
    companies = client.companies.search("AAPL", mic: "XNAS")
    if companies.any?
      record = client.companies.get(companies.first.company_id)
      expect(record.cache_info.etag).to be_a(String)
      again = client.companies.get(record.company_id, if_none_match: record.cache_info.etag) # 304: nil
      expect(again.nil? || again.company_id == record.company_id).to be(true)
    end
  rescue Finlight::ForbiddenError
    skip "this key has no entityAccess"
  end

  it "opens a stream, is admitted and closes cleanly" do
    admitted = Thread::Queue.new
    errors = []
    stream = client.stream(query: "ticker:AAPL", include: ["companies"],
                           on_admitted: ->(info) { admitted << info }, on_error: ->(e) { errors << e })
    runner = Thread.new do
      stream.each { |_event| break }
    rescue Finlight::Error => e
      e
    end
    info = admitted.pop(timeout: 20)
    expect(info).to be_a(Finlight::AdmittedInfo)
    expect(info.lease_id).to be_a(String)
    sleep 2
    stream.close
    result = runner.value
    expect(result).not_to be_a(Exception)
    expect(errors.grep(Finlight::ValidationFailedError)).to eq([])
  end
end
