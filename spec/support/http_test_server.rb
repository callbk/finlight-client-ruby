# frozen_string_literal: true

require "webrick"

# In-process HTTP server for REST client tests, mirroring the sibling
# clients' test servers.
class HttpTestServer
  attr_reader :port

  def initialize
    @server = WEBrick::HTTPServer.new(
      Port: 0,
      BindAddress: "127.0.0.1",
      Logger: WEBrick::Log.new(File::NULL),
      AccessLog: []
    )
    @port = @server.config[:Port]
    @thread = Thread.new { @server.start }
  end

  def url
    "http://127.0.0.1:#{@port}"
  end

  # Mounts a handler; the block receives (request, response).
  def mount(path, &handler)
    @server.mount_proc(path) do |req, res|
      handler.call(req, res)
    end
  end

  def self.respond_json(res, status, body)
    res.status = status
    res["Content-Type"] = "application/json"
    res.body = body
  end

  def close
    @server.shutdown
    @thread.join
  end
end
