# finlight-client (Ruby)

*[English](README.md) | 简体中文 | [日本語](README.ja.md) | [한국어](README.ko.md)*

[![Gem Version](https://img.shields.io/gem/v/finlight-client)](https://rubygems.org/gems/finlight-client)
[![CI](https://github.com/callbk/finlight-client-ruby/actions/workflows/test.yml/badge.svg)](https://github.com/callbk/finlight-client-ruby/actions/workflows/test.yml)

[finlight.me](https://finlight.me) API 的官方 Ruby 客户端 —— 提供带情感分析、实体识别和实时流式推送的财经新闻。

📚 **完整 API 文档：[docs.finlight.me](https://docs.finlight.me)**

## 功能特性

- **REST API**：检索文章、按链接获取单篇文章、列出新闻源
- **实时流式推送**：通过 WebSocket 提供 enhanced 和 raw 两种文章流
- **默认具备韧性**：请求失败按指数退避重试；WebSocket 自动重连、带 pong 看门狗的保活、主动连接轮换，以及速率限制处理
- **支持 Webhook**：HMAC-SHA256 签名验证，含重放防护
- **依赖极少**：标准库 `Net::HTTP` 和 `OpenSSL`，外加纯 Ruby 实现的 `websocket-driver`

需要 Ruby 3.2 及以上版本。

## 安装

```ruby
# Gemfile
gem "finlight-client"
```

或直接安装：

```bash
gem install finlight-client
```

## 快速开始

```ruby
require "finlight/client"

client = Finlight::Client.new(api_key: ENV["FINLIGHT_API_KEY"])

response = client.articles.fetch_articles(query: "nvidia", page_size: 10)
response.articles.each { |article| puts "[#{article.source}] #{article.title}" }
```

## REST API

### 检索文章

完整的 `query` 语法参见[查询语言参考](https://docs.finlight.me)。参数为 snake_case 关键字，与 API 的 camelCase 字段一一对应。

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

### 按链接获取单篇文章

```ruby
article = client.articles.fetch_article_by_link(
  link: "https://www.reuters.com/technology/example",
  include_content: true
)
```

### 列出新闻源

```ruby
sources = client.sources.get_sources
defaults = sources.select(&:is_default_source)
```

## 实时流式推送

`connect` 会阻塞并自动重连，直到你调用 `stop`；使用 `connect_async` 可将其运行在后台线程中。enhanced 流推送带情感和实体的文章；raw 流（`client.raw_websocket`）以最低延迟推送未经增强的文章。

```ruby
websocket = client.websocket
websocket.connect(tickers: %w[AAPL NVDA], extended: true) do |article|
  puts article.title
end
```

自定义流选项：

```ruby
websocket = client.websocket(
  takeover: true, # 接管同一密钥下已有的连接
  on_close: ->(code, reason) { puts "closed: #{code} #{reason}" }
)
thread = websocket.connect_async(query: "bitcoin") { |article| puts article.title }
# ...
websocket.stop
thread.join
```

若服务端永久拒绝该连接（关闭码 1008），`connect` 会抛出 `Finlight::BlockedError` —— 此时重连无济于事，请联系支持。

## Webhook

使用原始（未解析的）请求体验证收到的 Webhook：

```ruby
# 例如在 Rails controller 中
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

## 配置

| 选项           | 默认值                    | 说明                                            |
| -------------- | ------------------------- | ----------------------------------------------- |
| `base_url:`    | `https://api.finlight.me` | REST 接口地址                                   |
| `wss_url:`     | `wss://wss.finlight.me`   | WebSocket 接口地址                              |
| `timeout:`     | 5                         | 单次请求和连接超时（秒）                        |
| `retry_count:` | 3                         | 可重试失败（429/5xx）的总尝试次数               |
| `logger:`      | stderr, WARN              | 任意兼容标准库的 `Logger`                       |

```ruby
client = Finlight::Client.new(
  api_key: api_key,
  timeout: 10,
  retry_count: 5,
  logger: Logger.new($stdout, level: Logger::INFO)
)
```

## 开发

```bash
bundle install
bundle exec rake        # 运行测试套件
```

### 针对真实 API 的验证

`local/` 目录已被 gitignore，用于存放冒烟测试脚本，与其他语言客户端保持一致 —— 凭据请放在环境变量中，切勿写入代码。

```bash
# 一次性冒烟测试：REST 接口 + 30 秒文章流
FINLIGHT_API_KEY=sk_... bundle exec ruby local/smoke.rb

# REST 集成测试（未设置密钥时自动跳过）
FINLIGHT_API_KEY=sk_... bundle exec rspec spec/integration
```

可选：使用 `FINLIGHT_BASE_URL` / `FINLIGHT_WSS_URL` 指向 dev 环境。

## 许可证

[MIT](LICENSE)

## 相关资源

- 中文产品页：https://finlight.me/zh/news-api
