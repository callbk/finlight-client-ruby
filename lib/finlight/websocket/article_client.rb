# frozen_string_literal: true

module Finlight
  # Streams enriched articles (sentiment, entities, content). Duplicate
  # deliveries are suppressed via a small cache of recent article links.
  class ArticleWebSocketClient < BaseWebSocketClient
    private

    def websocket_url
      @config.wss_url
    end

    def parse_article(data)
      Article.from_h(data)
    end

    def article_id(article)
      article.link
    end
  end
end
