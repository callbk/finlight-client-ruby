# frozen_string_literal: true

module Finlight
  # Shared parsing helpers for wire-format (camelCase) JSON hashes.
  module ModelParsing
    module_function

    # The API sometimes delivers numbers as strings (e.g. "confidence":"0.9").
    def to_float(value)
      return nil if value.nil?

      Float(value)
    rescue ArgumentError, TypeError
      nil
    end

    def to_string_list(value)
      value&.map(&:to_s)
    end
  end

  # A ticker listing on an exchange.
  class Listing
    attr_reader :ticker, :exchange_code, :exchange_country

    def initialize(ticker:, exchange_code:, exchange_country:)
      @ticker = ticker
      @exchange_code = exchange_code
      @exchange_country = exchange_country
    end

    def self.from_h(hash)
      new(
        ticker: hash["ticker"],
        exchange_code: hash["exchangeCode"],
        exchange_country: hash["exchangeCountry"]
      )
    end
  end

  # A company tagged in an article.
  class Company
    attr_reader :company_id, :confidence, :country, :exchange, :industry, :sector,
                :name, :ticker, :isin, :openfigi, :primary_listing, :isins, :other_listings

    def initialize(company_id:, name:, ticker:, confidence: nil, country: nil, exchange: nil,
                   industry: nil, sector: nil, isin: nil, openfigi: nil, primary_listing: nil,
                   isins: nil, other_listings: nil)
      @company_id = company_id
      @confidence = confidence
      @country = country
      @exchange = exchange
      @industry = industry
      @sector = sector
      @name = name
      @ticker = ticker
      @isin = isin
      @openfigi = openfigi
      @primary_listing = primary_listing
      @isins = isins
      @other_listings = other_listings
    end

    def self.from_h(hash)
      new(
        company_id: hash["companyId"],
        confidence: ModelParsing.to_float(hash["confidence"]),
        country: hash["country"],
        exchange: hash["exchange"],
        industry: hash["industry"],
        sector: hash["sector"],
        name: hash["name"],
        ticker: hash["ticker"],
        isin: hash["isin"],
        openfigi: hash["openfigi"],
        primary_listing: hash["primaryListing"] && Listing.from_h(hash["primaryListing"]),
        isins: ModelParsing.to_string_list(hash["isins"]),
        other_listings: hash["otherListings"]&.map { |l| Listing.from_h(l) }
      )
    end
  end

  # An unenriched article as delivered by the raw stream.
  class RawArticle
    attr_reader :link, :title, :publish_date, :source, :language, :summary, :images,
                :created_at, :revised_date, :is_update, :categories

    def initialize(link:, title:, publish_date:, source:, language:, summary: nil, images: nil,
                   created_at: nil, revised_date: nil, is_update: nil, categories: nil, **)
      @link = link
      @title = title
      @publish_date = publish_date
      @source = source
      @language = language
      @summary = summary
      @images = images
      @created_at = created_at
      @revised_date = revised_date
      @is_update = is_update
      @categories = categories
    end

    def self.base_attributes(hash)
      {
        link: hash["link"],
        title: hash["title"],
        publish_date: FlexTime.parse(hash["publishDate"]),
        source: hash["source"],
        language: hash["language"],
        summary: hash["summary"],
        images: ModelParsing.to_string_list(hash["images"]),
        created_at: FlexTime.parse(hash["createdAt"]),
        revised_date: FlexTime.parse(hash["revisedDate"]),
        is_update: hash["isUpdate"],
        categories: ModelParsing.to_string_list(hash["categories"])
      }
    end

    def self.from_h(hash)
      new(**base_attributes(hash))
    end
  end

  # An enriched article with sentiment, entities and content.
  class Article < RawArticle
    attr_reader :sentiment, :confidence, :content, :companies, :countries

    def initialize(sentiment: nil, confidence: nil, content: nil, companies: nil,
                   countries: nil, **base)
      super(**base)
      @sentiment = sentiment
      @confidence = confidence
      @content = content
      @companies = companies
      @countries = countries
    end

    def self.from_h(hash)
      new(
        **base_attributes(hash),
        sentiment: hash["sentiment"],
        confidence: ModelParsing.to_float(hash["confidence"]),
        content: hash["content"],
        companies: hash["companies"]&.map { |c| Company.from_h(c) },
        countries: ModelParsing.to_string_list(hash["countries"])
      )
    end
  end

  # A page of search results.
  class ArticleResponse
    attr_reader :status, :page, :page_size, :articles

    def initialize(status:, page:, page_size:, articles:)
      @status = status
      @page = page
      @page_size = page_size
      @articles = articles
    end

    def self.from_h(hash)
      new(
        status: hash["status"],
        page: hash["page"],
        page_size: hash["pageSize"],
        articles: (hash["articles"] || []).map { |a| Article.from_h(a) }
      )
    end
  end

  # A news source available through the API.
  class Source
    attr_reader :domain, :is_content_available, :is_default_source

    def initialize(domain:, is_content_available:, is_default_source:)
      @domain = domain
      @is_content_available = is_content_available
      @is_default_source = is_default_source
    end

    def self.from_h(hash)
      new(
        domain: hash["domain"],
        is_content_available: !!hash["isContentAvailable"],
        is_default_source: !!hash["isDefaultSource"]
      )
    end
  end
end
