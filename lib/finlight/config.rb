# frozen_string_literal: true

module Finlight
  # Connection settings shared by the REST and WebSocket clients.
  class Config
    DEFAULT_BASE_URL = "https://api.finlight.me"
    DEFAULT_WSS_URL = "wss://wss.finlight.me"
    DEFAULT_TIMEOUT = 5
    DEFAULT_RETRY_COUNT = 3

    attr_reader :api_key, :base_url, :wss_url, :timeout, :retry_count

    # @param api_key [String] your finlight API key
    # @param base_url [String] REST endpoint
    # @param wss_url [String] WebSocket endpoint
    # @param timeout [Numeric] per-request and connect timeout in seconds
    # @param retry_count [Integer] total attempts for retryable failures (429/5xx)
    def initialize(api_key:, base_url: DEFAULT_BASE_URL, wss_url: DEFAULT_WSS_URL,
                   timeout: DEFAULT_TIMEOUT, retry_count: DEFAULT_RETRY_COUNT)
      raise ArgumentError, "api_key is required" if api_key.nil? || api_key.to_s.empty?

      @api_key = api_key
      @base_url = base_url.chomp("/")
      @wss_url = wss_url.chomp("/")
      @timeout = timeout
      @retry_count = retry_count
    end
  end
end
