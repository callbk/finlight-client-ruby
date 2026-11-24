# frozen_string_literal: true

require "net/http"
require "openssl"
require "securerandom"
require "time"
require "uri"
require "zlib"

module Finlight
  # REST transport: one X-Request-Id per logical call, an explicit retry loop, no hidden retries
  # in Net::HTTP. Internal.
  class HttpTransport
    Response = Struct.new(:status, :headers, :body, :request_id)

    NETWORK_ERRORS = [
      IOError, EOFError, SocketError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse,
      Net::ProtocolError, Zlib::Error
    ].freeze
    TIMEOUT_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, ::Timeout::Error].freeze

    class TooLarge < StandardError; end

    def initialize(config)
      @config = config
      @random = Random.new
    end

    def inspect
      "#<Finlight::HttpTransport base_url=#{@config.base_url.inspect}>"
    end

    # Runs one logical call and returns the Response for an ok status; raises ApiError otherwise.
    def call(method, path, query: nil, body: nil, headers: nil, ok: [200])
      cfg = @config
      url = cfg.rest_url(path)
      url += "?#{Params.query_string(query)}" if query && !query.empty?
      request_id = SecureRandom.uuid
      send_headers = {
        "X-API-KEY" => cfg.api_key,
        "User-Agent" => USER_AGENT,
        "x-client-version" => VERSION,
        "X-Request-Id" => request_id,
        "Accept" => "application/json"
      }
      send_headers["Content-Type"] = "application/json" unless body.nil?
      send_headers.merge!(headers) if headers

      clock = cfg.clock
      deadline = cfg.total_timeout ? clock.monotonic + cfg.total_timeout : nil
      attempt = 0
      burst_used = false
      loop do
        timeout = cfg.timeout
        if deadline
          remaining = deadline - clock.monotonic
          raise TimeoutError, "call ran out of its total time (#{cfg.total_timeout} s)" if remaining <= 0

          timeout = [timeout, remaining].min
        end

        error = nil
        begin
          status, resp_headers, resp_body = send_once(method, url, send_headers, body, timeout)
        rescue NetworkError => e
          error = e
          log(:debug) { "#{method} #{path} failed (#{e.kind}), request id #{request_id}" }
        end

        unless error
          log(:debug) { "#{method} #{path} -> #{status}, request id #{request_id}" }
          return Response.new(status, resp_headers, resp_body, request_id) if ok.include?(status)

          api_error = ErrorParser.from_response(
            status, resp_headers["content-type"], resp_body,
            sent_request_id: request_id, retry_after: parse_retry_after(resp_headers["retry-after"])
          )
          if api_error.is_a?(RateLimitedError)
            raise api_error unless api_error.limit_type == RateLimitType::BURST &&
                                   cfg.retry_on_burst == "once" && !burst_used

            # Contract: wait exactly Retry-After seconds, burst_wait when the header is missing.
            wait = api_error.retry_after || cfg.burst_wait
            raise api_error if deadline && clock.monotonic + wait > deadline

            log(:warn) { format("burst limit reached, retrying once in %.1f s (request id %s)", wait, request_id) }
            burst_used = true
            clock.sleep(wait)
            next
          end
          raise api_error if status < 500

          error = api_error
        end

        raise error if attempt >= cfg.max_retries

        delay = [cfg.retry_max_delay, cfg.retry_base_delay * (2**attempt)].min
        delay *= 0.5 + (0.5 * @random.rand)
        attempt += 1
        raise error if deadline && clock.monotonic + delay > deadline

        log(:info) do
          format("retry %d/%d in %.2f s after %s (request id %s)", attempt, cfg.max_retries, delay,
                 describe(error), request_id)
        end
        clock.sleep(delay)
      end
    end

    private

    def log(level, &)
      @config.logger.public_send(level, "finlight", &)
    end

    def describe(error)
      error.is_a?(ApiError) ? "HTTP #{error.status}" : error.class.name
    end

    def parse_retry_after(value)
      return nil if value.nil? || value.strip.empty?

      text = value.strip
      if text.match?(/\A\d+(\.\d+)?\z/)
        text.to_f
      else
        [Time.httpdate(text) - Time.now, 0.0].max
      end
    rescue ArgumentError
      nil
    end

    # One attempt. Returns [status, headers (lowercase names), body]. Raises NetworkError/TimeoutError.
    def send_once(method, url, headers, body, timeout)
      if @config.http_client
        send_custom(method, url, headers, body)
      else
        send_net_http(method, url, headers, body, timeout)
      end
    rescue TooLarge
      raise DecodeError, "response is larger than #{@config.max_response_bytes} bytes"
    end

    def send_custom(method, url, headers, body)
      status, resp_headers, resp_body = @config.http_client.call(method, url, headers.dup, body)
      resp_body = resp_body.to_s
      raise TooLarge if resp_body.bytesize > @config.max_response_bytes

      [Integer(status), normalize_headers(resp_headers), resp_body]
    rescue NetworkError, DecodeError, TooLarge
      raise
    rescue *TIMEOUT_ERRORS => e
      raise TimeoutError, "request timed out (#{e.class.name})"
    rescue StandardError => e
      raise NetworkError, "network error: #{e.class.name}"
    end

    def normalize_headers(headers)
      (headers || {}).each_with_object({}) do |(name, value), out|
        out[name.to_s.downcase] = value.is_a?(Array) ? value.join(", ") : value.to_s
      end
    end

    def send_net_http(method, url, headers, body, timeout)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout
      http.write_timeout = timeout
      http.max_retries = 0 # no hidden retries: every attempt costs quota
      request = build_request(method, uri, headers, body)
      limit = @config.max_response_bytes
      http.start do |conn|
        conn.request(request) do |response|
          chunks = +""
          response.read_body do |chunk|
            chunks << chunk
            raise TooLarge if chunks.bytesize > limit
          end
          resp_headers = response.each_header.to_h { |k, v| [k.downcase, v] }
          return [response.code.to_i, resp_headers, chunks]
        end
      end
    rescue TooLarge
      raise
    rescue *TIMEOUT_ERRORS => e
      raise TimeoutError, "request timed out after #{timeout} s (#{e.class.name})"
    rescue *NETWORK_ERRORS => e
      raise NetworkError, "network error: #{e.class.name}"
    end

    def build_request(method, uri, headers, body)
      klass = { "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post }.fetch(method)
      request = klass.new(uri.request_uri)
      headers.each { |name, value| request[name] = value }
      request.body = body unless body.nil?
      request
    end
  end
end
