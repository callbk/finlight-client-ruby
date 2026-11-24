# frozen_string_literal: true

# R-SCOPE-1: nothing from API v1/v2 is left, except in the frame decoder (R-WS-1) and the
# wrong-version detection of webhooks (R-HOOK-2).
RSpec.describe "v3-only scope" do
  legacy = %w[includeContent includeEntities extended pageSize publishDate isUpdate]
  spellings = legacy.flat_map do |key|
    snake = Kit.snake(key)
    [key, snake, snake.split("_").map(&:capitalize).join]
  end.uniq

  it "serializes every request type without legacy keys" do
    mock_http.respond({ status: 200, body: { "articles" => [], "pagination" => { "limit" => 1, "returned" => 0,
                                                                                 "hasMore" => false,
                                                                                 "nextCursor" => nil } } })
    all = Kit.snake_args(Kit.load("fixtures/requests/search-all-parameters.json")["sdk"]["args"])
    rest_client.articles.search(**all, cursor: "c")
    bodies = [mock_http.requests[0].body]
    bodies << JSON.generate(Finlight::Params.subscribe_frame(
                              { query: "q", sources: ["a"], exclude_sources: ["b"], opt_in_sources: ["c"],
                                language: "en", tickers: ["X"], countries: ["US"], categories: ["markets"],
                                exclude_empty_content: true, include_updates: true, include: ["content"] }, raw: false
                            ))
    bodies << JSON.generate(Finlight::Params.subscribe_frame(
                              { query: "q", sources: ["a"], exclude_sources: ["b"], language: "en",
                                include_updates: false }, raw: true
                            ))
    bodies.each do |body|
      legacy.each { |key| expect(body).not_to include("\"#{key}\"") }
    end
  end

  it "rejects the legacy keys when a caller slips them in" do
    client = Finlight::Client.new(api_key: "k")
    %i[include_content include_entities extended page_size publish_date].each do |key|
      expect { client.stream(query: "x", key => true) }.to raise_error(Finlight::ValidationError)
      expect { client.raw_stream(query: "x", key => true) }.to raise_error(Finlight::ValidationError)
      expect { client.articles.search(key => true) }.to raise_error(Finlight::ValidationError)
    end
  end

  it "keeps v1/v2 names out of the library source" do
    pattern = Regexp.union([%r{/v1/}, %r{/v2/}, /sendArticle/i, /admin_kick/i] +
                           spellings.map { |s| /#{Regexp.escape(s)}/i })
    allowed = %w[lib/finlight/frames.rb lib/finlight/webhooks.rb]
    hits = Dir.glob(File.join(Kit::ROOT, "lib", "**", "*.rb")).flat_map do |path|
      rel = path.delete_prefix("#{Kit::ROOT}/")
      File.readlines(path).each_with_index.filter_map do |line, i|
        "#{rel}:#{i + 1}: #{line.strip}" if line.match?(pattern) && !allowed.include?(rel)
      end
    end
    expect(hits).to eq([])
  end
end
