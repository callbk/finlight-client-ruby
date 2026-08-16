# finlight-client (Ruby)

*English | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md)*

[![Gem Version](https://img.shields.io/gem/v/finlight-client)](https://rubygems.org/gems/finlight-client)
[![CI](https://github.com/callbk/finlight-client-ruby/actions/workflows/test.yml/badge.svg)](https://github.com/callbk/finlight-client-ruby/actions/workflows/test.yml)

The official Ruby client for the [finlight.me](https://finlight.me) API — financial news with sentiment analysis, entity recognition, and real-time streaming.

📚 **Full API documentation: [docs.finlight.me](https://docs.finlight.me)**

## Features

- **REST API**: search articles, fetch single articles by link, list sources
- **Real-time streaming**: enhanced and raw article streams over WebSocket
- **Resilient by default**: request retries with exponential backoff; WebSocket auto-reconnect, keepalive with pong watchdog, proactive connection rotation, and rate-limit handling
- **Webhook support**: HMAC-SHA256 signature verification with replay protection
- **Minimal dependencies**: stdlib `Net::HTTP` and `OpenSSL`, plus the pure-Ruby `websocket-driver`

Requires Ruby 3.2+.

## Installation

```ruby
# Gemfile
gem "finlight-client"
```

Or directly:

```bash
gem install finlight-client
```

## Quick Start

```ruby
require "finlight/client"

client = Finlight::Client.new(api_key: ENV["FINLIGHT_API_KEY"])

response = client.articles.fetch_articles(query: "nvidia", page_size: 10)
response.articles.each { |article| puts "[#{article.source}] #{article.title}" }
```

## REST API

### Search articles

See the [query language reference](https://docs.finlight.me) for the full `query` syntax. Parameters are snake_case keywords; they map 1:1 to the camelCase API fields.

```ruby
response = client.articles.fetch_articles(
  query: '(ticker:AAPL OR ticker:NVDA) AND "Elon Musk"',
  tickers: %w[AAPL NVDA],
  from: "2025-01-01",
  include_content: true,
  include_entities: true,
  order_by: "publishDate",
  order: "DESC",
  page_size: 20
)

response.articles.each do |article|
  puts "#{article.publish_date} #{article.title} (#{article.sentiment})"
end
```

### Fetch a single article by link

```ruby
article = client.articles.fetch_article_by_link(
  link: "https://www.reuters.com/technology/example",
  include_content: true
)
```

### List sources

```ruby
sources = client.sources.get_sources
defaults = sources.select(&:is_default_source)
```

## Real-time streaming

`connect` blocks and reconnects automatically until you call `stop`; use `connect_async` to run it on a background thread. The enhanced stream delivers articles with sentiment and entities; the raw stream (`client.raw_websocket`) delivers unenriched articles with minimal latency.

```ruby
websocket = client.websocket
websocket.connect(tickers: %w[AAPL NVDA], extended: true) do |article|
  puts article.title
end
```

Custom stream options:

```ruby
websocket = client.websocket(
  takeover: true, # take over an existing connection for the same key
  on_close: ->(code, reason) { puts "closed: #{code} #{reason}" }
)
thread = websocket.connect_async(query: "bitcoin") { |article| puts article.title }
# ...
websocket.stop
thread.join
```

If the server permanently rejects the connection (close code 1008), `connect` raises `Finlight::BlockedError` — reconnecting will not help; contact support.

## Webhooks

Verify incoming webhooks with the raw (unparsed) request body:

```ruby
# e.g. in a Rails controller
def webhook
  article = Finlight::WebhookService.construct_event(
    request.raw_post,
    request.headers["X-Webhook-Signature"],
    ENV["WEBHOOK_SECRET"],
    request.headers["X-Webhook-Timestamp"]
  )
  Rails.logger.info("New article: #{article.title}")
  head :ok
rescue Finlight::WebhookVerificationError
  head :bad_request
end
```

## Configuration

| Option         | Default                   | Description                                     |
| -------------- | ------------------------- | ----------------------------------------------- |
| `base_url:`    | `https://api.finlight.me` | REST endpoint                                   |
| `wss_url:`     | `wss://wss.finlight.me`   | WebSocket endpoint                              |
| `timeout:`     | 5                         | Per-request and connect timeout in seconds      |
| `retry_count:` | 3                         | Total attempts for retryable failures (429/5xx) |
| `logger:`      | stderr, WARN              | Any stdlib-compatible `Logger`                  |

```ruby
client = Finlight::Client.new(
  api_key: api_key,
  timeout: 10,
  retry_count: 5,
  logger: Logger.new($stdout, level: Logger::INFO)
)
```

## Development

```bash
bundle install
bundle exec rake        # run the test suite
```

### Verification against the real API

The `local/` directory is gitignored and holds smoke runners, mirroring the sibling clients — keep credentials in the environment, never in code.

```bash
# One-shot smoke: REST endpoints + 30s article stream
FINLIGHT_API_KEY=sk_... bundle exec ruby local/smoke.rb

# REST integration tests (auto-skipped when the key is not set)
FINLIGHT_API_KEY=sk_... bundle exec rspec spec/integration
```

Optional: `FINLIGHT_BASE_URL` / `FINLIGHT_WSS_URL` to target dev.

## License

[MIT](LICENSE)
