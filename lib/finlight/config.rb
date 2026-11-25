# frozen_string_literal: true

require "logger"

module Finlight
  # The system clock. Replace it through Config#clock in tests: any object with
  # `monotonic` (Float seconds) and `sleep(seconds)` works. `sleep` may return early;
  # the SDK checks the time again after every wake-up.
  class SystemClock
    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def sleep(seconds)
      Kernel.sleep(seconds) if seconds.positive?
    end
  end

  # Client configuration. All times are seconds (Float). Every key can be set as a keyword of
  # Client.new or of Config.new.
  class Config
    DEFAULT_BASE_URL = "https://api.finlight.me"
    DEFAULT_WSS_URL = "wss://wss.finlight.me"

    DEFAULTS = {
      base_url: DEFAULT_BASE_URL,
      wss_url: DEFAULT_WSS_URL,
      timeout: 30.0,
      total_timeout: nil,
      max_retries: 3,
      retry_base_delay: 0.5,
      retry_max_delay: 8.0,
      retry_on_burst: "once",
      burst_wait: 10.0,
      max_pages: 10,
      max_response_bytes: 32 * 1024 * 1024,
      ping_interval: 25.0,
      watchdog_timeout: 60.0,
      rotation_interval: 115 * 60.0,
      reconnect_base_delay: 1.0,
      reconnect_max_delay: 30.0,
      long_backoff: 60.0,
      quota_reconnect: true,
      quota_reconnect_interval: 3600.0,
      search_failed_threshold: 5,
      dedupe_cache_size: 1000,
      max_message_bytes: 32 * 1024 * 1024,
      connect_timeout: 30.0,
      logger: nil,
      clock: nil,
      http_client: nil,
      ws_connect: nil
    }.freeze

    KEYS = ([:api_key] + DEFAULTS.keys).freeze

    attr_reader(*DEFAULTS.keys)

    # @param api_key [String] required, not empty
    # @param base_url [String] REST base URL (a trailing slash is fine)
    # @param wss_url [String] WebSocket URL; raw streams use `<wss_url>/raw`
    # @param timeout [Numeric] seconds per REST attempt
    # @param total_timeout [Numeric, nil] cap per REST call, retries and burst wait included
    # @param max_retries [Integer] retries for 5xx, network errors and timeouts
    # @param retry_base_delay [Numeric] first retry wait (doubles, with jitter)
    # @param retry_max_delay [Numeric] longest retry wait
    # @param retry_on_burst [String] "once" (wait Retry-After, then retry once) or "off"
    # @param burst_wait [Numeric] burst wait when the 429 has no Retry-After
    # @param max_pages [Integer] default page cap of search_all
    # @param max_response_bytes [Integer] size cap of a REST response
    # @param ping_interval [Numeric] stream ping interval
    # @param watchdog_timeout [Numeric] reconnect after this long without a pong
    # @param rotation_interval [Numeric] open a fresh connection after this long
    # @param reconnect_base_delay [Numeric] first reconnect wait (doubles, with jitter)
    # @param reconnect_max_delay [Numeric] longest reconnect wait
    # @param long_backoff [Numeric] wait after "too many connections" or a dial 429
    # @param quota_reconnect [Boolean] wait for the monthly WebSocket quota instead of ending the stream
    # @param quota_reconnect_interval [Numeric] wait between quota attempts
    # @param search_failed_threshold [Integer] SEARCH_FAILED in a row before on_error hears about it
    # @param dedupe_cache_size [Integer] remembered deliveries per stream
    # @param max_message_bytes [Integer] largest incoming WebSocket message
    # @param connect_timeout [Numeric] WebSocket dial and handshake timeout
    # @param logger [Logger, nil] standard Logger; nil = silent
    # @param clock [#monotonic, #sleep, nil] replaceable clock (tests)
    # @param http_client [#call, nil] your own REST transport, see README
    # @param ws_connect [#call, nil] your own WebSocket transport, see README
    def initialize(api_key:, **options)
      unknown = options.keys - DEFAULTS.keys
      raise ValidationError.new("unknown config key: #{unknown.first}", param: unknown.first.to_s) if unknown.any?
      unless api_key.is_a?(String) && !api_key.strip.empty?
        raise ValidationError.new("api_key must be a non-empty String", param: "api_key")
      end

      @api_key = api_key
      DEFAULTS.each { |key, default| instance_variable_set(:"@#{key}", options.fetch(key, default)) }
      @retry_on_burst = @retry_on_burst.to_s
      @logger ||= Logger.new(nil, progname: "finlight")
      @clock ||= SystemClock.new
      validate!
      freeze
    end

    # @return [String]
    attr_reader :api_key

    # @return [Config] a copy with some keys changed
    def with(**changes)
      Config.new(api_key: changes.fetch(:api_key, @api_key),
                 **DEFAULTS.keys.to_h { |k| [k, changes.fetch(k, instance_variable_get(:"@#{k}"))] })
    end

    # @api private
    def rest_url(path)
      "#{@base_url.to_s.sub(%r{/+\z}, "")}#{path}"
    end

    # @api private
    def ws_url(raw)
      base = @wss_url.to_s.sub(%r{/+\z}, "")
      raw ? "#{base}/raw" : base
    end

    def inspect
      "#<Finlight::Config base_url=#{@base_url.inspect} wss_url=#{@wss_url.inspect} api_key=[REDACTED]>"
    end
    alias to_s inspect

    private

    def validate!
      %i[base_url wss_url].each do |key|
        value = instance_variable_get(:"@#{key}")
        raise ValidationError.new("#{key} must be a URL String", param: key.to_s) unless value.is_a?(String)
      end
      %i[timeout retry_base_delay retry_max_delay burst_wait ping_interval watchdog_timeout rotation_interval
         reconnect_base_delay reconnect_max_delay long_backoff quota_reconnect_interval connect_timeout].each do |key|
        positive_number!(key)
      end
      positive_number!(:total_timeout) unless @total_timeout.nil?
      integer!(:max_retries, 0)
      %i[max_pages max_response_bytes search_failed_threshold dedupe_cache_size].each { |key| integer!(key, 1) }
      integer!(:max_message_bytes, 16 * 1024 * 1024)
      unless %w[once off].include?(@retry_on_burst)
        raise ValidationError.new('retry_on_burst must be "once" or "off"', param: "retry_on_burst")
      end
      raise ValidationError.new("quota_reconnect must be true or false", param: "quota_reconnect") unless
        [true, false].include?(@quota_reconnect)
    end

    def positive_number!(key)
      value = instance_variable_get(:"@#{key}")
      return if value.is_a?(Numeric) && value.positive?

      raise ValidationError.new("#{key} must be a positive number of seconds", param: key.to_s)
    end

    def integer!(key, min)
      value = instance_variable_get(:"@#{key}")
      return if value.is_a?(Integer) && value >= min

      raise ValidationError.new("#{key} must be an Integer >= #{min}", param: key.to_s)
    end
  end

  # Internal: not part of the public API (only the sdk-style name table is), may change in any release.
  private_constant :SystemClock
end
