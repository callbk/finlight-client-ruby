# frozen_string_literal: true

require "json"
require "webrick"

# A real HTTP server on 127.0.0.1 that records every request and answers from a script.
class MockHttp
  Request = Struct.new(:method, :path, :query, :headers, :body, keyword_init: true) do
    def header(name)
      headers[name.downcase]
    end

    # Decoded query parameters as [name, value] pairs.
    def query_pairs
      URI.decode_www_form(query.to_s)
    end
  end

  attr_reader :requests

  def initialize
    @requests = []
    @responses = []
    @routes = []
    @mutex = Mutex.new
    @server = WEBrick::HTTPServer.new(Port: 0, BindAddress: "127.0.0.1", Logger: WEBrick::Log.new(File::NULL),
                                      AccessLog: [])
    @server.mount_proc("/") { |req, res| handle(req, res) }
    @thread = Thread.new { @server.start }
  end

  def url
    "http://127.0.0.1:#{@server.config[:Port]}"
  end

  # Queues answers: each is {status:, headers: {}, body: String|Hash|nil}. The last one repeats.
  def respond(*responses)
    @mutex.synchronize { @responses.concat(responses) }
    self
  end

  # Answers requests whose path matches `pattern` with `response` (before the queued answers).
  def route(pattern, response)
    @mutex.synchronize { @routes << [pattern, response] }
    self
  end

  def reset
    @mutex.synchronize do
      @requests.clear
      @responses.clear
      @routes.clear
    end
  end

  def close
    @server.shutdown
    @thread.join(5)
  end

  private

  def handle(req, res)
    headers = req.header.transform_values { |v| v.join(", ") }
    @mutex.synchronize do
      @requests << Request.new(method: req.request_method, path: req.path, query: req.query_string,
                               headers: headers, body: req.body)
    end
    answer = @mutex.synchronize do
      @routes.find { |pattern, _| pattern.match?(req.path) }&.last ||
        (@responses.size > 1 ? @responses.shift : @responses.first)
    end
    answer ||= { status: 500, body: "no scripted answer" }
    res.status = answer[:status]
    (answer[:headers] || {}).each { |name, value| res[name] = value }
    body = answer[:body]
    res.body = case body
               when nil then ""
               when String then body
               else JSON.generate(body)
               end
  end
end
