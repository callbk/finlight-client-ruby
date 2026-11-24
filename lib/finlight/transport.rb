# frozen_string_literal: true

require "io/wait"
require "openssl"
require "socket"
require "uri"
require "websocket/driver"

module Finlight
  # The WebSocket transport seam.
  #
  # A custom transport (Config#ws_connect) is a callable `(url, headers) -> connection`.
  # `headers` is an Array of [name, value] pairs that must go out exactly as given (lowercase
  # `x-api-key`). The connection needs three methods:
  #
  # - `send_text(string)`: send one text message; raise Closed when the socket is gone
  # - `receive`: block until the next text message and return it; raise Closed when the socket closed
  # - `close(code)`: close the socket with that close code
  #
  # Raise DialRefused(status, body) from the callable when the server refused the upgrade.
  module Transport
    # The server answered the upgrade with an HTTP status other than 101.
    class DialRefused < StandardError
      # @return [Integer]
      attr_reader :status
      # @return [String, nil] the response body, when it could be read
      attr_reader :body

      def initialize(status, body = nil)
        @status = status
        @body = body
        super("WebSocket upgrade refused with HTTP #{status}")
      end
    end

    # The socket closed. `code` is the WebSocket close code (1006 when the connection dropped).
    class Closed < StandardError
      attr_reader :code, :reason

      def initialize(code, reason = "")
        @code = code
        @reason = reason.to_s
        super("WebSocket closed (#{code})")
      end
    end

    # The default transport: a TCP/TLS socket driven by websocket-driver. It writes the header
    # names exactly as given and reads the body of a refused upgrade itself (websocket-driver
    # does not expose it). Internal.
    class DriverConnection
      READ_CHUNK = 65_536

      attr_reader :url

      def self.connect(url, headers, connect_timeout:, max_message_bytes:)
        conn = new(url, headers, max_message_bytes)
        conn.open(connect_timeout)
        conn
      end

      def initialize(url, headers, max_message_bytes)
        @url = url
        @uri = URI.parse(url)
        @headers = headers
        @max_message_bytes = max_message_bytes
        @messages = []
        @mutex = Mutex.new
        @closed = false
        @open = false
        @write_failed = false
      end

      def inspect
        "#<Finlight::Transport::DriverConnection url=#{@url.inspect}>"
      end

      def open(connect_timeout)
        deadline = monotonic + connect_timeout
        @io = open_socket(deadline)
        @driver = WebSocket::Driver.client(self, max_length: @max_message_bytes)
        @headers.each { |name, value| @driver.set_header(name, value) }
        @driver.on(:open) { @open = true }
        @driver.on(:message) { |event| @messages << event.data }
        @driver.on(:close) do |event|
          @closed = true
          @close_code ||= event.code
          @close_reason ||= event.reason
        end
        @driver.start
        handshake(deadline)
      rescue StandardError
        close_io
        raise
      end

      # websocket-driver socket interface
      def write(data)
        @io.write(data)
      rescue StandardError
        @write_failed = true
      end

      def send_text(text)
        @mutex.synchronize do
          raise Closed.new(@close_code || 1006, @close_reason) if @closed || @write_failed

          @driver.text(text)
          raise Closed.new(1006, "write failed") if @write_failed
        end
        nil
      end

      def receive
        loop do
          message = @mutex.synchronize { @messages.shift }
          return message if message
          raise Closed.new(@close_code || 1006, @close_reason) if @closed

          begin
            chunk = @io.readpartial(READ_CHUNK)
          rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
            @closed = true
            next
          end
          @mutex.synchronize { @driver.parse(chunk) }
        end
      end

      def close(code = 1000)
        @mutex.synchronize do
          begin
            @driver.close("", code) if @open && !@closed
          rescue StandardError
            nil
          end
          @closed = true
        end
        close_io
      end

      private

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def secure?
        %w[wss https].include?(@uri.scheme)
      end

      def open_socket(deadline)
        port = @uri.port || (secure? ? 443 : 80)
        tcp = Socket.tcp(@uri.host, port, connect_timeout: remaining(deadline))
        return tcp unless secure?

        context = OpenSSL::SSL::SSLContext.new
        context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
        ssl.hostname = @uri.host
        ssl.sync_close = true
        loop do
          result = ssl.connect_nonblock(exception: false)
          break unless %i[wait_readable wait_writable].include?(result)

          wait(ssl, result, deadline)
        end
        ssl.post_connection_check(@uri.host)
        ssl
      rescue Errno::ETIMEDOUT, IO::TimeoutError
        raise Finlight::TimeoutError, "WebSocket connect timed out"
      end

      def remaining(deadline)
        left = deadline - monotonic
        raise Finlight::TimeoutError, "WebSocket handshake timed out" if left <= 0

        left
      end

      def wait(io, what, deadline)
        ready = what == :wait_writable ? io.wait_writable(remaining(deadline)) : io.wait_readable(remaining(deadline))
        raise Finlight::TimeoutError, "WebSocket handshake timed out" unless ready
      end

      def read_some(deadline)
        loop do
          data = @io.read_nonblock(READ_CHUNK, exception: false)
          return nil if data.nil?
          return data unless data.is_a?(Symbol)

          wait(@io, data, deadline)
        end
      end

      # Reads the HTTP answer to the upgrade. 101 goes on to websocket-driver; anything else
      # becomes DialRefused with the body (read up to Content-Length, or until EOF).
      def handshake(deadline)
        buffer = +"".b
        until buffer.include?("\r\n\r\n")
          chunk = read_some(deadline)
          raise Closed.new(1006, "connection closed during the handshake") if chunk.nil?

          buffer << chunk
        end
        head, rest = buffer.split("\r\n\r\n", 2)
        status = head[%r{\AHTTP/1\.[01] (\d{3})}, 1].to_i
        if status == 101
          @mutex.synchronize { @driver.parse(buffer) }
          raise Closed.new(1006, "WebSocket handshake failed") unless @open

          return
        end

        length = head[/^content-length:\s*(\d+)/i, 1]&.to_i
        body_deadline = [deadline, monotonic + 2].min
        while length.nil? || rest.bytesize < length
          chunk = begin
            read_some(body_deadline)
          rescue Finlight::TimeoutError, IOError, SystemCallError
            nil
          end
          break if chunk.nil?

          rest << chunk
        end
        rest = rest.byteslice(0, length) if length
        raise DialRefused.new(status, rest.force_encoding(Encoding::UTF_8))
      end

      def close_io
        @io&.close
      rescue StandardError
        nil
      end
    end
  end
end
