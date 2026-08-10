# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Finlight
  # Performs authenticated REST requests with retry and exponential backoff
  # (500ms * 2^(attempt-1)), mirroring the sibling clients: retries on 429 and
  # transient 5xx.
  class ApiClient
    RETRYABLE_STATUSES = [429, 500, 502, 503, 504].freeze
    BASE_RETRY_DELAY = 0.5

    def initialize(config, logger: Logging.default)
      @config = config
      @logger = logger
    end

    # @return [Object] the decoded JSON response
    def get(path, query = {})
      uri = URI.parse(@config.base_url + path)
      uri.query = URI.encode_www_form(query) unless query.empty?
      perform(uri, Net::HTTP::Get.new(uri))
    end

    # @return [Object] the decoded JSON response
    def post(path, body)
      uri = URI.parse(@config.base_url + path)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
      perform(uri, request)
    end

    private

    def perform(uri, request)
      request["X-API-KEY"] = @config.api_key
      request["User-Agent"] = Client::CLIENT_VERSION

      attempt = 0
      loop do
        attempt += 1
        response = execute(uri, request)
        status = response.code.to_i
        return decode(response.body.to_s) if (200..299).cover?(status)

        if RETRYABLE_STATUSES.include?(status) && attempt < @config.retry_count
          delay = BASE_RETRY_DELAY * (2**(attempt - 1))
          @logger.warn do
            "finlight: retrying request (status=#{status}, " \
              "attempt=#{attempt}/#{@config.retry_count}, delay=#{(delay * 1000).round}ms)"
          end
          sleep(delay)
          next
        end

        raise ApiError.new(status, response.body.to_s)
      end
    end

    def execute(uri, request)
      Net::HTTP.start(
        uri.hostname, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: @config.timeout,
        read_timeout: @config.timeout,
        write_timeout: @config.timeout
      ) { |http| http.request(request) }
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout,
           OpenSSL::SSL::SSLError, SystemCallError, IOError => e
      raise Error, "finlight: request failed: #{e.message}"
    end

    def decode(body)
      JSON.parse(body)
    rescue JSON::ParserError => e
      raise Error, "finlight: cannot decode response: #{e.message}"
    end
  end
end
