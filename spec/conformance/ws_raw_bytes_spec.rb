# frozen_string_literal: true

require "socket"

# S-02: the dial request carries exactly `x-api-key` (lowercase), never the key in the URL.
# A plain TCP listener reads the raw upgrade request bytes; nothing normalizes header case.
RSpec.describe "Conformance S-02: raw dial bytes" do
  def capture_dial(raw:, takeover: false)
    listener = TCPServer.new("127.0.0.1", 0)
    received = Thread::Queue.new
    acceptor = Thread.new do
      sock = listener.accept
      data = +"".b
      data << sock.readpartial(65_536) until data.include?("\r\n\r\n")
      received << data
      body = '{"message":"Invalid API key"}'
      sock.write("HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}" \
                 "\r\nConnection: close\r\n\r\n#{body}")
      sock.close
    end
    client = Finlight::Client.new(api_key: Kit::KEY, wss_url: "ws://127.0.0.1:#{listener.addr[1]}")
    stream = raw ? client.raw_stream(query: "x", takeover: takeover) : client.stream(query: "x", takeover: takeover)
    expect { stream.each { nil } }.to raise_error(Finlight::UnauthorizedError) { |e|
      expect(e.status).to eq(401)
      expect(e.detail).to eq("Invalid API key")
      expect(e.raw).to eq('{"message":"Invalid API key"}')
    }
    received.pop(timeout: 3)
  ensure
    acceptor&.join(1)
    listener&.close
  end

  it "S-02 #{Kit.case_titles["S-02"]}", kit_case: "S-02" do
    data = capture_dial(raw: false)
    request_line, rest = data.split("\r\n", 2)
    expect(request_line).to eq("GET / HTTP/1.1")
    expect(request_line.downcase).not_to include("apikey")
    expect(request_line).not_to include(Kit::KEY)
    lines = rest.split("\r\n")
    expect(lines).to include("x-api-key: #{Kit::KEY}")
    expect(lines.select { |l| l.downcase.start_with?("x-api-key:") }).to eq(["x-api-key: #{Kit::KEY}"])
    expect(lines).to include("x-client-version: #{Finlight::VERSION}")
    expect(lines).to include("User-Agent: finlight-client-ruby/#{Finlight::VERSION}")
    expect(lines.grep(/\Ax-takeover/i)).to eq([])
  end

  it "S-02 raw endpoint, takeover header", kit_case: "S-02" do
    data = capture_dial(raw: true, takeover: true)
    expect(data).to start_with("GET /raw HTTP/1.1\r\n")
    expect(data).to include("\r\nx-takeover: true\r\n")
    expect(data).to include("\r\nx-api-key: #{Kit::KEY}\r\n")
  end
end
