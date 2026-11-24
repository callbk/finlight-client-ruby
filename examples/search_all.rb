# frozen_string_literal: true

# Walk up to 3 pages of a search. Every page costs quota. Run: FINLIGHT_API_KEY=... ruby examples/search_all.rb

require "finlight"

module SearchAllExample
  def self.run
    client = Finlight::Client.new(api_key: ENV.fetch("FINLIGHT_API_KEY"),
                                  **{ base_url: ENV.fetch("FINLIGHT_BASE_URL", nil) }.compact)
    result = client.articles.search_all(query: "ticker:NVDA", limit: 50, max_pages: 3)
    count = result.count # the result can be iterated once
    puts "#{count} articles from #{result.pages_fetched} pages"
    return unless result.truncated?

    puts "stopped at max_pages; continue with cursor: #{result.next_cursor}"
    puts "  client.articles.search_all(query: \"ticker:NVDA\", limit: 50, cursor: result.next_cursor)"
  rescue Finlight::ApiError => e
    puts "API error: status=#{e.status} code=#{e.code.inspect} request_id=#{e.request_id}"
  end
end

SearchAllExample.run if $PROGRAM_NAME == __FILE__
