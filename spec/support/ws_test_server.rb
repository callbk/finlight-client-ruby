# frozen_string_literal: true

require "json"
require "socket"
require "websocket/driver"

# In-process WebSocket server for protocol tests, mirroring the sibling
# clients' test servers. Handlers run on the server's connection threads;
# failures surface via #errors.
class WsTestServer
  # One accepted connection: exposes handshake headers and send/close.
  class Conn
    attr_reader :index, :driver

    def initialize(io, index)
      @io = io
      @index = index
      @driver = WebSocket::Driver.server(self)
    end

    # websocket-driver socket interface
    def write(data)
      @io.write(data)
    rescue StandardError
      nil
    end

    # Handshake header, e.g. header("x-api-key").
    def header(name)
      @driver.env["HTTP_#{name.upcase.tr("-", "_")}"]
    end

    def path
      @driver.env["PATH_INFO"]
    end

    def send_text(message)
      @driver.text(message)
    end

    def close(code = 1000, reason = "")
      @driver.close(reason, code)
    end
  end

  attr_reader :port, :resource_paths, :errors

  # @param on_open [Proc] called with (conn) once the WebSocket handshake completed
  # @param on_message [Proc] called with (conn, message) for every text message
  def initialize(on_open: nil, on_message: nil)
    @on_open = on_open
    @on_message = on_message
    @resource_paths = []
    @errors = []
    @connections = 0
    @mutex = Mutex.new
    @sockets = []
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @accept_thread = Thread.new do
      Thread.current.report_on_exception = false
      loop do
        io = @server.accept
        @mutex.synchronize { @sockets << io }
        Thread.new { handle(io) }
      end
    rescue StandardError, IOError
      nil
    end
  end

  def url
    "ws://127.0.0.1:#{@port}"
  end

  # A sendArticle message for the given link.
  def self.article_message(link)
    JSON.generate(
      action: "sendArticle",
      data: {
        link: link, title: "T", publishDate: "2025-06-01T12:00:00Z",
        source: "example.com", language: "en"
      }
    )
  end

  def close
    begin
      @server.close
    rescue StandardError
      nil
    end
    @accept_thread.join(2)
    @mutex.synchronize { @sockets.each { |s| s.close rescue nil } }
  end

  private

  def handle(io)
    Thread.current.report_on_exception = false
    index = @mutex.synchronize { @connections += 1 }
    conn = Conn.new(io, index)
    driver = conn.driver
    done = false

    driver.on(:connect) do
      if WebSocket::Driver.websocket?(driver.env)
        @resource_paths << driver.env["PATH_INFO"]
        driver.start
      else
        done = true
      end
    end
    driver.on(:open) { safely { @on_open&.call(conn) } }
    driver.on(:message) { |event| safely { @on_message&.call(conn, event.data) } }
    driver.on(:close) { done = true }
    driver.on(:error) { done = true }

    driver.parse(io.readpartial(16_384)) until done
  rescue EOFError, IOError, SystemCallError
    nil
  ensure
    io.close rescue nil
  end

  def safely
    yield
  rescue StandardError => e
    @errors << e
  end
end
