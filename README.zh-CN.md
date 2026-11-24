# finlight Ruby 客户端

*[English](README.md) | 简体中文 | [日本語](README.ja.md) | [한국어](README.ko.md)*

> 本译文会随英文版 [README.md](README.md) 后续更新；如有出入，以英文版为准。

[![Gem Version](https://badge.fury.io/rb/finlight-client.svg)](https://rubygems.org/gems/finlight-client)
[![Test](https://github.com/callbk/finlight-client-ruby/actions/workflows/test.yml/badge.svg)](https://github.com/callbk/finlight-client-ruby/actions/workflows/test.yml)

> **Breaking release.** 1.0.0 版只支持 finlight API v3。为 0.x 编写的代码不能直接运行。
> 如需继续使用 0.x（API v2），请固定 `gem "finlight-client", "~> 0.1.0"`。`~> 0.1` 不会升级到 1.0，
> 但 `>= 0.1` 这样的开放版本约束会。请参阅[从 0.x 迁移](#从-0x-迁移)。

[finlight](https://finlight.me) 新闻 API 的 Ruby 客户端：通过 REST 搜索和查询金融新闻、公司和来源，
通过 WebSocket 实时接收文章，并校验 Webhook。

## 版本

| SDK version | API version | Status |
|---|---|---|
| 1.x | v3（REST `/v3`、WebSocket `payloadVersion` 3、v3 Webhook） | 当前版本 |
| 0.x | v2 | 不再发布新版本 |

SDK 版本与 API 版本相互独立。支持 API v3 的其他 finlight SDK：TypeScript 4.x、Python 3.x、PHP 2.x、
Go 模块 `/v2`、.NET 2.x、Java 1.x、Ruby 1.x、Rust 0.2。

## 环境要求

- Ruby 3.2 或更高版本（在 3.2、3.3、3.4 和 4.0 上测试）
- `websocket-driver` 0.7.7 或更高（低于 1.0），`logger` 1.5 或更高
- 其余全部来自标准库（`net/http`、`json`、`openssl`）

## 安装

```bash
bundle add finlight-client --version "~> 1.0"
```

## 快速开始

```ruby
require "finlight"

client = Finlight::Client.new(api_key: ENV.fetch("FINLIGHT_API_KEY"))
page = client.articles.search(query: "ticker:NVDA", limit: 10)
page.articles.each { |article| puts "#{article.published_at} #{article.title}" }
```

参数是 snake_case 的关键字参数，每个参数对应 API 中唯一的一个键（`event_types` 即 `eventTypes`）。
只发送你传入的参数：不带参数的搜索发送 `{}`。词表中的值（事件类型、角色等）保持为普通字符串，
不在本地校验，因此服务器新增的值无需更新 SDK 即可使用。

## 搜索文章

```ruby
page = client.articles.search(
  query: "eventType:mna AND companyCountry:US",
  languages: ["en", "de"],
  source_types: [Finlight::SourceType::NEWSWIRE, Finlight::SourceType::FINANCIAL_MEDIA],
  from: Time.utc(2026, 11, 1),      # a Time, a Date or a String
  event_types: ["mna"],
  min_relevance: 0.5,
  order_by: "availableAt",
  include: ["content", "companies", "events"],
  limit: 50
)
puts page.pagination.has_more, page.pagination.next_cursor
```

`search_all` 会自动翻页。调用时请求即被冻结，后续页面只改变 `cursor`。默认在 `max_pages`（10）页后停止，
因为每一页都会消耗配额。

```ruby
results = client.articles.search_all(query: "ticker:AAPL", limit: 100, max_pages: 5)
results.each { |article| puts article.title } # or: results.pages.each { |page| ... }
puts "continue with cursor #{results.next_cursor}" if results.truncated?
```

结果只能遍历一次，第二次遍历会抛出 `Finlight::ValidationError`。用 `cursor:` 可从中断处继续。
未知关键字和格式错误（`limit: 0`、`languages: []`、超过 3 个 `include` 值）会在发送前抛出
`Finlight::ValidationError`（也是 `ArgumentError`）。`Time` 以带毫秒的 UTC ISO 8601 发送，
`Date` 以 `YYYY-MM-DD` 发送，字符串原样发送。

`source_types` 和 `exclude_source_types` 按来源类型筛选（`Finlight::SourceType::ALL`，例如
`Finlight::SourceType::NEWSWIRE`）。未分类来源的文章不会匹配 `source_types`，在 `exclude_source_types` 下会保留。
两者只会缩小你已能获取的来源范围。
`client.stream` 和 `client.raw_stream` 也支持这两个参数。

## 查询文章、公司和来源

```ruby
article = client.articles.get("EU8JwpsZ8iJehuyPZjMqRz", include: ["content"])
article = client.articles.get_by_link("https://www.reuters.com/...")

companies = client.companies.search("NVDA", mic: "XNAS") # at most 10, no pages
companies = client.companies.get_many([4821, 1001])
company = client.companies.get(4821)                     # revalidated with its ETag next time
puts company.cache_info.etag

sources = client.sources.list
```

- 未找到时抛出 `Finlight::NotFoundError`，绝不会返回空结果。在引入文章 id 之前收录的文章按 id 查询会返回 404，请按链接查询。
- `companies.*` 需要 `entityAccess` 权限（否则抛出 `Finlight::ForbiddenError`）。
- 查询企业和来源与文章请求一样消耗额度：每个成功的请求 1 个 credit（`get_many` 按请求计，不按 ID 计）。304 重新验证和错误不计费。这里也可能返回 429。
- `companies.get` 最多缓存 256 条记录（`company_cache_size`），并用 ETag 重新验证。304 时返回缓存的记录。
  使用自己的 ETag 调用 `companies.get(id, if_none_match: etag)` 时，304 返回 `nil`（"未修改"）。
- `CompanyList` 和 `SourceList` 是 Enumerable。无法读取的条目会被跳过、记录警告，并保存在 `skipped`
  中（索引、原始 JSON、原因）。`search` 的结果页同样有 `skipped`。

## 缺失、null 与空

有些键取决于你的套餐和 `include`。它们有三种状态：缺失（未请求、无权限或 raw 文章）、`null`（没有值）或有值。

```ruby
article.content_present?    # was "content" sent? (null counts as sent)
article.content             # nil when absent or null
article.sentiment_present?  # the same for "sentiment"
article.companies_present?  # companies is nil when absent; [] means "tagged, nothing found"
article.events_present?     # the same for events
article.raw_json            # the JSON as received, unknown keys included
```

- `companies: []` 表示文章已打标签但没有找到公司；`nil` 表示根本没有收到该数据块。不要把缺失理解为"没有公司"。
- 只有同一响应中包含 `companies` 时才会发送 `events[].company_ids`，否则为 `nil`。
- 时间戳保持为发送时的字符串（`published_at`）。`published_at_time`、`first_seen_at_time`、`revised_at_time`、
  `available_at_time` 按 RFC 3339 严格解析，无法解析时返回 `nil`。
- 新版服务器的未知键会被忽略。`raw_json` 和 `to_wire` 可取回 JSON。
- 模型是不可变的 `Data` 对象。词表值是字符串，绝不是 Symbol。请与常量比较（`Finlight::EventType::MNA`、
  `Finlight::CompanyRole::ACQUIRER`），`ALL` 列出已知值。未知值原样保留。

## 实时流

```ruby
stream = client.stream(
  query: "ticker:NVDA",
  language: "en",
  exclude_source_types: [Finlight::SourceType::BLOG],
  include: ["companies", "events"],
  include_updates: true,
  on_admitted: ->(info) { puts "admitted #{info.lease_id}" },
  on_reconnect: ->(info) { puts "reconnected (#{info.reason}), last seen #{info.last_seen_at}" },
  on_error: ->(error) { warn "stream problem: #{error.message}" },
  on_quota_wait: ->(info) { warn "quota used up, next try in #{info.next_attempt_in} s" }
)
stream.each do |event|
  next if event.kind == "other" # an event this SDK does not know yet
  puts "#{event.kind} #{event.data.title}"
end
```

- `each` 会阻塞。用 `break` 退出，或在另一个线程中调用 `stream.close`：套接字以 1000 关闭，所有后台线程结束。流只能遍历一次。
- `event.kind` 为 `created`、`updated` 或 `other`。`event.raw_json` 是完整的帧。
- `client.raw_stream(query:, sources:, exclude_sources:, source_types:, exclude_source_types:, language:, include_updates:)` 推送未经加工的文章。
  它不接受 `include`，没有正文、情绪、公司或事件。
- 流每 25 秒发送一次 ping，60 秒内没有 pong 时重新连接，115 分钟后建立新连接。每次重连后发送相同的订阅并丢弃重复项。
- 不会自动补数据。`on_reconnect` 提供你看到的最新 `availableAt`（raw：`firstSeenAt`）。可用
  `client.articles.search_all(from: info.last_seen_at, order_by: "availableAt")` 补齐缺口。
- 钩子在遍历线程上、两个元素之间运行。钩子中的错误会被记录，不会停止流。
- 终止性问题会从 `each` 抛出：无效密钥（`UnauthorizedError`）、套餐不含 WebSocket（`ForbiddenError`）、
  订阅被拒绝（`ValidationFailedError`）、另一连接接管时原因为 `connection_limit` 的 `PreemptedError`，以及关闭码 1008。
  其他问题会重新连接并交给 `on_error`。
- 每月 WebSocket 配额用完时（连接被拒绝，或收到原因为 `quota_exceeded` 的 `connection.preempted`），流不会结束，
  而是每小时重试一次，直到配额恢复。每次等待都会记录警告并交给 `on_quota_wait`（不交给 `on_error`）。
  设置 `quota_reconnect: false` 则以错误结束流；`quota_reconnect_interval` 可修改间隔。

需要了解的限制：

- 套餐的连接数上限由 enriched、raw 和旧版 SDK 的连接共享。达到上限时新连接会被拒绝，SDK 在 60 秒后重试。
  向 `stream` 传入 `takeover: true` 可替换最旧的连接。
- 连接最长存活 2 小时，SDK 在 115 分钟后轮换连接。如果你的套餐已达到连接上限（例如上限为 1），旧连接仍被计入，新连接会被拒绝；SDK 随即关闭旧连接并立即重新连接，中断时间大约只有一次连接的长度。只有这次连接也被拒绝时，才会按常规至少等待 60 秒。
- 订阅后，服务器会立即发送一次最新的匹配文章，每次重连和轮换后也会发送。它可能是旧文章；如果你已收到过，重复过滤会将其丢弃。
- 超过 32,000 字节的实时帧会被服务器静默丢弃。使用 `include: ["content"]` 且文章很长时可能发生，请用 `articles.get` 获取。
- `connection.admitted` 在服务器检查订阅之前到达，并不表示订阅已被接受。

## Webhook

finlight 会为每个 Webhook 签名。请在解析任何内容之前，用**原始**请求体进行校验：

```ruby
result = Finlight::Webhooks.construct_event(raw_body, headers, ENV.fetch("FINLIGHT_WEBHOOK_SECRET"))
case result
when Finlight::WrongPayloadVersion
  keep_for_later(result.raw)  # an old v2 body: answer 2xx anyway
when Finlight::WebhookEvent
  queue_for_processing(result) unless already_seen?(result.event_id)
end
# answer 2xx within 5 s; answer 400 on Finlight::WebhookVerificationError; never 410
```

- `headers` 可以是任意大小写的 Hash、Rack env（`HTTP_X_WEBHOOK_SIGNATURE`）或名称/值对。
  `construct_event_from_values(raw_body, signature, timestamp, secret)` 直接接收两个头的值；`verify_signature` 只做校验。
- 时间戳必须在双向 300 秒（`tolerance:`）之内。`now:` 可替换时钟。
- 投递可能重复：请按 `event_id` 去重。仪表板测试 Webhook 的 `result.test?` 为 true。
- 请在 5 秒内返回 2xx，再处理耗时工作。绝不要返回 410：它会立即停用 Webhook。连续 10 次非 2xx 也会停用。
- 签名正确但 `payloadVersion` 不是 3 的请求体会返回 `Finlight::WrongPayloadVersion`，这是结果而不是错误，请以 2xx 应答。

获取原始请求体：

| 框架 | 原始请求体 |
|---|---|
| Rack | `env["rack.input"].read` |
| Rails | `request.raw_post` |
| Sinatra | `request.body.read` |
| Hanami | `request.body.read` |

`examples/webhook_endpoint.rb` 是一个完整的 Rack 应用。

将 Webhook 切换到 v3：先部署本 SDK；以 2xx 应答 `WrongPayloadVersion` 并保留其原始 JSON；然后在仪表板中将
Webhook 切换为 `payloadVersion` 3；再等待约 2 小时，因为切换前排队的重试仍以旧格式到达。

## 错误与重试

每个错误都包含模块 `Finlight::Error`（`rescue Finlight::Error`），并有一个 `kind` 字符串。

| 错误 | Kind | 何时 |
|---|---|---|
| `Finlight::ApiError` | `api` | API 返回错误：`status`、`code`、`type`、`title`、`detail`、`request_id`、`errors`（`FieldIssue`）、`api_kind`、`raw`（正文文本）、`raw_json`。 |
| `ValidationFailedError`、`CursorInvalidError`、`CursorMismatchError`、`UnauthorizedError`、`ForbiddenError`、`NotFoundError`、`RateLimitedError`、`InternalServerError` | `api` | 每个问题代码一个子类。未知代码为普通 `ApiError`（`api_kind` 为 `other`）。 |
| `Finlight::RateLimitedError` | `api` | `limit_type` 为 `monthly`、`burst` 或更新的值；`retry_after` 以秒为单位。 |
| `Finlight::ValidationError` | `validation` | 在发送前于本地被拒绝。也是 `ArgumentError`。`param` 指出键名。 |
| `Finlight::NetworkError`、`Finlight::TimeoutError` | `network`、`timeout` | 网络故障或超时。原始错误在 `cause` 中。 |
| `Finlight::DecodeError` | `decode` | 单个响应无法读取（`path`、`raw`）。 |
| `Finlight::WebhookVerificationError` | `webhook_verification` | Webhook 校验失败（`reason`）。 |
| `Finlight::PreemptedError` | `preempted` | 另一个连接接管了流（`reason`、`new_lease_id`）。`quota_reconnect: false` 时配额用完也会抛出。 |

重试：5xx、网络错误和超时最多重试 3 次，等待时间递增，搜索请求同样适用。400、401、403、404 和每月 429 绝不重试。
REST 调用绝不等待新的配额周期：每月 429 立即失败，`search_all` 中也是如此。只有流会等待配额。
突发 429 会精确等待 `Retry-After` 秒（无该头时 10 秒）后再试一次，且不计入 `max_retries`。
设置 `retry_on_burst: "off"` 可关闭。每次调用发送自己的 `X-Request-Id`，重试时保持不变；错误对象以 `request_id` 携带。

要取消调用，请停止其线程（`Thread#raise`、`Thread#kill`）或用 `Timeout.timeout` 包裹：等待立即结束且不会重试。
`total_timeout:` 限制整个调用的时间，包括重试和突发等待。

## 配置

```ruby
client = Finlight::Client.new(
  api_key: ENV.fetch("FINLIGHT_API_KEY"),
  base_url: "https://api.finlight.me",  # a trailing slash is fine
  wss_url: "wss://wss.finlight.me",     # raw streams use <wss_url>/raw
  timeout: 30.0,                        # seconds per attempt
  total_timeout: nil,                   # optional cap per call, retries included
  max_retries: 3,
  retry_on_burst: "once",               # or "off"
  max_pages: 10,
  quota_reconnect: true,
  quota_reconnect_interval: 3600.0
)
```

所有时间均以秒为单位（Float）。也可以创建 `Finlight::Config` 并通过 `config:` 传入。

| 键 | 默认值 |
|---|---|
| `api_key` | 必填，不能为空 |
| `base_url` | `https://api.finlight.me` |
| `wss_url` | `wss://wss.finlight.me`（raw：`/raw`） |
| `timeout` | 每次尝试 30 秒 |
| `total_timeout` | 无 |
| `max_retries` | 3 |
| `retry_base_delay`、`retry_max_delay` | 0.5 秒、8 秒 |
| `retry_on_burst` | `"once"`（或 `"off"`） |
| `burst_wait` | 10 秒，仅在没有 `Retry-After` 时 |
| `max_pages` | 10 |
| `max_response_bytes` | 32 MiB |
| `company_cache_size` | 256（0 = 关闭） |
| `ping_interval`、`watchdog_timeout`、`rotation_interval` | 25 秒、60 秒、115 分钟 |
| `reconnect_base_delay`、`reconnect_max_delay` | 1 秒、30 秒 |
| `long_backoff` | 60 秒 |
| `quota_reconnect`、`quota_reconnect_interval` | 开启、1 小时 |
| `search_failed_threshold` | 5 |
| `dedupe_cache_size` | 1000 |
| `max_message_bytes` | 32 MiB |
| `connect_timeout` | 30 秒（WebSocket 连接与握手） |
| `logger` | 静默 |
| `clock` | 系统时钟（任何带有 `monotonic` 和 `sleep` 的对象） |
| `http_client` | `Net::HTTP` |
| `ws_connect` | 内置的 websocket-driver 传输 |

自定义 HTTP 客户端：`http_client:` 接受任何带有 `call(method, url, headers, body)` 并返回 `[status, headers, body]`
的对象，此时适用它自己的超时，而不是 `timeout:`。不要为它添加重试：每次尝试都消耗配额。自定义 WebSocket 传输：
`ws_connect:` 接受一个可调用对象 `(url, headers)`，返回带有 `send_text`、`receive` 和 `close(code)` 的连接
（参见 `Finlight::Transport`）。请严格按给定的名称发送头：网关需要小写的 `x-api-key`。SDK 绝不关闭不是它创建的客户端。
内置传输不读取环境变量中的代理设置。

每个 REST 请求和 WebSocket 连接都会发送 `User-Agent: finlight-client-ruby/1.0.0` 和 `x-client-version: 1.0.0`。

## 日志

SDK 通过你以 `logger:` 传入的标准 `Logger` 记录日志，progname 为 `finlight`。未设置时保持静默。
它从不直接写入 stdout 或 stderr，不修改全局日志设置，也不安装信号处理器，不会在 info 级别记录每条消息。
API 密钥、Webhook 密钥、签名和完整的请求体绝不会出现在日志、错误消息或 `inspect` 输出中。

## 数据说明

- 旧文章的 `published_at` 可能是 `"1970-01-01T00:00:00.000Z"`，按原样发送。
- 空文本为 `nil`（`summary`、`content`），绝不是 `""`。
- 在引入角色之前打标签的文章，`role` 和 `relevance` 为 `nil`，`events` 为 `[]`。
- 对于引入 id 之前收录的文章，`articles.get(id)` 返回 404，请使用 `get_by_link`。
- 旧文章的 `available_at` 为 `nil`，raw 流和 raw Webhook 中始终为 `nil`。
- 来源未分类时，`source.type` 和 `Source#type` 为 `nil`。来源类型出现之前索引的文章也为 `nil`。
  来源重新分类后，旧文章保留原来的类型。

## 从 0.x 迁移

完整指南见 [docs.finlight.me](https://docs.finlight.me/migration/v2-to-v3)。简要对照：

| 0.x | 1.x |
|---|---|
| `require "finlight/client"` | `require "finlight"` |
| `Finlight::Client::VERSION` | `Finlight::VERSION` |
| `client.articles.fetch_articles(query:, page_size:, page:)` | `client.articles.search(query:, limit:)`、`client.articles.search_all(...)` |
| `page` / `page_size` | `limit` / `cursor` |
| `client.articles.fetch_article_by_link(link:)` | `client.articles.get_by_link(link)`、`client.articles.get(id)` |
| `include_content`、`include_entities`、`extended` | `include: ["content", "companies", "events"]` |
| `order: "DESC"` | `order: "desc"` |
| `publish_date`、`created_at`、`revised_date` | `published_at`、`first_seen_at`、`revised_at`（字符串；`*_time` 解析） |
| `images` | `media.map(&:url)` |
| `source`（字符串） | `source.domain` |
| `sentiment`、`confidence` | `sentiment.label`、`sentiment.confidence` |
| `client.sources.get_sources` | `client.sources.list` |
| `client.websocket.connect(**params) { \|article\| }` | `client.stream(**params).each { \|event\| event.data }` |
| `client.raw_websocket` | `client.raw_stream(...)` |
| `Finlight::BlockedError` | 从 `each` 抛出的 `Finlight::ApiError` |
| `Finlight::WebhookService.construct_event(...)` | `Finlight::Webhooks.construct_event(raw_body, headers, secret)` |
| Webhook `isUpdate` | `event.event == "article.updated"`、`event.changed_fields` |
| Webhook 请求体 | `event.data`，以及用于去重的 `event.event_id` |
| （新增） | `client.companies.search`、`get_many`、`get` |

不要在同一个密钥上同时运行 0.x 和 1.x 的流：它们共享连接数上限。

切换 Webhook 的四个步骤：

1. 部署本 SDK。
2. 以 2xx 应答 `Finlight::WrongPayloadVersion` 并保留 `result.raw`。
3. 在仪表板中将 Webhook 切换为 `payloadVersion` 3。
4. 等待约 2 小时：切换前排队的重试仍以旧格式到达。

## 开发

```bash
bundle install
bundle exec rake                 # kit check, every conformance case, unit tests, RuboCop, README, examples
bundle exec rake "conformance:sync[../path/to/shared/contracts/api-v3]"
ruby scripts/check_package.rb    # build the gem into an empty pkg/ and check its contents
```

`conformance/` 是 API v3 契约套件的副本（`CONTRACT_VERSION`、带 sha256 校验和的 `MANIFEST`）。
`CONFORMANCE.md` 将每个套件用例映射到对应的测试。单元测试和一致性测试只使用 127.0.0.1，不需要密钥。
实时测试只针对 dev 环境，且只在明确要求时运行：

```bash
FINLIGHT_LIVE=1 FINLIGHT_API_KEY=... FINLIGHT_BASE_URL=https://api.dev.finlight.me \
  FINLIGHT_WSS_URL=wss://wss.dev.finlight.me bundle exec rspec spec/live
```

## 许可证

MIT
