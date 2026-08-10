# frozen_string_literal: true

require "json"

RSpec.describe "models and params" do
  describe Finlight::Article do
    it "parses an article with string confidence and companies" do
      json = <<~JSON
        {"link":"https://example.com/1","title":"T","publishDate":"2025-06-01T12:00:00.123Z",
         "source":"example.com","language":"en","confidence":"0.87","sentiment":"negative",
         "companies":[{"companyId":42,"name":"Apple","ticker":"AAPL","confidence":"0.99",
                       "isins":["US0378331005"]}],
         "unknownFutureField":{"nested":true}}
      JSON

      article = Finlight::Article.from_h(JSON.parse(json))

      expect(article.confidence).to eq(0.87)
      expect(article.publish_date).to eq(Time.utc(2025, 6, 1, 12, 0, 0.123r))
      expect(article.sentiment).to eq("negative")
      expect(article.companies.size).to eq(1)
      expect(article.companies.first.confidence).to eq(0.99)
      expect(article.companies.first.company_id).to eq(42)
      expect(article.companies.first.isins).to eq(["US0378331005"])
      expect(article.images).to be_nil
      expect(article.content).to be_nil
    end
  end

  describe Finlight::FlexTime do
    it "parses flexible timestamp formats" do
      expect(described_class.parse("2025-06-01T12:00:00Z")).to eq(Time.utc(2025, 6, 1, 12))
      expect(described_class.parse("2025-06-01T12:00:00+02:00")).to eq(Time.utc(2025, 6, 1, 10))
      expect(described_class.parse("2025-06-01T12:00:00.500")).to eq(Time.utc(2025, 6, 1, 12, 0, 0.5r))
      expect(described_class.parse("2025-06-01 12:00:00")).to eq(Time.utc(2025, 6, 1, 12))
      expect(described_class.parse("2025-06-01")).to eq(Time.utc(2025, 6, 1))
    end

    it "raises on unknown formats" do
      expect { described_class.parse("junk") }.to raise_error(Finlight::Error)
    end
  end

  describe Finlight::Params do
    it "serializes params camelCased, omitting unset fields" do
      normalized = Finlight::Params.normalize(
        query: "Nvidia",
        tickers: ["NVDA"],
        categories: %w[technology markets],
        order_by: "publishDate",
        order: "DESC",
        include_content: true,
        page_size: 20,
        sources: nil,
        from: nil,
        page: nil
      )

      expect(normalized).to eq(
        "query" => "Nvidia",
        "tickers" => ["NVDA"],
        "categories" => %w[technology markets],
        "orderBy" => "publishDate",
        "order" => "DESC",
        "includeContent" => true,
        "pageSize" => 20
      )
    end

    it "keeps date-range keys and false values, and passes camelCase through" do
      normalized = Finlight::Params.normalize(
        from: "2025-01-01", to: "2025-02-01", include_updates: false, "excludeSources" => ["x.com"]
      )

      expect(normalized).to eq(
        "from" => "2025-01-01",
        "to" => "2025-02-01",
        "includeUpdates" => false,
        "excludeSources" => ["x.com"]
      )
    end
  end
end
