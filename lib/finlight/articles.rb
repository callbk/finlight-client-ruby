# frozen_string_literal: true

require "json"

module Finlight
  # `client.articles`: search and look up articles.
  class Articles
    def initialize(http, config)
      @http = http
      @config = config
    end

    def inspect
      "#<Finlight::Articles>"
    end

    # One page of POST /v3/articles/search. Only the keywords you pass are sent; a search without
    # keywords sends `{}`. Unknown keywords and wrong shapes raise ValidationError before any request.
    #
    # @return [ArticlePage]
    def search(query: nil, sources: nil, opt_in_sources: nil, exclude_sources: nil, source_types: nil,
               exclude_source_types: nil, from: nil, to: nil, languages: nil, tickers: nil, countries: nil,
               categories: nil, has_content: nil, roles: nil, min_relevance: nil, event_types: nil,
               event_directions: nil, min_importance: nil, sectors: nil, company_countries: nil, exchanges: nil,
               order_by: nil, order: nil, limit: nil, cursor: nil, include: nil, **unknown)
      Params.reject_unknown!(unknown, "articles.search")
      body = Params.search_body(
        query: query, sources: sources, opt_in_sources: opt_in_sources, exclude_sources: exclude_sources,
        source_types: source_types, exclude_source_types: exclude_source_types, from: from, to: to,
        languages: languages, tickers: tickers, countries: countries, categories: categories,
        has_content: has_content, roles: roles, min_relevance: min_relevance, event_types: event_types,
        event_directions: event_directions, min_importance: min_importance, sectors: sectors,
        company_countries: company_countries, exchanges: exchanges, order_by: order_by, order: order,
        limit: limit, cursor: cursor, include: include
      )
      fetch_page(Params.json(body))
    end

    # Walks the pages of a search. The request is frozen when you call this; later pages change only
    # the cursor. Stops at the last page or after `max_pages` pages (every page costs quota).
    # The result can be iterated once.
    #
    # @return [SearchAllResult]
    def search_all(query: nil, sources: nil, opt_in_sources: nil, exclude_sources: nil, source_types: nil,
                   exclude_source_types: nil, from: nil, to: nil, languages: nil, tickers: nil, countries: nil,
                   categories: nil, has_content: nil, roles: nil, min_relevance: nil, event_types: nil,
                   event_directions: nil, min_importance: nil, sectors: nil, company_countries: nil,
                   exchanges: nil, order_by: nil, order: nil, limit: nil, cursor: nil, include: nil,
                   max_pages: nil, **unknown)
      Params.reject_unknown!(unknown, "articles.search_all")
      max_pages = @config.max_pages if max_pages.nil?
      unless max_pages.is_a?(Integer) && max_pages >= 1
        raise ValidationError.new("max_pages must be an Integer >= 1", param: "max_pages")
      end

      body = Params.search_body(
        query: query, sources: sources, opt_in_sources: opt_in_sources, exclude_sources: exclude_sources,
        source_types: source_types, exclude_source_types: exclude_source_types, from: from, to: to,
        languages: languages, tickers: tickers, countries: countries, categories: categories,
        has_content: has_content, roles: roles, min_relevance: min_relevance, event_types: event_types,
        event_directions: event_directions, min_importance: min_importance, sectors: sectors,
        company_countries: company_countries, exchanges: exchanges, order_by: order_by, order: order,
        limit: limit, include: include
      )
      first_cursor = cursor.nil? ? nil : Params.string!(cursor, "cursor")
      SearchAllResult.new(self, Params.json(body).freeze, first_cursor, max_pages, @config.logger)
    end
    # rubocop:enable Metrics/ParameterLists

    # GET /v3/articles/{id}. A miss raises NotFoundError (also for articles indexed before ids existed;
    # use get_by_link for those).
    #
    # @return [Article]
    def get(id, include: nil)
      Params.string!(id, "id", non_empty: true)
      query = include_query(include)
      response = @http.call("GET", "/v3/articles/#{Params.escape(id)}", query: query)
      Decode.article(Decode.parse(response.body, "response"))
    end

    # GET /v3/articles/by-link. The link must equal the delivered `link` exactly.
    #
    # @return [Article]
    def get_by_link(link, include: nil)
      Params.string!(link, "link", non_empty: true)
      query = [["link", link]] + include_query(include)
      response = @http.call("GET", "/v3/articles/by-link", query: query)
      Decode.article(Decode.parse(response.body, "response"))
    end

    # @api private
    def fetch_page(json_body)
      response = @http.call("POST", "/v3/articles/search", body: json_body)
      Decode.article_page(Decode.parse(response.body, "response"), @config.logger)
    end

    private

    def include_query(include)
      return [] if include.nil?

      list = Params.include!(include)
      list ? [["include", list.join(",")]] : []
    end
  end

  # Result of articles.search_all. Iterate it once: `each` gives articles, `pages` gives pages.
  # Errors (a monthly 429 included) come out of the iteration.
  class SearchAllResult
    include Enumerable

    # @return [String, nil] the last nextCursor seen; use it to continue after `max_pages`
    attr_reader :next_cursor
    # @return [Integer] pages fetched so far
    attr_reader :pages_fetched

    def initialize(articles, frozen_body, first_cursor, max_pages, logger)
      @articles = articles
      @frozen_body = frozen_body
      @first_cursor = first_cursor
      @max_pages = max_pages
      @logger = logger
      @started = false
      @truncated = false
      @next_cursor = nil
      @pages_fetched = 0
      @mutex = Mutex.new
    end

    def inspect
      "#<Finlight::SearchAllResult pages_fetched=#{@pages_fetched} truncated=#{@truncated}>"
    end

    # @return [Boolean] true when max_pages stopped the walk while more pages were left
    def truncated?
      @truncated
    end

    # Yields every article of every page.
    def each(&block)
      return enum_for(:each) unless block

      walk { |page| page.articles.each(&block) }
      self
    end

    # @return [Enumerator<ArticlePage>] the pages (counts as the one iteration)
    def pages
      Enumerator.new { |y| walk { |page| y << page } }
    end

    private

    def walk
      @mutex.synchronize do
        raise ValidationError, "a search_all result can be iterated only once; call search_all again" if @started

        @started = true
      end
      cursor = @first_cursor
      loop do
        page = @articles.fetch_page(body_for(cursor))
        @pages_fetched += 1
        @next_cursor = page.pagination.next_cursor
        yield page
        break if page.pagination.has_more != true || @next_cursor.nil?

        if @pages_fetched >= @max_pages
          @truncated = true
          @logger.warn("finlight") do
            "search_all stopped after max_pages=#{@max_pages}; continue with the cursor in next_cursor"
          end
          break
        end
        cursor = @next_cursor
      end
    end

    # The frozen page-1 body with only the cursor added.
    def body_for(cursor)
      return @frozen_body if cursor.nil?

      prefix = @frozen_body[0..-2]
      separator = prefix == "{" ? "" : ","
      "#{prefix}#{separator}\"cursor\":#{JSON.generate(cursor)}}"
    end
  end
end
