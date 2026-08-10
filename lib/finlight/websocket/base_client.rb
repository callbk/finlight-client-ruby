# frozen_string_literal: true

require "json"
require "openssl"
require "securerandom"
require "socket"
require "uri"
require "websocket/driver"

module Finlight
  # Shared implementation of the finlight streaming protocol: reconnect loop
  # with exponential backoff, application-level ping/pong with watchdog,
  # proactive connection rotation before the server-side lifetime cap, and
  # optional duplicate suppression.
  #
  # Use the concrete {ArticleWebSocketClient} and {RawArticleWebSocketClient}
  # obtained from {Client#websocket} and {Client#raw_websocket}.
  class BaseWebSocketClient
    RECENT_ARTICLE_CACHE_SIZE = 10
    CLOSE_GRACE_SECONDS = 5
    DIAL_RATE_LIMIT_BACKOFF_SECONDS = 60
    ERROR_RATE_LIMIT_BACKOFF_SECONDS = 60
    ERROR_BLOCKED_BACKOFF_SECONDS = 3600
    DEFAULT_ADMIN_KICK_RETRY_MS = 900_000

    # Close codes of the finlight WebSocket protocol.
    CLOSE_BLOCKED = 1008
    CLOSE_PROACTIVE_ROTATION = 4000
    CLOSE_RATE_LIMITED = 4001
    CLOSE_USER_BLOCKED = 4002
    CLOSE_ADMIN_KICK = 4003

    # Adapter between websocket-driver and the raw socket.
    class DriverSocket
      attr_reader :url

      def initialize(url, io)
        @url = url
        @io = io
      end

      def write(data)
        @io.write(data)
      rescue StandardError
        # The connection is going down; the read loop notices independently.
      end
    end

    # @param config [Config]
    # @param ping_interval [Numeric] seconds between application-level pings
    # @param pong_timeout [Numeric] seconds without a pong before forcing a reconnect
    # @param base_reconnect_delay [Numeric] initial reconnect backoff in seconds
    # @param max_reconnect_delay [Numeric] backoff cap in seconds
    # @param connection_lifetime [Numeric] seconds before proactively rotating
    #   the connection (server caps connections at 2h)
    # @param takeover [Boolean] take over an existing connection for the same key
    # @param on_close [#call, nil] callback invoked with (code, reason) whenever
    #   a connection closes
    def initialize(config, ping_interval: 25, pong_timeout: 60,
                   base_reconnect_delay: 0.5, max_reconnect_delay: 10.0,
                   connection_lifetime: 115 * 60, takeover: false, on_close: nil,
                   logger: Logging.default)
      @config = config
      @ping_interval = ping_interval
      @pong_timeout = pong_timeout
      @base_reconnect_delay = base_reconnect_delay
      @max_reconnect_delay = max_reconnect_delay
      @connection_lifetime = connection_lifetime
      @takeover = takeover
      @on_close = on_close
      @logger = logger
      @stop = false
      @running = false
      @recent_articles = []
    end

    # Connects to the stream and blocks, yielding every received article.
    # Reconnects automatically (exponential backoff, honors server-mandated
    # wait times) until {#stop} is called or the server preempts the
    # connection in favor of a newer one.
    #
    # @param params [Hash] stream filters as snake_case keywords, e.g.
    #   +query:+, +sources:+, +exclude_sources:+, +language:+, +tickers:+,
    #   +extended:+, +include_entities:+, +exclude_empty_content:+,
    #   +countries:+, +categories:+, +include_updates:+
    # @yield [article] every article received on the stream
    # @raise [BlockedError] if the server permanently rejected the connection
    #   (close code 1008)
    def connect(**params, &on_article)
      raise ArgumentError, "finlight: connect requires a block" unless on_article
      raise Error, "finlight: connect is already running on this client" if @running

      @running = true
      @stop = false
      @reconnect_at = nil
      payload = Params.normalize(params)
      delay = @base_reconnect_delay

      begin
        until @stop
          @logger.info { "finlight: connecting to #{websocket_url}" }
          result = run_connection(payload, on_article)
          raise BlockedError if result == :blocked
          break if @stop

          delay = @base_reconnect_delay if result == :connected

          now = monotonic
          if @reconnect_at && @reconnect_at > now
            wait = @reconnect_at - now
            @logger.info { "finlight: waiting #{wait.round(1)}s until server-mandated reconnect time" }
          else
            wait = delay
            @logger.info { "finlight: reconnecting in #{wait.round(1)}s" }
            delay = [delay * 2, @max_reconnect_delay].min
          end
          interruptible_sleep(wait)
        end
      ensure
        @running = false
      end
      nil
    end

    # Runs {#connect} on a background thread and returns it. Joining the
    # thread re-raises {BlockedError} if the stream ended that way.
    #
    # @return [Thread]
    def connect_async(**params, &on_article)
      Thread.new do
        Thread.current.report_on_exception = false
        connect(**params, &on_article)
      end
    end

    # Stops the stream: the current connection closes and the reconnect loop
    # ends. Safe to call from any thread; {#connect} returns shortly after.
    def stop
      @stop = true
      nil
    end

    private

    # @return [String] the full WebSocket URL to connect to
    def websocket_url
      raise NotImplementedError
    end

    # @return [Object] the parsed article for a sendArticle payload
    def parse_article(data)
      raise NotImplementedError
    end

    # Identifier used for duplicate suppression, or nil to disable it.
    def article_id(_article)
      nil
    end

    def run_connection(payload, on_article)
      uri = URI.parse(websocket_url)
      begin
        io = dial(uri)
      rescue StandardError => e
        @logger.error { "finlight: connection failed: #{e.message}" }
        return :failed
      end

      begin
        run_stream(io, payload, on_article)
      ensure
        begin
          io.close
        rescue StandardError
          nil
        end
      end
    end

    def dial(uri)
      host = uri.host
      secure = %w[wss https].include?(uri.scheme)
      port = uri.port || (secure ? 443 : 80)
      tcp = Socket.tcp(host, port, connect_timeout: @config.timeout)
      return tcp unless secure

      context = OpenSSL::SSL::SSLContext.new
      context.verify_mode = OpenSSL::SSL::VERIFY_PEER
      context.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
      ssl.hostname = host
      ssl.sync_close = true
      ssl.connect
      ssl.post_connection_check(host)
      ssl
    end

    def run_stream(io, payload, on_article)
      state = {
        opened: false, closed: nil, error: nil, stop_sent: false,
        last_pong: monotonic, next_ping: nil, abort_at: nil,
        rotate_at: monotonic + @connection_lifetime
      }
      nonce = SecureRandom.uuid

      # The server reads these headers case-sensitively in exact lowercase.
      driver = WebSocket::Driver.client(DriverSocket.new(websocket_url, io))
      driver.set_header("x-api-key", @config.api_key)
      driver.set_header("x-client-version", Client::CLIENT_VERSION)
      driver.set_header("x-takeover", "true") if @takeover

      driver.on(:open) do
        state[:opened] = true
        state[:last_pong] = monotonic
        state[:next_ping] = monotonic + @ping_interval
        @reconnect_at = nil
        @logger.info { "finlight: connected" }
        driver.text(JSON.generate(payload.merge("clientNonce" => nonce)))
      end
      driver.on(:message) { |event| handle_message(event.data, driver, state, nonce, on_article) }
      driver.on(:close) { |event| state[:closed] ||= [event.code || 1006, event.reason.to_s] }
      driver.on(:error) { |event| handle_driver_error(event.message.to_s, state) }

      queue = Thread::Queue.new
      reader = Thread.new do
        Thread.current.report_on_exception = false
        begin
          loop { queue << io.readpartial(16_384) }
        rescue StandardError
          queue << :eof
        end
      end

      driver.start
      pump(driver, queue, state)

      close_code, close_reason = state[:closed] || [1006, state[:error] || "connection lost"]
      @logger.info { "finlight: connection closed: #{close_code} - #{close_reason}" }
      notify_close(close_code, close_reason)

      return :blocked if close_code == CLOSE_BLOCKED

      state[:opened] ? :connected : :failed
    ensure
      reader&.kill
    end

    def pump(driver, queue, state)
      until state[:closed]
        break if state[:error] && !state[:opened]

        if @stop
          break unless state[:opened]

          request_close(driver, state, "client stopped", 1000)
        end

        chunk = queue.pop(timeout: 0.2)
        if chunk == :eof
          state[:closed] ||= [1006, "connection lost"]
          break
        end
        driver.parse(chunk) if chunk

        now = monotonic
        if state[:opened]
          if state[:next_ping] && now >= state[:next_ping]
            @logger.debug { "finlight: sending ping" }
            driver.text(JSON.generate({ "action" => "ping", "t" => wallclock_millis }))
            state[:next_ping] = now + @ping_interval
          end
          if now - state[:last_pong] > @pong_timeout
            @logger.warn { "finlight: no pong received in time, forcing reconnect" }
            break
          end
          if now >= state[:rotate_at]
            @logger.info { "finlight: proactive rotation before server connection cap" }
            state[:rotate_at] = Float::INFINITY
            request_close(driver, state, "Proactive rotation", CLOSE_PROACTIVE_ROTATION)
          end
        end
        break if state[:abort_at] && now >= state[:abort_at]
      end
    end

    def handle_message(data, driver, state, nonce, on_article)
      msg = begin
        JSON.parse(data)
      rescue JSON::ParserError => e
        @logger.error { "finlight: cannot parse message: #{e.message}" }
        nil
      end
      return unless msg.is_a?(Hash)

      case msg["action"]
      when "pong"
        ping_time = msg["t"]
        if ping_time
          @logger.debug { "finlight: pong received (rtt=#{wallclock_millis - ping_time.to_i}ms)" }
        else
          @logger.debug { "finlight: pong received" }
        end
        state[:last_pong] = monotonic
      when "admit"
        @logger.info { "finlight: admitted (leaseId=#{msg["leaseId"]})" }
        server_nonce = msg["clientNonce"].to_s
        if !server_nonce.empty? && server_nonce != nonce
          @logger.warn { "finlight: nonce mismatch: expected #{nonce}, got #{server_nonce}" }
        end
      when "preempted"
        @logger.warn do
          "finlight: connection preempted: #{msg.fetch("reason", "unknown")} " \
            "(new lease: #{msg["newLeaseId"]})"
        end
        @stop = true
        request_close(driver, state, "Preempted by server", 1000)
      when "sendArticle"
        handle_article(msg["data"] || {}, on_article)
      when "admin_kick"
        retry_after_ms = msg.fetch("retryAfter", DEFAULT_ADMIN_KICK_RETRY_MS).to_i
        @reconnect_at = monotonic + (retry_after_ms / 1000.0)
        @logger.warn { "finlight: admin kick - retry after #{retry_after_ms}ms" }
        request_close(driver, state, "Admin kick", CLOSE_ADMIN_KICK)
      when "error"
        raw = msg["data"] || msg["error"] || ""
        text = raw.is_a?(String) ? raw : JSON.generate(raw)
        @logger.error { "finlight: server error: #{text}" }
        if text.downcase.include?("limit")
          @reconnect_at = monotonic + ERROR_RATE_LIMIT_BACKOFF_SECONDS
          request_close(driver, state, "Rate limited", CLOSE_RATE_LIMITED)
        elsif text.downcase.include?("blocked")
          @reconnect_at = monotonic + ERROR_BLOCKED_BACKOFF_SECONDS
          request_close(driver, state, "User blocked", CLOSE_USER_BLOCKED)
        end
      else
        @logger.warn { "finlight: unknown message action: #{msg["action"]}" }
      end
    end

    def handle_article(data, on_article)
      article = begin
        parse_article(data)
      rescue StandardError => e
        @logger.error { "finlight: cannot parse article: #{e.message}" }
        nil
      end
      return if article.nil?

      id = article_id(article)
      if id
        if @recent_articles.include?(id)
          @logger.debug { "finlight: skipping duplicate article: #{id}" }
          return
        end
        @recent_articles << id
        @recent_articles.shift if @recent_articles.size > RECENT_ARTICLE_CACHE_SIZE
      end

      begin
        on_article.call(article)
      rescue StandardError => e
        @logger.error { "finlight: article callback failed: #{e.message}" }
      end
    end

    def handle_driver_error(message, state)
      if message[/Unexpected response code: (\d+)/, 1].to_i == 429
        @reconnect_at = monotonic + DIAL_RATE_LIMIT_BACKOFF_SECONDS
        @logger.warn { "finlight: server rejected connection (429), backing off" }
      else
        @logger.error { "finlight: connection error: #{message}" }
      end
      state[:error] = message
    end

    # Sends a close frame once and arms a grace deadline in case the server
    # never completes the close handshake.
    def request_close(driver, state, reason, code)
      return if state[:stop_sent]

      state[:stop_sent] = true
      state[:abort_at] = monotonic + CLOSE_GRACE_SECONDS
      driver.close(reason, code)
    end

    def notify_close(code, reason)
      return unless @on_close

      begin
        @on_close.call(code, reason)
      rescue StandardError => e
        @logger.error { "finlight: on_close callback failed: #{e.message}" }
      end
    end

    def interruptible_sleep(seconds)
      deadline = monotonic + seconds
      sleep([0.05, deadline - monotonic].min) while !@stop && monotonic < deadline
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def wallclock_millis
      (Time.now.to_f * 1000).to_i
    end
  end
end
