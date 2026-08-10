# frozen_string_literal: true

require_relative "client/version"
require_relative "errors"
require_relative "logging"
require_relative "config"
require_relative "flex_time"
require_relative "params"
require_relative "models"
require_relative "api_client"
require_relative "article_service"
require_relative "source_service"
require_relative "webhook_service"
require_relative "websocket/base_client"
require_relative "websocket/article_client"
require_relative "websocket/raw_article_client"

module Finlight
  # Entry point to the finlight API.
  #
  # @example
  #   client = Finlight::Client.new(api_key: ENV["FINLIGHT_API_KEY"])
  #   response = client.articles.fetch_articles(query: "Nvidia", page_size: 20)
  #   response.articles.each { |article| puts article.title }
  class Client
    attr_reader :config, :articles, :sources

    # @param api_key [String] your finlight API key
    # @param options [Hash] optional +base_url:+, +wss_url:+, +timeout:+
    #   (seconds), +retry_count:+ — see {Config}
    def initialize(api_key:, logger: Logging.default, **options)
      @config = Config.new(api_key: api_key, **options)
      @logger = logger
      api_client = ApiClient.new(@config, logger: logger)
      @articles = ArticleService.new(api_client)
      @sources = SourceService.new(api_client)
    end

    # A streaming client for enriched articles — see
    # {BaseWebSocketClient#connect} for options and usage.
    #
    # @return [ArticleWebSocketClient]
    def websocket(**options)
      ArticleWebSocketClient.new(@config, logger: @logger, **options)
    end

    # A streaming client for raw articles (minimal latency, no enrichment).
    #
    # @return [RawArticleWebSocketClient]
    def raw_websocket(**options)
      RawArticleWebSocketClient.new(@config, logger: @logger, **options)
    end
  end
end
