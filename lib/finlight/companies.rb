# frozen_string_literal: true

module Finlight
  # `client.companies`: company lookups (needs the entityAccess entitlement, ForbiddenError otherwise).
  class Companies
    def initialize(http, config)
      @http = http
      @config = config
      @cache = {}
      @mutex = Mutex.new
    end

    def inspect
      "#<Finlight::Companies>"
    end

    # GET /v3/companies?q=…&mic=… (at most 10 results, no pages).
    #
    # @return [CompanyList]
    def search(q, mic: nil)
      Params.string!(q, "q", max: 200, non_empty: true)
      query = [["q", q]]
      query << ["mic", Params.string!(mic, "mic", max: 32, non_empty: true)] unless mic.nil?
      list(query)
    end

    # GET /v3/companies?ids=1,2 (1 to 10 ids; unknown ids are left out; order is not guaranteed).
    #
    # @return [CompanyList]
    def get_many(ids)
      Params.ids!(ids)
      list([["ids", ids.join(",")]])
    end

    # GET /v3/companies/{companyId}.
    #
    # With `if_none_match` (your own ETag) a 304 returns nil ("not modified"). Without it the SDK
    # revalidates its own cached copy and returns that copy on 304. A miss raises NotFoundError.
    #
    # @return [CompanyRecord, nil]
    def get(company_id, if_none_match: nil)
      unless company_id.is_a?(Integer) && company_id >= 1
        raise ValidationError.new("company_id must be an Integer >= 1", param: "company_id")
      end

      Params.string!(if_none_match, "if_none_match", non_empty: true) unless if_none_match.nil?
      cached = if_none_match.nil? ? cache_get(company_id) : nil
      etag = if_none_match || cached&.cache_info&.etag
      headers = etag ? { "If-None-Match" => etag } : nil
      response = @http.call("GET", "/v3/companies/#{company_id}", headers: headers, ok: [200, 304])
      if response.status == 304
        return nil unless if_none_match.nil? && cached

        info = CacheInfo.new(etag: response.headers["etag"] || etag,
                             cache_control: response.headers["cache-control"] || cached.cache_info.cache_control,
                             not_modified: true)
        record = cached.__with_cache_info(info)
        cache_put(company_id, record)
        return record
      end

      json = Decode.parse(response.body, "response")
      record = CompanyRecord.decode(Decode.envelope(json, "company"), "$.company")
      info = CacheInfo.new(etag: response.headers["etag"], cache_control: response.headers["cache-control"],
                           not_modified: false)
      record = record.__with_cache_info(info)
      cache_put(company_id, record) if info.etag
      record
    end

    private

    def list(query)
      response = @http.call("GET", "/v3/companies", query: query)
      json = Decode.parse(response.body, "response")
      items, skipped = Decode.entries(Decode.envelope(json, "companies"), CompanyRecord, "$.companies",
                                      @config.logger)
      CompanyList.new(items, skipped)
    end

    def cache_get(id)
      return nil if @config.company_cache_size.zero?

      @mutex.synchronize do
        record = @cache.delete(id)
        @cache[id] = record if record
        record
      end
    end

    def cache_put(id, record)
      return if @config.company_cache_size.zero?

      @mutex.synchronize do
        @cache.delete(id)
        @cache[id] = record
        @cache.shift while @cache.size > @config.company_cache_size
      end
    end
  end

  # `client.sources`: the sources your plan can see.
  class Sources
    def initialize(http, config)
      @http = http
      @config = config
    end

    def inspect
      "#<Finlight::Sources>"
    end

    # GET /v3/sources, sorted by domain. `has_content` is nil without full-article access.
    #
    # @return [SourceList]
    def list
      response = @http.call("GET", "/v3/sources")
      json = Decode.parse(response.body, "response")
      items, skipped = Decode.entries(Decode.envelope(json, "sources"), Source, "$.sources", @config.logger)
      SourceList.new(items, skipped)
    end
  end
end
