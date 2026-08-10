# frozen_string_literal: true

module Finlight
  # Fetches financial news articles.
  class ArticleService
    def initialize(api_client)
      @api_client = api_client
    end

    # Searches articles with advanced filtering by query, tickers, sources,
    # dates, countries and categories.
    #
    # @example
    #   response = client.articles.fetch_articles(
    #     query: "Nvidia", tickers: ["NVDA"], include_content: true, page_size: 20
    #   )
    #   response.articles.each { |a| puts a.title }
    #
    # @param params [Hash] snake_case keywords, e.g. +query:+, +sources:+,
    #   +exclude_sources:+, +from:+, +to:+, +language:+, +tickers:+,
    #   +include_entities:+, +exclude_empty_content:+, +include_content:+,
    #   +order_by:+ ("publishDate"|"createdAt"|"revisedDate"),
    #   +order:+ ("ASC"|"DESC"), +page_size:+ (1-1000), +page:+, +countries:+,
    #   +categories:+
    # @return [ArticleResponse]
    # @raise [ApiError] if the API request fails
    def fetch_articles(**params)
      response = @api_client.post("/v2/articles", Params.normalize(params))
      ArticleResponse.from_h(response)
    end

    # Fetches a single article by its URL.
    #
    # @example
    #   article = client.articles.fetch_article_by_link(
    #     link: "https://www.reuters.com/technology/example", include_content: true
    #   )
    #
    # @param link [String] the URL of the article to fetch
    # @param params [Hash] optional +include_content:+ and +include_entities:+
    # @return [Article]
    # @raise [ApiError] if the API request fails or the article is not found
    def fetch_article_by_link(link:, **params)
      query = Params.normalize(params.merge(link: link))
      query = query.transform_values { |v| [true, false].include?(v) ? v.to_s : v }
      response = @api_client.get("/v2/articles/by-link", query)
      Article.from_h(response.fetch("article"))
    end
  end
end
