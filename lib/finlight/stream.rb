# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

module Finlight
  # A real-time stream over the finlight WebSocket (payloadVersion 3). Iterate it once:
  #
  #   stream = client.stream(query: "ticker:NVDA", include: ["companies"])
  #   stream.each { |event| puts event.data.title if event.data }
  #
  # `each` blocks. It keeps the connection alive (ping every 25 s, reconnect after 60 s without a
  # pong, a fresh connection after 115 minutes), sends the same subscribe after every reconnect and
  # drops duplicate deliveries. It never backfills: use on_reconnect and articles.search_all.
  #
  # Terminal problems raise out of `each`: a refused dial (UnauthorizedError, ForbiddenError without
  # WebSocket access), ValidationFailedError for a rejected subscribe, PreemptedError when another
  # connection took the slot, close code 1008. An exhausted monthly WebSocket quota is not terminal
  # by default: the stream tries again every quota_reconnect_interval (1 h) and reports each wait to
  # on_quota_wait. Other problems reconnect and go to on_error.
  #
  # Stop it with `break`, or with #close from another thread: the socket closes with 1000 and every
  # background thread ends. Hooks run on the iterating thread, between elements; errors they raise
  # are logged and do not stop the stream.
  #
  # Notes: `connection.admitted` arrives before the server checks the subscribe. Live frames over
  # 32,000 bytes are dropped by the server without notice; fetch such articles with articles.get.
  # The connection limit of your plan is shared by enriched, raw and older SDK connections.
  class Stream
    include Enumerable

    # @api private
    Outcome = Struct.new(:kind, :reason, :error, :delay)

    HOOKS = %i[on_admitted on_reconnect on_error on_quota_wait].freeze

    # @api private
    def initialize(config, frame, raw:, takeover:, hooks:, on_close: nil)
      @config = config
      @frame = frame
      @raw = raw
      @takeover = takeover
      @hooks = hooks
      @on_close = on_close
      @url = config.ws_url(raw)
      @logger = config.logger
      @clock = config.clock
      @queue = Thread::Queue.new
      @mutex = Mutex.new
      @started = false
      @closed = false
      @sessions = []
      @dedupe = {}
      @search_failed = 0
      @quota_attempt = 0
      @connections = 0
      @last_seen_at = nil
      @last_seen_time = nil
      @random = Random.new
      @nonce_factory = -> { "c-#{SecureRandom.hex(8)}" }
      @supervisor = nil
    end

    def inspect
      "#<Finlight::Stream #{@raw ? "raw" : "enriched"} closed=#{@closed}>"
    end

    # @return [String, nil] the latest timestamp seen: availableAt (fallback firstSeenAt) on
    #   enriched streams, firstSeenAt on raw streams; nil when nothing came yet
    attr_reader :last_seen_at

    # @return [Boolean]
    def closed?
      @closed
    end

    # Blocks and yields every StreamEvent until the stream is closed or ends with an error.
    # A stream can be iterated once; a second call raises ValidationError.
    #
    # @yieldparam event [StreamEvent]
    def each
      return enum_for(:each) unless block_given?

      start!
      begin
        loop do
          entry = @queue.pop
          case entry[0]
          when :item then yield entry[1]
          when :hook then run_hook(entry[1], entry[2])
          when :end
            raise entry[1] if entry[1]

            break
          end
        end
      ensure
        close
      end
      self
    end

    # Stops the stream: closes the socket with 1000 and ends every background thread. Safe to call
    # from any thread, more than once.
    def close
      sessions = nil
      supervisor = nil
      @mutex.synchronize do
        return nil if @closed

        @closed = true
        sessions = @sessions.dup
        @sessions.clear
        supervisor = @supervisor
      end
      sessions.each { |session| session.close(1000) }
      Stream.stop_thread(supervisor)
      @queue << [:end, nil]
      @on_close&.call(self)
      nil
    end

    # @api private
    def self.stop_thread(thread)
      return if thread.nil? || thread == Thread.current

      20.times do
        begin
          thread.wakeup
        rescue ThreadError
          break
        end
        return if thread.join(0.05)
      end
      return if thread.join(0.01)

      thread.kill
      thread.join(1)
    end

    # -- internal ------------------------------------------------------------------

    # @api private
    attr_reader :config, :clock, :logger

    # @api private
    def handle_frame(session, frame)
      case frame.type
      when :pong
        session.last_pong = @clock.monotonic
        @search_failed = 0 unless frame.v2 # a v3 pong means the subscribe was stored
      when :admitted
        session.admitted = true
        @quota_attempt = 0
        f = frame.fields
        @logger.debug("finlight") { "connection admitted" }
        queue_hook(:on_admitted, AdmittedInfo.new(lease_id: f[:lease_id], server_now: f[:server_now],
                                                  client_nonce: f[:client_nonce]))
      when :article then deliver_article(frame)
      when :preempted then handle_preempted(session, frame)
      when :error then handle_error_frame(session, frame)
      when :legacy_article then @logger.warn("finlight") { "dropped a v2 article frame on a v3 stream" }
      when :invalid then @logger.warn("finlight") { "dropped a frame that is not a JSON object" }
      else
        if frame.event.is_a?(String)
          # Unknown event: an element of kind "other" with the raw frame, never an error.
          @logger.debug("finlight") { "unknown event #{frame.event}" }
          put(StreamEvent.new(kind: StreamEventKind::OTHER, event: frame.event, data: nil,
                              __raw: WireModel.deep_freeze(frame.raw)))
        else
          @logger.debug("finlight") { "ignored a frame without event" }
        end
      end
    end

    private

    def start!
      @mutex.synchronize do
        raise ValidationError, "a stream can be iterated only once; call stream again" if @started

        @started = true
        if @closed
          @queue << [:end, nil]
          return
        end
        @supervisor = Thread.new do
          Thread.current.report_on_exception = false
          Thread.current.name = "finlight-stream"
          run
        end
      end
    end

    def put(event)
      @queue << [:item, event] unless @closed
    end

    def queue_hook(name, arg)
      @queue << [:hook, name, arg] if @hooks[name] && !@closed
    end

    def emit_error(error)
      queue_hook(:on_error, error)
    end

    def run_hook(name, arg)
      @hooks[name]&.call(arg)
    rescue StandardError => e
      @logger.error("finlight") { "stream hook #{name} raised #{e.class.name}" }
    end

    def finish_stream(error)
      @queue << [:end, error]
    end

    def wait_for(seconds)
      deadline = @clock.monotonic + seconds
      loop do
        return false if @closed

        left = deadline - @clock.monotonic
        return true if left <= 0

        @clock.sleep(left)
      end
    end

    def dial_headers
      # Exactly lowercase: the gateway looks the key up case-sensitively.
      headers = [["x-api-key", @config.api_key], ["x-client-version", VERSION], ["User-Agent", USER_AGENT]]
      headers << %w[x-takeover true] if @takeover
      headers
    end

    def dial
      if @config.ws_connect
        @config.ws_connect.call(@url, dial_headers)
      else
        # DriverConnection is a private constant of Transport (internal); const_get reaches it.
        Transport.const_get(:DriverConnection).connect(@url, dial_headers, connect_timeout: @config.connect_timeout,
                                                                           max_message_bytes: @config.max_message_bytes)
      end
    end

    def backoff(attempt)
      delay = [@config.reconnect_max_delay, @config.reconnect_base_delay * (2**attempt)].min
      delay * (0.5 + (0.5 * @random.rand))
    end

    def long_backoff
      @config.long_backoff * (1 + (0.25 * @random.rand))
    end

    def register(session)
      @mutex.synchronize do
        return false if @closed

        @sessions << session
        true
      end
    end

    def remove(session)
      @mutex.synchronize { @sessions.delete(session) }
    end

    def retire(session)
      remove(session)
      session.close(1000)
    end

    def run
      attempt = 0
      delay = 0.0
      reason = nil
      current = nil
      loop do
        return unless wait_for(delay)

        delay = 0.0
        begin
          conn = dial
        rescue Transport::DialRefused => e
          verdict, error, refused_reason = classify_dial(e.status, e.body)
          verdict = :terminal if verdict == :quota && !@config.quota_reconnect
          if current
            # A rotation dial failed: free the slot first, then dial again.
            retire(current)
            current = nil
            next unless verdict == :terminal
          end
          return finish_stream(error) if verdict == :terminal

          reason = refused_reason
          if verdict == :quota
            delay = quota_wait(error)
            next
          end
          emit_error(error)
          delay = verdict == :long ? long_backoff : backoff(attempt)
          attempt += 1
          @logger.warn("finlight") { format("WebSocket dial refused (HTTP %d), retrying in %.1f s", e.status, delay) }
          next
        rescue StandardError => e
          if current
            retire(current)
            current = nil
          end
          error = wrap_dial_error(e)
          emit_error(error)
          reason = ReconnectReason::DIAL_FAILED
          delay = backoff(attempt)
          attempt += 1
          @logger.warn("finlight") { format("WebSocket dial failed (%s), retrying in %.1f s", e.class.name, delay) }
          next
        end

        session = Session.new(self, conn, @nonce_factory.call)
        unless register(session)
          close_quietly(conn)
          return
        end
        begin
          session.start(@frame)
        rescue Transport::Closed => e
          session.finish(Session.closed_outcome(e))
        rescue StandardError
          session.finish(Outcome.new(:reconnect, ReconnectReason::CLOSED, nil, nil))
        end
        if current
          current.retiring = true
          retire(current)
        end
        current = session
        @connections += 1
        # Only after a new connection that is not the first: a refused first dial is no reconnect.
        if reason && @connections > 1
          queue_hook(:on_reconnect, ReconnectInfo.new(last_seen_at: @last_seen_at, reason: reason,
                                                      connection: @connections))
        end

        outcome = session.wait_outcome
        case outcome.kind
        when :stopped then return
        when :terminal
          retire(session)
          return finish_stream(outcome.error)
        when :quota
          retire(session)
          current = nil
          reason = outcome.reason
          delay = quota_wait(outcome.error)
          next
        end
        reason = outcome.reason
        healthy = session.admitted && [ReconnectReason::WATCHDOG, ReconnectReason::CLOSED,
                                       ReconnectReason::ROTATION].include?(outcome.reason)
        attempt = 0 if healthy
        if outcome.kind == :rotate
          @logger.info("finlight") { "rotating the WebSocket connection" }
          next # keep the old session open until the new one has subscribed
        end
        retire(session)
        current = nil
        if outcome.delay && healthy
          delay = outcome.delay
        else
          delay = backoff(attempt)
          attempt += 1
        end
      end
    rescue StandardError => e
      @logger.error("finlight") { "stream failed: #{e.class.name}" }
      begin
        raise NetworkError, "stream failed: #{e.class.name}"
      rescue NetworkError => wrapped
        finish_stream(wrapped)
      end
    end

    def close_quietly(conn)
      conn.close(1000)
    rescue StandardError
      nil
    end

    def wrap_dial_error(error)
      return error if error.is_a?(Error)

      begin
        raise NetworkError, "WebSocket dial failed: #{error.class.name}"
      rescue NetworkError => e
        e
      end
    end

    def quota_wait(error)
      @quota_attempt += 1
      delay = @config.quota_reconnect_interval.to_f
      @logger.warn("finlight") { format("WebSocket quota exhausted, trying again in %.0f s", delay) }
      queue_hook(:on_quota_wait, QuotaWaitInfo.new(error: error, next_attempt_in: delay, attempt: @quota_attempt))
      delay
    end

    def dial_message(body)
      return nil if body.nil? || body.empty?

      parsed = JSON.parse(body)
      if parsed.is_a?(Hash)
        %w[message error].each { |key| return parsed[key] if parsed[key].is_a?(String) }
      end
      nil
    rescue JSON::ParserError
      body.strip.empty? ? nil : body.strip
    end

    # Sorts a refused dial into [verdict, error, reconnect reason]. 403 texts are compared by their start.
    def classify_dial(status, body)
      message = dial_message(body)
      text = "WebSocket connection refused with HTTP #{status}"
      text += ": #{message}" if message
      fields = { status: status, detail: message, raw: body }
      case status
      when 401 then [:terminal, UnauthorizedError.new(text, **fields), nil]
      when 403
        if message&.start_with?("Your subscription does not include WebSockets")
          [:terminal, ForbiddenError.new(text, **fields), nil]
        elsif message&.start_with?("WebSocket quota exceeded")
          [:quota, ForbiddenError.new(text, **fields), ReconnectReason::QUOTA_EXCEEDED]
        elsif message&.start_with?("Too many concurrent connections")
          hint = "#{text}. Another connection holds the slot; pass takeover: true to replace it."
          [:long, ForbiddenError.new(hint, **fields), ReconnectReason::CONNECTION_LIMIT]
        else
          # Body missing or unknown: a long wait plus a report.
          [:long, ForbiddenError.new(text, **fields), ReconnectReason::DIAL_REFUSED]
        end
      when 429 then [:long, RateLimitedError.new(text, **fields), ReconnectReason::RATE_LIMITED]
      else
        if status >= 500
          [:backoff, InternalServerError.new(text, **fields), ReconnectReason::DIAL_REFUSED]
        else
          [:terminal, ErrorParser.class_for_status(status).new(text, **fields), nil]
        end
      end
    end

    def handle_preempted(session, frame)
      return if session.retiring

      f = frame.fields
      error = PreemptedError.new(reason: f[:reason], new_lease_id: f[:new_lease_id], timestamp: f[:timestamp])
      if f[:reason] == PreemptReason::QUOTA_EXCEEDED && @config.quota_reconnect
        session.finish(Outcome.new(:quota, ReconnectReason::QUOTA_EXCEEDED, error, nil))
      else
        session.finish(Outcome.new(:terminal, nil, error, nil))
      end
    end

    def handle_error_frame(session, frame)
      f = frame.fields
      code = f[:code]
      message = f[:message].to_s
      fields = {
        code: code, detail: message.empty? ? nil : message, errors: ErrorParser.issues_from(f[:details]),
        raw: JSON.generate(frame.raw)
      }
      text = "stream error #{code || "(v2 form)"}: #{message}".strip
      case code
      when ConnectionErrorCode::VALIDATION_FAILED
        error = ValidationFailedError.new("subscribe rejected: #{message}".strip, **fields)
        session.finish(Outcome.new(:terminal, nil, error, nil))
      when ConnectionErrorCode::HANDSHAKE_FAILED
        @logger.warn("finlight") { "HANDSHAKE_FAILED, reconnecting" }
        session.finish(Outcome.new(:reconnect, ReconnectReason::HANDSHAKE_FAILED, nil, nil))
      when ConnectionErrorCode::SEARCH_FAILED
        @search_failed += 1
        @logger.warn("finlight") { "SEARCH_FAILED (#{@search_failed} in a row), reconnecting" }
        emit_error(ApiError.new(text, **fields)) if @search_failed >= @config.search_failed_threshold
        session.finish(Outcome.new(:reconnect, ReconnectReason::SEARCH_FAILED, nil, nil))
      else
        # PING_ON_DEFAULT_ROUTE, INTERNAL_ERROR, v2-form errors and unknown codes: report only.
        @logger.warn("finlight") { "stream error #{code || "(v2 form)"}" }
        klass = code ? ErrorParser::CODE_CLASSES.fetch(code, ApiError) : ApiError
        emit_error(klass.new(text, **fields))
      end
    end

    def deliver_article(frame)
      article = decode_article(frame)
      return unless article

      digest = Digest::SHA256.hexdigest(canonical_json(frame.data))
      key = [frame.event, article.id, digest].freeze
      duplicate = @mutex.synchronize do
        if @dedupe.key?(key)
          @dedupe[key] = @dedupe.delete(key)
          true
        else
          @dedupe[key] = true
          @dedupe.shift while @dedupe.size > @config.dedupe_cache_size
          false
        end
      end
      if duplicate
        @logger.debug("finlight") { "dropped a duplicate delivery" }
        return
      end

      @search_failed = 0
      track_last_seen(article)
      put(StreamEvent.new(kind: frame.kind, event: frame.event, data: article,
                          __raw: WireModel.deep_freeze(frame.raw)))
    end

    def decode_article(frame)
      Article.decode(frame.data, "$.data")
    rescue DecodeError => e
      @logger.warn("finlight") { "dropped an unreadable #{frame.event} frame: #{e.message}" }
      emit_error(e)
      nil
    end

    def track_last_seen(article)
      seen = @raw ? article.first_seen_at : (article.available_at || article.first_seen_at)
      seen_time = TimeParse.parse(seen)
      return unless seen_time && (@last_seen_time.nil? || seen_time > @last_seen_time)

      @last_seen_time = seen_time
      @last_seen_at = seen
    end

    def canonical_json(value)
      JSON.generate(canonical(value))
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |k| [k, canonical(value[k])] }
      when Array then value.map { |v| canonical(v) }
      else value
      end
    end

    # One WebSocket connection of a stream: the subscribe, a reader thread and a ticker thread
    # (ping, watchdog, rotation). Internal.
    class Session
      attr_accessor :admitted, :retiring, :last_pong
      attr_reader :nonce, :outcome

      def self.closed_outcome(error)
        if error.code == 1008
          detail = error.reason.empty? ? nil : error.reason
          api_error = ApiError.new("WebSocket closed by the server with 1008 (policy violation)", detail: detail)
          return Outcome.new(:terminal, nil, api_error, nil)
        end
        Outcome.new(:reconnect, ReconnectReason::CLOSED, nil, nil)
      end

      def initialize(stream, conn, nonce)
        @stream = stream
        @conn = conn
        @nonce = nonce
        @config = stream.config
        @clock = stream.clock
        @logger = stream.logger
        @opened_at = @clock.monotonic
        @last_pong = @opened_at
        @last_ping = @opened_at
        @admitted = false
        @retiring = false
        @stopping = false
        @outcome = nil
        @outcome_queue = Thread::Queue.new
        @mutex = Mutex.new
        @reader = nil
        @ticker = nil
      end

      def inspect
        "#<Finlight::Stream::Session admitted=#{@admitted}>"
      end

      def finish(outcome)
        @mutex.synchronize do
          return if @outcome

          @outcome = outcome
        end
        @outcome_queue << outcome
      end

      def wait_outcome
        @outcome_queue.pop
      end

      def start(frame)
        @conn.send_text(JSON.generate(frame.merge("clientNonce" => @nonce)))
        @reader = spawn("finlight-reader") { read_loop }
        @ticker = spawn("finlight-ticker") { tick_loop }
      end

      def close(code = 1000)
        @stopping = true
        @retiring = true
        finish(Outcome.new(:stopped, nil, nil, nil))
        begin
          @conn.close(code)
        rescue StandardError
          nil
        end
        Stream.stop_thread(@ticker)
        Stream.stop_thread(@reader)
      end

      private

      def spawn(name, &block)
        Thread.new do
          Thread.current.report_on_exception = false
          Thread.current.name = name
          block.call
        end
      end

      def read_loop
        loop do
          text = @conn.receive
          @stream.handle_frame(self, Frames.decode(text))
          current = @outcome
          # During rotation the old connection keeps delivering until it is closed.
          return if current && current.kind != :rotate
        end
      rescue Transport::Closed => e
        finish(Session.closed_outcome(e)) unless @stopping
      rescue StandardError => e
        unless @stopping
          @logger.warn("finlight") { "WebSocket receive failed: #{e.class.name}" }
          finish(Outcome.new(:reconnect, ReconnectReason::CLOSED, nil, nil))
        end
      end

      def tick_loop
        until @outcome || @stopping
          now = @clock.monotonic
          watchdog_at = @last_pong + @config.watchdog_timeout
          if now >= watchdog_at
            @logger.warn("finlight") { "no pong for #{@config.watchdog_timeout} s, reconnecting" }
            return finish(Outcome.new(:reconnect, ReconnectReason::WATCHDOG, nil, 0.0))
          end
          rotate_at = @opened_at + @config.rotation_interval
          return finish(Outcome.new(:rotate, ReconnectReason::ROTATION, nil, 0.0)) if now >= rotate_at && !@retiring

          next_ping = @last_ping + @config.ping_interval
          if now >= next_ping
            @last_ping = now
            begin
              @conn.send_text(JSON.generate({ "action" => "ping", "t" => (Time.now.to_f * 1000).to_i }))
            rescue StandardError
              return finish(Outcome.new(:reconnect, ReconnectReason::CLOSED, nil, nil)) unless @stopping
            end
            next
          end
          wake = [watchdog_at, next_ping, @retiring ? watchdog_at : rotate_at].min
          @clock.sleep(wake - now)
        end
      end
    end

    private_constant :Session
  end
end
