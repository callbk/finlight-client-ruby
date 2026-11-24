# frozen_string_literal: true

require "json"
require "monitor"
require "socket"
require "websocket/driver"

# An in-process WebSocket server on 127.0.0.1. It reads the upgrade request itself (so header names
# are seen exactly as sent), can refuse a dial with a status and body, and exposes each accepted
# connection to the test.
class WsServer
  # One accepted connection.
  class Conn
    attr_reader :dial, :inbox, :driver

    def initialize(io, dial, server)
      @io = io
      @dial = dial
      @server = server
      @inbox = Thread::Queue.new
      @mutex = Monitor.new # re-entrant: auto-pong answers from inside the parse callback
      @closed = false
      @closed_queue = Thread::Queue.new
      @driver = WebSocket::Driver.server(self)
    end

    # websocket-driver socket interface
    def write(data)
      @io.write(data)
    rescue StandardError
      nil
    end

    def url
      "ws://127.0.0.1#{@dial[:path]}"
    end

    def path
      @dial[:path]
    end

    def send_frame(frame)
      text = frame.is_a?(String) ? frame : JSON.generate(frame)
      @mutex.synchronize { @driver.text(text) }
    end

    # Next message from the client, parsed as JSON when possible.
    def recv(timeout: 3, skip_pings: true)
      loop do
        text = @inbox.pop(timeout: timeout)
        raise "timed out waiting for a client message" if text.nil?

        obj = parse(text)
        return text if obj.nil?
        next if skip_pings && obj.is_a?(Hash) && obj["action"] == "ping"

        return obj
      end
    end

    def parse(text)
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end

    # Drops the connection the way API Gateway does: a close frame, then the socket goes away.
    def close(code = 1001)
      @mutex.synchronize do
        @driver.close("", code)
      rescue StandardError
        nil
      end
      Kernel.sleep(0.01)
      mark_closed
    end

    def closed?
      @closed
    end

    # Holds back everything the client sends from now on (and so the answer to its close frame)
    # until #release.
    def hold!
      @held = Thread::Queue.new
    end

    def release
      held = @held
      @held = nil
      held&.close
    end

    def wait_closed(timeout = 5)
      return true if @closed

      !@closed_queue.pop(timeout: timeout).nil?
    end

    def mark_closed
      return if @closed

      @closed = true
      release
      begin
        @io.close
      rescue StandardError
        nil
      end
      @closed_queue << true
    end

    def run(head)
      @driver.on(:connect) { @driver.start }
      @driver.on(:message) { |event| @server.on_message(self, event.data) }
      @driver.on(:close) { mark_closed }
      @mutex.synchronize { @driver.parse(head) }
      loop do
        chunk = @io.readpartial(65_536)
        @held&.pop
        @mutex.synchronize { @driver.parse(chunk) }
      end
    rescue StandardError
      mark_closed
    end
  end

  attr_reader :dials, :all
  attr_accessor :auto_pong

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @dials = []
    @all = []
    @reject_plan = []
    @connections = Thread::Queue.new
    @mutex = Mutex.new
    @auto_pong = false
    @accept = Thread.new do
      Thread.current.report_on_exception = false
      loop do
        io = @server.accept
        Thread.new(io) do |sock|
          Thread.current.report_on_exception = false
          handle(sock)
        end
      end
    rescue StandardError
      nil
    end
  end

  def port
    @server.addr[1]
  end

  def url
    "ws://127.0.0.1:#{port}"
  end

  # Queues the answer for the next dial: nil accepts, [status, body] refuses, :drop closes the
  # socket without an answer (a network failure).
  def plan(answer)
    @mutex.synchronize { @reject_plan << answer }
  end

  def dial_count
    @mutex.synchronize { @dials.size }
  end

  def next_connection(timeout: 3)
    conn = @connections.pop(timeout: timeout)
    raise "timed out waiting for a WebSocket connection" if conn.nil?

    conn
  end

  def on_message(conn, text)
    if @auto_pong
      obj = begin
        JSON.parse(text)
      rescue JSON::ParserError
        nil
      end
      if obj.is_a?(Hash) && obj["action"] == "ping"
        conn.send_frame({ "event" => "connection.pong", "payloadVersion" => 3,
                          "data" => { "t" => obj["t"], "serverNow" => 1 } })
        return
      end
    end
    conn.inbox << text
  end

  def close
    begin
      @server.close
    rescue StandardError
      nil
    end
    @accept.kill
    @mutex.synchronize { @all.dup }.each(&:mark_closed)
  end

  private

  def handle(io)
    head = +"".b
    head << io.readpartial(65_536) until head.include?("\r\n\r\n")
    request_line, *lines = head.split("\r\n\r\n", 2).first.split("\r\n")
    headers = lines.map { |line| line.split(": ", 2) }
    dial = { request_line: request_line, path: request_line.split[1], headers: headers, raw: head.dup }
    plan = @mutex.synchronize do
      @dials << dial
      @reject_plan.shift
    end
    if plan == :drop
      io.close
      return
    end
    if plan
      status, body = plan
      body = body.to_s.b
      io.write("HTTP/1.1 #{status} Refused\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}" \
               "\r\nConnection: close\r\n\r\n#{body}")
      io.close
      return
    end
    conn = Conn.new(io, dial, self)
    @mutex.synchronize { @all << conn }
    @connections << conn
    conn.run(head)
  rescue StandardError
    begin
      io.close
    rescue StandardError
      nil
    end
  end
end
