# finlight-client (Ruby)

*[English](README.md) | [简体中文](README.zh-CN.md) | 日本語 | [한국어](README.ko.md)*

[![Gem Version](https://img.shields.io/gem/v/finlight-client)](https://rubygems.org/gems/finlight-client)
[![CI](https://github.com/callbk/finlight-client-ruby/actions/workflows/test.yml/badge.svg)](https://github.com/callbk/finlight-client-ruby/actions/workflows/test.yml)

[finlight.me](https://finlight.me) API の公式 Ruby クライアントです。センチメント分析、エンティティ認識、リアルタイムストリーミングを備えた金融ニュースを提供します。

📚 **完全な API ドキュメント: [docs.finlight.me](https://docs.finlight.me)**

## 主な機能

- **REST API**: 記事の検索、リンクによる単一記事の取得、ニュースソースの一覧取得
- **リアルタイムストリーミング**: WebSocket 経由の enhanced および raw 記事ストリーム
- **標準で堅牢**: 指数バックオフによるリクエストのリトライ、WebSocket の自動再接続、pong ウォッチドッグ付きキープアライブ、先回りのコネクションローテーション、レート制限のハンドリング
- **Webhook 対応**: HMAC-SHA256 の署名検証とリプレイ攻撃対策
- **依存関係は最小限**: 標準ライブラリの `Net::HTTP` と `OpenSSL`、および純 Ruby 実装の `websocket-driver`

Ruby 3.2 以降が必要です。

## インストール

```ruby
# Gemfile
gem "finlight-client"
```

または直接:

```bash
gem install finlight-client
```

## クイックスタート

```ruby
require "finlight/client"

client = Finlight::Client.new(api_key: ENV["FINLIGHT_API_KEY"])

response = client.articles.fetch_articles(query: "nvidia", page_size: 10)
response.articles.each { |article| puts "[#{article.source}] #{article.title}" }
```

## REST API

### 記事を検索する

`query` の完全な構文は[クエリ言語リファレンス](https://docs.finlight.me)を参照してください。パラメータは snake_case のキーワードで、API の camelCase フィールドと 1 対 1 に対応します。

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

### リンクから単一の記事を取得する

```ruby
article = client.articles.fetch_article_by_link(
  link: "https://www.reuters.com/technology/example",
  include_content: true
)
```

### ニュースソースを一覧取得する

```ruby
sources = client.sources.get_sources
defaults = sources.select(&:is_default_source)
```

## リアルタイムストリーミング

`connect` はブロックし、`stop` を呼ぶまで自動的に再接続します。バックグラウンドスレッドで動かす場合は `connect_async` を使用してください。enhanced ストリームはセンチメントとエンティティ付きの記事を、raw ストリーム（`client.raw_websocket`）は最小遅延で未加工の記事を配信します。

```ruby
websocket = client.websocket
websocket.connect(tickers: %w[AAPL NVDA], extended: true) do |article|
  puts article.title
end
```

ストリームオプションのカスタマイズ:

```ruby
websocket = client.websocket(
  takeover: true, # 同じキーの既存コネクションをテイクオーバーする
  on_close: ->(code, reason) { puts "closed: #{code} #{reason}" }
)
thread = websocket.connect_async(query: "bitcoin") { |article| puts article.title }
# ...
websocket.stop
thread.join
```

サーバーが接続を恒久的に拒否した場合（クローズコード 1008）、`connect` は `Finlight::BlockedError` を送出します。再接続しても解決しないため、サポートにご連絡ください。

## Webhook

生の（パースされていない）リクエストボディで、受信した Webhook を検証します:

```ruby
# 例: Rails の controller で
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

## 設定

| オプション     | デフォルト                | 説明                                            |
| -------------- | ------------------------- | ----------------------------------------------- |
| `base_url:`    | `https://api.finlight.me` | REST のエンドポイント                           |
| `wss_url:`     | `wss://wss.finlight.me`   | WebSocket のエンドポイント                      |
| `timeout:`     | 5                         | リクエストごとおよび接続のタイムアウト（秒）    |
| `retry_count:` | 3                         | リトライ対象の失敗（429/5xx）に対する総試行回数 |
| `logger:`      | stderr, WARN              | 標準ライブラリ互換の任意の `Logger`             |

```ruby
client = Finlight::Client.new(
  api_key: api_key,
  timeout: 10,
  retry_count: 5,
  logger: Logger.new($stdout, level: Logger::INFO)
)
```

## 開発

```bash
bundle install
bundle exec rake        # テストスイートを実行
```

### 実 API に対する検証

`local/` ディレクトリは gitignore されており、他言語のクライアントと同様にスモーク実行スクリプトを収めています。認証情報は環境変数に置き、コードには決して書かないでください。

```bash
# 一度きりのスモーク: REST エンドポイント + 30 秒の記事ストリーム
FINLIGHT_API_KEY=sk_... bundle exec ruby local/smoke.rb

# REST 統合テスト（キー未設定時は自動的にスキップ）
FINLIGHT_API_KEY=sk_... bundle exec rspec spec/integration
```

任意: dev 環境を対象にする場合は `FINLIGHT_BASE_URL` / `FINLIGHT_WSS_URL` を指定します。

## ライセンス

[MIT](LICENSE)

## 関連リンク

- 日本語の製品ページ: https://finlight.me/ja/news-api
