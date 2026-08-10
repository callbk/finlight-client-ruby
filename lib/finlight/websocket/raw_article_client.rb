# frozen_string_literal: true

module Finlight
  # Streams unenriched articles with minimal latency. The raw stream delivers
  # every message, including updates — no duplicate suppression.
  class RawArticleWebSocketClient < BaseWebSocketClient
    private

    def websocket_url
      "#{@config.wss_url}/raw"
    end

    def parse_article(data)
      RawArticle.from_h(data)
    end
  end
end
