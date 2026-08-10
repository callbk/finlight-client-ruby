# frozen_string_literal: true

require "socket"

# The wss.finlight.me authorizer reads the API key header case-sensitively in
# exact lowercase; a canonicalized "X-Api-Key" is rejected with 401. This test
# captures the raw upgrade request and asserts the header names go out in
# lowercase.
RSpec.describe "WebSocket header casing" do
  it "sends the api key header in exact lowercase" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    config = Finlight::Config.new(
      api_key: "test-key", wss_url: "ws://127.0.0.1:#{port}", timeout: 5
    )
    client = Finlight::ArticleWebSocketClient.new(
      config, takeover: true, base_reconnect_delay: 0.01, logger: test_logger
    )
    thread = client.connect_async { |_article| }

    socket = server.accept
    head = +""
    head << socket.readpartial(1) until head.end_with?("\r\n\r\n")
    client.stop
    socket.write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    socket.close
    thread.join(15) or raise "timed out waiting for the stream to end"

    expect(head).to include("\r\nx-api-key: test-key")
    expect(head).to include("\r\nx-client-version: ruby/finlight-client@")
    expect(head).to include("\r\nx-takeover: true")
    expect(head).not_to include("X-Api-Key"), "header name must not be canonicalized"
    expect(head).not_to include("X-API-KEY"), "header name must not be canonicalized"
  ensure
    server&.close
  end
end
