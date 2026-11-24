# frozen_string_literal: true

# One page of a search. Run: FINLIGHT_API_KEY=... ruby examples/search.rb
# Optional: FINLIGHT_BASE_URL (for example https://api.dev.finlight.me).

require "finlight"

module SearchExample
  def self.client
    Finlight::Client.new(api_key: ENV.fetch("FINLIGHT_API_KEY"),
                         **{ base_url: ENV.fetch("FINLIGHT_BASE_URL", nil) }.compact)
  end

  def self.run
    page = client.articles.search(query: "ticker:NVDA", languages: ["en"], include: %w[companies events],
                                  limit: 10)
    page.articles.each do |article|
      time = article.published_at_time&.iso8601 || "-"
      companies = article.companies_present? ? article.companies.map(&:name).join(", ") : "(not delivered)"
      puts "#{time}  #{article.source.domain}  #{article.title}  [#{companies}]"
    end
    puts "has more: #{page.pagination.has_more}"
  rescue Finlight::ApiError => e
    puts "API error: status=#{e.status} code=#{e.code.inspect} request_id=#{e.request_id}"
  end
end

SearchExample.run if $PROGRAM_NAME == __FILE__
