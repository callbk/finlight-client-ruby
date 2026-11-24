# frozen_string_literal: true

module Finlight
  # `client.companies`: company lookups (needs the entityAccess entitlement, ForbiddenError otherwise).
  # Each request costs 1 credit from the monthly quota, like an article request. A 304 and error
  # answers cost 1 credit too. The SDK keeps no cache of company records.
  class Companies
    def initialize(http, config)
      @http = http
      @config = config
    end

    def inspect
      "#<Finlight::Companies>"
    end

    # GET /v3/companies?q=…&mic=… (at most 10 results, no pages). Costs 1 credit.
    #
    # @return [CompanyList]
    def search(q, mic: nil)
      Params.string!(q, "q", max: 200, non_empty: true)
      query = [["q", q]]
      query << ["mic", Params.string!(mic, "mic", max: 32, non_empty: true)] unless mic.nil?
      list(query)
    end

    # GET /v3/companies?ids=1,2 (1 to 10 ids; unknown ids are left out; order is not guaranteed).
    # Costs 1 credit per request, not per id.
    #
    # @return [CompanyList]
    def get_many(ids)
      Params.ids!(ids)
      list([["ids", ids.join(",")]])
    end

    # GET /v3/companies/{companyId}.
    #
    # The SDK keeps no cache of company records. The answer's ETag and Cache-Control are in
    # `record.cache_info`; to save credits keep the record yourself and do not call again within
    # max-age. With `if_none_match` (your own ETag) the SDK sends If-None-Match and a 304 returns nil
    # ("not modified"). Without it no If-None-Match is sent. A miss raises NotFoundError.
    # Every call costs 1 credit, a 304 included.
    #
    # @return [CompanyRecord, nil]
    def get(company_id, if_none_match: nil)
      unless company_id.is_a?(Integer) && company_id >= 1
        raise ValidationError.new("company_id must be an Integer >= 1", param: "company_id")
      end

      Params.string!(if_none_match, "if_none_match", non_empty: true) unless if_none_match.nil?
      headers = if_none_match ? { "If-None-Match" => if_none_match } : nil
      response = @http.call("GET", "/v3/companies/#{company_id}", headers: headers, ok: [200, 304])
      return nil if response.status == 304

      json = Decode.parse(response.body, "response")
      record = CompanyRecord.decode(Decode.envelope(json, "company"), "$.company")
      info = CacheInfo.new(etag: response.headers["etag"], cache_control: response.headers["cache-control"],
                           not_modified: false)
      record.__with_cache_info(info)
    end

    private

    def list(query)
      response = @http.call("GET", "/v3/companies", query: query)
      json = Decode.parse(response.body, "response")
      items, skipped = Decode.entries(Decode.envelope(json, "companies"), CompanyRecord, "$.companies",
                                      @config.logger)
      CompanyList.new(items, skipped)
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
    # Costs 1 credit per request, errors included.
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
