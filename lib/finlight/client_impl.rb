# frozen_string_literal: true

module Finlight
  # The finlight API v3 client.
  #
  #   client = Finlight::Client.new(api_key: ENV.fetch("FINLIGHT_API_KEY"))
  #   page = client.articles.search(query: "ticker:NVDA", limit: 10)
  #
  # The client is safe to share between threads and can run several streams at once.
  class Client
    # @return [Config]
    attr_reader :config
    # @return [Articles]
    attr_reader :articles
    # @return [Companies]
    attr_reader :companies
    # @return [Sources]
    attr_reader :sources

    # @param config [Config, nil] a ready Config; or pass its keys as keywords (api_key: required)
    def initialize(config: nil, **options)
      if config
        raise ValidationError.new("pass either config: or keywords, not both", param: "config") unless options.empty?
        raise ValidationError.new("config must be a Finlight::Config", param: "config") unless config.is_a?(Config)

        @config = config
      else
        raise ValidationError.new("api_key must be a non-empty String", param: "api_key") unless options.key?(:api_key)

        @config = Config.new(**options)
      end
      http = HttpTransport.new(@config)
      @articles = Articles.new(http, @config)
      @companies = Companies.new(http, @config)
      @sources = Sources.new(http, @config)
      @streams = {}
      @mutex = Mutex.new
    end

    def inspect
      "#<Finlight::Client base_url=#{@config.base_url.inspect}>"
    end
    alias to_s inspect

    # Opens an enriched stream (`<wss_url>`). Nothing connects until you iterate it.
    #
    # Hooks: on_admitted(AdmittedInfo), on_reconnect(ReconnectInfo), on_error(Error),
    # on_quota_wait(QuotaWaitInfo). They run on the iterating thread.
    #
    # @param takeover [Boolean] replace the stalest connection when your connection limit is reached
    # @return [Stream]
    def stream(query: nil, sources: nil, exclude_sources: nil, opt_in_sources: nil, source_types: nil,
               exclude_source_types: nil, language: nil, tickers: nil, countries: nil, categories: nil,
               exclude_empty_content: nil, include_updates: nil, include: nil, takeover: false, on_admitted: nil,
               on_reconnect: nil, on_error: nil, on_quota_wait: nil, **unknown)
      Params.reject_unknown!(unknown, "stream")
      frame = Params.subscribe_frame(
        { query: query, sources: sources, exclude_sources: exclude_sources, opt_in_sources: opt_in_sources,
          source_types: source_types, exclude_source_types: exclude_source_types, language: language,
          tickers: tickers, countries: countries, categories: categories,
          exclude_empty_content: exclude_empty_content, include_updates: include_updates, include: include },
        raw: false
      )
      open_stream(frame, false, takeover, on_admitted: on_admitted, on_reconnect: on_reconnect, on_error: on_error,
                                          on_quota_wait: on_quota_wait)
    end

    # Opens a raw stream (`<wss_url>/raw`): articles before enrichment, without content, sentiment,
    # companies or events. It takes no `include`.
    #
    # @return [Stream]
    def raw_stream(query: nil, sources: nil, exclude_sources: nil, source_types: nil, exclude_source_types: nil,
                   language: nil, include_updates: nil, takeover: false, on_admitted: nil, on_reconnect: nil,
                   on_error: nil, on_quota_wait: nil, **unknown)
      if unknown.key?(:include)
        raise ValidationError.new("raw streams take no include: the server would close the connection",
                                  param: "include")
      end
      Params.reject_unknown!(unknown, "raw_stream")
      frame = Params.subscribe_frame(
        { query: query, sources: sources, exclude_sources: exclude_sources, source_types: source_types,
          exclude_source_types: exclude_source_types, language: language, include_updates: include_updates },
        raw: true
      )
      open_stream(frame, true, takeover, on_admitted: on_admitted, on_reconnect: on_reconnect, on_error: on_error,
                                         on_quota_wait: on_quota_wait)
    end
    # rubocop:enable Metrics/ParameterLists

    # Closes every stream this client opened that is still running.
    def close
      streams = @mutex.synchronize { @streams.keys }
      streams.each(&:close)
      nil
    end

    private

    def open_stream(frame, raw, takeover, **hooks)
      Params.bool!(takeover, "takeover")
      hooks.each do |name, hook|
        next if hook.nil? || hook.respond_to?(:call)

        raise ValidationError.new("#{name} must respond to call", param: name.to_s)
      end
      stream = Stream.new(@config, frame, raw: raw, takeover: takeover, hooks: hooks,
                                          on_close: ->(s) { @mutex.synchronize { @streams.delete(s) } })
      @mutex.synchronize { @streams[stream] = true }
      stream
    end
  end
end
