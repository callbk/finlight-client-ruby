# frozen_string_literal: true

# Look up articles, companies and sources. Run: FINLIGHT_API_KEY=... ruby examples/lookup.rb

require "finlight"

module LookupExample
  def self.run
    client = Finlight::Client.new(api_key: ENV.fetch("FINLIGHT_API_KEY"),
                                  **{ base_url: ENV.fetch("FINLIGHT_BASE_URL", nil) }.compact)
    first = client.articles.search(query: "ticker:NVDA", limit: 1).articles.first
    if first
      by_link = client.articles.get_by_link(first.link, include: ["content"])
      puts "by link: #{by_link.title} | content present: #{by_link.content_present?}"
      puts "by id: #{client.articles.get(first.id).id}"
    end
    begin
      client.articles.get("does-not-exist")
    rescue Finlight::NotFoundError => e
      puts "not found: #{e.detail}"
    end

    # Company data needs the entityAccess entitlement (ForbiddenError otherwise).
    matches = client.companies.search("NVDA", mic: "XNAS")
    matches.each { |c| puts "company: #{c.company_id} #{c.name} #{c.listings.map(&:mic).join(",")}" }
    if matches.any?
      record = client.companies.get(matches.first.company_id) # revalidated with its ETag next time
      puts "record: #{record.name} #{record.sector} etag: #{record.cache_info&.etag}"
    end

    sources = client.sources.list
    puts "#{sources.size} sources, e.g. #{sources.first(3).map(&:domain).join(", ")}"
  rescue Finlight::ApiError => e
    puts "API error: status=#{e.status} code=#{e.code.inspect} request_id=#{e.request_id}"
  end
end

LookupExample.run if $PROGRAM_NAME == __FILE__
