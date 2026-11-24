# finlight Ruby クライアント

*[English](README.md) | [简体中文](README.zh-CN.md) | 日本語 | [한국어](README.ko.md)*

> この翻訳は英語版 [README.md](README.md) に合わせて後から更新されます。内容が異なる場合は英語版が優先です。

[![Gem Version](https://badge.fury.io/rb/finlight-client.svg)](https://rubygems.org/gems/finlight-client)
[![Test](https://github.com/callbk/finlight-client-ruby/actions/workflows/test.yml/badge.svg)](https://github.com/callbk/finlight-client-ruby/actions/workflows/test.yml)

> **Breaking release.** バージョン 1.0.0 は finlight API v3 のみに対応します。0.x 用のコードはそのままでは動きません。
> 0.x（API v2）を使い続けるには `gem "finlight-client", "~> 0.1.0"` で固定してください。`~> 0.1` は 1.0 を取り込みませんが、
> `>= 0.1` のような開いた指定は取り込みます。[0.x からの移行](#0x-からの移行)を参照してください。

[finlight](https://finlight.me) ニュース API の Ruby クライアントです。REST で金融ニュース、企業、ソースを検索・参照し、
WebSocket で記事をリアルタイムに受信し、Webhook を検証できます。

## バージョン

| SDK version | API version | Status |
|---|---|---|
| 1.x | v3（REST `/v3`、WebSocket `payloadVersion` 3、v3 Webhook） | 現行 |
| 0.x | v2 | 今後のリリースなし |

SDK と API のバージョンは独立しています。API v3 に対応する他の finlight SDK：TypeScript 4.x、Python 3.x、PHP 2.x、
Go モジュール `/v2`、.NET 2.x、Java 1.x、Ruby 1.x、Rust 0.2。

## 動作要件

- Ruby 3.2 以降（3.2、3.3、3.4、4.0 でテスト）
- `websocket-driver` 0.7.7 以上（1.0 未満）、`logger` 1.5 以上
- それ以外はすべて標準ライブラリ（`net/http`、`json`、`openssl`）

## インストール

```bash
bundle add finlight-client --version "~> 1.0"
```

## クイックスタート

```ruby
require "finlight"

client = Finlight::Client.new(api_key: ENV.fetch("FINLIGHT_API_KEY"))
page = client.articles.search(query: "ticker:NVDA", limit: 10)
page.articles.each { |article| puts "#{article.published_at} #{article.title}" }
```

引数は snake_case のキーワード引数です。各引数は API のちょうど 1 つのキーに対応します（`event_types` は `eventTypes`）。
渡した引数だけが送信されます。引数なしの検索は `{}` を送ります。語彙の値（イベント種別、ロールなど）は普通の文字列のままで、
ローカルでは検査しません。そのためサーバーの新しい値も SDK の更新なしで使えます。

## 記事を検索する

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

`search_all` はページをたどります。呼び出した時点でリクエストを固定し、以降のページでは `cursor` だけを変えます。
ページごとにクォータを消費するため、`max_pages` ページ（既定 10）で止まります。

```ruby
results = client.articles.search_all(query: "ticker:AAPL", limit: 100, max_pages: 5)
results.each { |article| puts article.title } # or: results.pages.each { |page| ... }
puts "continue with cursor #{results.next_cursor}" if results.truncated?
```

結果は 1 回だけ反復できます。2 回目は `Finlight::ValidationError` になります。`cursor:` を渡すと止まった所から続けられます。
未知のキーワードや形式の誤り（`limit: 0`、`languages: []`、4 つ以上の `include`）は、送信前に
`Finlight::ValidationError`（`ArgumentError` でもある）になります。`Time` はミリ秒付き UTC の ISO 8601、`Date` は
`YYYY-MM-DD`、文字列はそのまま送信されます。

`source_types` と `exclude_source_types` はソースの種類で絞り込みます（`Finlight::SourceType::ALL`、例：
`Finlight::SourceType::NEWSWIRE`）。種類が未分類のソースの記事は `source_types` に一致せず、
`exclude_source_types` では残ります。どちらも受け取れるソースを狭めるだけです。
`client.stream` と `client.raw_stream` でも使えます。

## 記事・企業・ソースを参照する

```ruby
article = client.articles.get("EU8JwpsZ8iJehuyPZjMqRz", include: ["content"])
article = client.articles.get_by_link("https://www.reuters.com/...")

companies = client.companies.search("NVDA", mic: "XNAS") # at most 10, no pages
companies = client.companies.get_many([4821, 1001])
company = client.companies.get(4821)                     # revalidated with its ETag next time
puts company.cache_info.etag

sources = client.sources.list
```

- 見つからない場合は `Finlight::NotFoundError` です。空の結果にはなりません。記事 ID 導入前に収録された記事は ID では 404 になるため、リンクで参照してください。
- `companies.*` には `entityAccess` 権限が必要です（ない場合は `Finlight::ForbiddenError`）。
- 企業・ソースの参照も記事リクエストと同じくクレジットを消費します。成功したリクエスト 1 回につき 1 クレジット（`get_many` は ID ごとではなく 1 リクエストで 1）。304 の再検証とエラーは無料です。ここでも 429 が返ることがあります。
- `companies.get` は最大 256 件（`company_cache_size`）を保持し、ETag で再検証します。304 ではキャッシュのレコードを返します。
  自分の ETag を使う `companies.get(id, if_none_match: etag)` は 304 で `nil`（「変更なし」）を返します。
- `CompanyList` と `SourceList` は Enumerable です。読めないエントリは除外され、警告としてログに出て、`skipped`
  （インデックス、生の JSON、理由）に残ります。`search` のページにも `skipped` があります。

## 欠落、null、空

一部のキーはプランと `include` に依存します。状態は 3 つです：欠落（未要求、権限なし、または raw 記事）、`null`（値なし）、値あり。

```ruby
article.content_present?    # was "content" sent? (null counts as sent)
article.content             # nil when absent or null
article.sentiment_present?  # the same for "sentiment"
article.companies_present?  # companies is nil when absent; [] means "tagged, nothing found"
article.events_present?     # the same for events
article.raw_json            # the JSON as received, unknown keys included
```

- `companies: []` は記事がタグ付けされ、企業が見つからなかったことを意味します。`nil` はブロック自体を受け取っていないことを意味します。欠落を「企業なし」と読まないでください。
- `events[].company_ids` は同じ応答に `companies` がある場合にだけ送られます。ない場合は `nil` です。
- タイムスタンプは送られた文字列のままです（`published_at`）。`published_at_time`、`first_seen_at_time`、`revised_at_time`、
  `available_at_time` は RFC 3339 で厳密に解析し、読めない値には `nil` を返します。
- 新しいサーバーの未知のキーは無視されます。`raw_json` と `to_wire` で JSON を取り出せます。
- モデルは不変の `Data` オブジェクトです。語彙の値は文字列で、Symbol にはなりません。定数
  （`Finlight::EventType::MNA`、`Finlight::CompanyRole::ACQUIRER`）と比較してください。`ALL` が既知の値の一覧です。未知の値はそのまま残ります。

## リアルタイムストリーム

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

- `each` はブロックします。`break` で抜けるか、別スレッドから `stream.close` を呼ぶと、ソケットは 1000 で閉じ、すべてのバックグラウンドスレッドが終了します。ストリームは 1 回だけ反復できます。
- `event.kind` は `created`、`updated`、`other` のいずれかです。`event.raw_json` はフレーム全体です。
- `client.raw_stream(query:, sources:, exclude_sources:, source_types:, exclude_source_types:, language:, include_updates:)` は加工前の記事を配信します。
  `include` は受け付けず、本文、センチメント、企業、イベントはありません。
- ストリームは 25 秒ごとに ping を送り、60 秒 pong がなければ再接続し、115 分後に新しい接続を開きます。再接続のたびに同じ購読を送り、重複を捨てます。
- 自動で過去分を取り直すことはしません。`on_reconnect` は最後に見た `availableAt`（raw では `firstSeenAt`）を渡します。
  `client.articles.search_all(from: info.last_seen_at, order_by: "availableAt")` で欠けた分を補ってください。
- フックは反復しているスレッドで、要素と要素の間に実行されます。フック内のエラーはログに記録され、ストリームは止まりません。
- 終了する問題は `each` から例外になります：無効なキー（`UnauthorizedError`）、WebSocket を含まないプラン（`ForbiddenError`）、
  拒否された購読（`ValidationFailedError`）、別の接続に引き継がれた場合の理由 `connection_limit` の `PreemptedError`、クローズコード 1008。
  それ以外の問題は再接続し、`on_error` に渡されます。
- 月間 WebSocket クォータを使い切った場合（接続が拒否されるか、理由 `quota_exceeded` の `connection.preempted`）、ストリームは終了しません。
  クォータが戻るまで 1 時間ごとに再試行します。待機のたびに警告をログに出し、`on_quota_wait`（`on_error` ではない）に渡します。
  `quota_reconnect: false` にするとエラーで終了します。`quota_reconnect_interval` で間隔を変えられます。

知っておくべき制限：

- プランの接続数上限は enriched、raw、旧 SDK の接続で共有されます。上限に達すると新しい接続は拒否され、SDK は 60 秒後に再試行します。
  `stream` に `takeover: true` を渡すと最も古い接続を置き換えます。
- 接続の寿命は最長 2 時間で、SDK は 115 分後に接続を入れ替えます。プランが接続数の上限に達している場合（上限 1 など）、古い接続もまだ数えられるため新しい接続は拒否されます。そのとき SDK は古い接続を閉じてすぐに接続し直すので、途切れるのは接続 1 回分ほどです。その接続も拒否された場合にだけ、通常どおり 60 秒以上待ちます。
- 購読直後、サーバーは一致する最新の記事を 1 回送ります。再接続や入れ替えのたびにも送られます。古い記事のこともあります。すでに受け取っていれば重複フィルターが捨てます。
- 32,000 バイトを超えるライブフレームはサーバーが通知なしに捨てます。長い記事で `include: ["content"]` を使うと起こり得ます。`articles.get` で取得してください。
- `connection.admitted` はサーバーが購読を検査する前に届きます。購読が受け付けられたことは意味しません。

## Webhook

finlight はすべての Webhook に署名します。何かを解析する前に、**生の**リクエストボディで検証してください：

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

- `headers` には大文字小文字を問わない Hash、Rack env（`HTTP_X_WEBHOOK_SIGNATURE`）、名前と値のペアを渡せます。
  `construct_event_from_values(raw_body, signature, timestamp, secret)` は 2 つのヘッダー値を直接受け取ります。`verify_signature` は検証だけを行います。
- タイムスタンプは前後 300 秒（`tolerance:`）以内である必要があります。`now:` で時計を差し替えられます。
- 配信は重複することがあります。`event_id` で重複を除いてください。ダッシュボードのテスト Webhook では `result.test?` が true です。
- 5 秒以内に 2xx で応答し、重い処理はその後で行ってください。410 では決して応答しないでください。Webhook が即座に無効になります。非 2xx が 10 回続いても無効になります。
- 署名は正しいが `payloadVersion` が 3 でないボディは `Finlight::WrongPayloadVersion` を返します。これはエラーではなく結果です。2xx で応答してください。

生のボディの取得方法：

| フレームワーク | 生のボディ |
|---|---|
| Rack | `env["rack.input"].read` |
| Rails | `request.raw_post` |
| Sinatra | `request.body.read` |
| Hanami | `request.body.read` |

`examples/webhook_endpoint.rb` は完全な Rack アプリです。

Webhook を v3 に切り替える：まずこの SDK をデプロイし、`WrongPayloadVersion` に 2xx で応答して生の JSON を保存します。
次にダッシュボードで Webhook を `payloadVersion` 3 に切り替え、約 2 時間待ちます。切り替え前にキューに入った再送は古い形式で届くためです。

## エラーと再試行

すべてのエラーはモジュール `Finlight::Error` を含み（`rescue Finlight::Error`）、`kind` 文字列を持ちます。

| エラー | Kind | いつ |
|---|---|---|
| `Finlight::ApiError` | `api` | API がエラーで応答した：`status`、`code`、`type`、`title`、`detail`、`request_id`、`errors`（`FieldIssue`）、`api_kind`、`raw`（本文テキスト）、`raw_json`。 |
| `ValidationFailedError`、`CursorInvalidError`、`CursorMismatchError`、`UnauthorizedError`、`ForbiddenError`、`NotFoundError`、`RateLimitedError`、`InternalServerError` | `api` | 問題コードごとのサブクラス。未知のコードは通常の `ApiError`（`api_kind` は `other`）。 |
| `Finlight::RateLimitedError` | `api` | `limit_type` は `monthly`、`burst`、またはより新しい値。`retry_after` は秒。 |
| `Finlight::ValidationError` | `validation` | 送信前にローカルで拒否された。`ArgumentError` でもある。`param` がキー名。 |
| `Finlight::NetworkError`、`Finlight::TimeoutError` | `network`、`timeout` | ネットワーク障害またはタイムアウト。元のエラーは `cause`。 |
| `Finlight::DecodeError` | `decode` | 単一の応答を読めなかった（`path`、`raw`）。 |
| `Finlight::WebhookVerificationError` | `webhook_verification` | Webhook の検証に失敗した（`reason`）。 |
| `Finlight::PreemptedError` | `preempted` | 別の接続がストリームを引き継いだ（`reason`、`new_lease_id`）。`quota_reconnect: false` ではクォータ切れのときも。 |

再試行：5xx、ネットワークエラー、タイムアウトは待ち時間を延ばしながら最大 3 回再試行します。検索も同じです。400、401、403、404、月間 429 は再試行しません。
REST 呼び出しは新しいクォータ期間を待ちません。月間 429 はすぐに失敗し、`search_all` の中でも同じです。クォータを待つのはストリームだけです。
バースト 429 はちょうど `Retry-After` 秒（ヘッダーがなければ 10 秒）待ってから 1 回だけ再試行し、これは `max_retries` に数えません。
`retry_on_burst: "off"` で無効にできます。呼び出しごとに独自の `X-Request-Id` を送り、再試行でも同じです。エラーオブジェクトは `request_id` として持ちます。

呼び出しを取り消すには、そのスレッドを止める（`Thread#raise`、`Thread#kill`）か `Timeout.timeout` で包んでください。待機はすぐに終わり、再試行はしません。
`total_timeout:` は再試行とバースト待機を含む呼び出し全体の上限です。

## 設定

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

時間はすべて秒（Float）です。`Finlight::Config` を作って `config:` で渡すこともできます。

| キー | 既定値 |
|---|---|
| `api_key` | 必須、空は不可 |
| `base_url` | `https://api.finlight.me` |
| `wss_url` | `wss://wss.finlight.me`（raw：`/raw`） |
| `timeout` | 試行ごとに 30 秒 |
| `total_timeout` | なし |
| `max_retries` | 3 |
| `retry_base_delay`、`retry_max_delay` | 0.5 秒、8 秒 |
| `retry_on_burst` | `"once"`（または `"off"`） |
| `burst_wait` | 10 秒、`Retry-After` がない場合のみ |
| `max_pages` | 10 |
| `max_response_bytes` | 32 MiB |
| `company_cache_size` | 256（0 = 無効） |
| `ping_interval`、`watchdog_timeout`、`rotation_interval` | 25 秒、60 秒、115 分 |
| `reconnect_base_delay`、`reconnect_max_delay` | 1 秒、30 秒 |
| `long_backoff` | 60 秒 |
| `quota_reconnect`、`quota_reconnect_interval` | 有効、1 時間 |
| `search_failed_threshold` | 5 |
| `dedupe_cache_size` | 1000 |
| `max_message_bytes` | 32 MiB |
| `connect_timeout` | 30 秒（WebSocket の接続とハンドシェイク） |
| `logger` | 出力なし |
| `clock` | システム時計（`monotonic` と `sleep` を持つ任意のオブジェクト） |
| `http_client` | `Net::HTTP` |
| `ws_connect` | 組み込みの websocket-driver トランスポート |

独自の HTTP クライアント：`http_client:` には `call(method, url, headers, body)` を持ち `[status, headers, body]` を返す
任意のオブジェクトを渡せます。その場合は `timeout:` ではなくそのクライアントのタイムアウトが適用されます。再試行を追加しないでください。
試行ごとにクォータを消費します。独自の WebSocket トランスポート：`ws_connect:` には `(url, headers)` を受け取り、
`send_text`、`receive`、`close(code)` を持つ接続を返す callable を渡します（`Finlight::Transport` 参照）。ヘッダー名は渡されたとおりに送ってください。
ゲートウェイは小文字の `x-api-key` を必要とします。SDK は自分が作っていないクライアントを閉じません。組み込みトランスポートは環境変数のプロキシ設定を読みません。

すべての REST リクエストと WebSocket 接続は `User-Agent: finlight-client-ruby/1.0.0` と `x-client-version: 1.0.0` を送ります。

## ログ

SDK は `logger:` で渡された標準の `Logger` に、progname `finlight` でログを出します。指定しなければ何も出しません。
stdout や stderr に直接書くことはなく、グローバルなログ設定を変えず、シグナルハンドラーも入れません。メッセージごとに info でログを出すこともありません。
API キー、Webhook シークレット、署名、ボディ全体がログ、エラーメッセージ、`inspect` の出力に現れることはありません。

## データに関する注意

- 古い記事の `published_at` が `"1970-01-01T00:00:00.000Z"` のことがあります。そのまま配信されます。
- 空のテキストは `nil`（`summary`、`content`）で、`""` にはなりません。
- ロール導入前にタグ付けされた記事は `role` と `relevance` が `nil`、`events` が `[]` です。
- ID 導入前に収録された記事では `articles.get(id)` が 404 を返します。`get_by_link` を使ってください。
- `available_at` は古い記事では `nil`、raw ストリームと raw Webhook では常に `nil` です。
- `source.type` と `Source#type` は、ソースが未分類なら `nil` です。ソースの種類が導入される前に索引された記事も
  `nil` です。ソースが再分類されても、古い記事は以前の種類のままです。

## 0.x からの移行

完全なガイドは [docs.finlight.me](https://docs.finlight.me/migration/v2-to-v3) にあります。要点：

| 0.x | 1.x |
|---|---|
| `require "finlight/client"` | `require "finlight"` |
| `Finlight::Client::VERSION` | `Finlight::VERSION` |
| `client.articles.fetch_articles(query:, page_size:, page:)` | `client.articles.search(query:, limit:)`、`client.articles.search_all(...)` |
| `page` / `page_size` | `limit` / `cursor` |
| `client.articles.fetch_article_by_link(link:)` | `client.articles.get_by_link(link)`、`client.articles.get(id)` |
| `include_content`、`include_entities`、`extended` | `include: ["content", "companies", "events"]` |
| `order: "DESC"` | `order: "desc"` |
| `publish_date`、`created_at`、`revised_date` | `published_at`、`first_seen_at`、`revised_at`（文字列。`*_time` で解析） |
| `images` | `media.map(&:url)` |
| `source`（文字列） | `source.domain` |
| `sentiment`、`confidence` | `sentiment.label`、`sentiment.confidence` |
| `client.sources.get_sources` | `client.sources.list` |
| `client.websocket.connect(**params) { \|article\| }` | `client.stream(**params).each { \|event\| event.data }` |
| `client.raw_websocket` | `client.raw_stream(...)` |
| `Finlight::BlockedError` | `each` から送出される `Finlight::ApiError` |
| `Finlight::WebhookService.construct_event(...)` | `Finlight::Webhooks.construct_event(raw_body, headers, secret)` |
| Webhook の `isUpdate` | `event.event == "article.updated"`、`event.changed_fields` |
| Webhook のボディ | `event.data`、重複除去用の `event.event_id` |
| （新規） | `client.companies.search`、`get_many`、`get` |

同じキーで 0.x と 1.x のストリームを並行して動かさないでください。接続数上限を共有します。

Webhook の切り替えは 4 ステップです：

1. この SDK をデプロイする。
2. `Finlight::WrongPayloadVersion` に 2xx で応答し、`result.raw` を保存する。
3. ダッシュボードで Webhook を `payloadVersion` 3 に切り替える。
4. 約 2 時間待つ。切り替え前にキューに入った再送は古い形式で届きます。

## 開発

```bash
bundle install
bundle exec rake                 # kit check, every conformance case, unit tests, RuboCop, README, examples
bundle exec rake "conformance:sync[../path/to/shared/contracts/api-v3]"
ruby scripts/check_package.rb    # build the gem into an empty pkg/ and check its contents
```

`conformance/` は API v3 コントラクトキットのコピーです（`CONTRACT_VERSION`、sha256 付きの `MANIFEST`）。
`CONFORMANCE.md` はキットの各ケースとテストを対応づけます。単体テストと適合テストは 127.0.0.1 だけを使い、キーは不要です。
ライブテストは dev に対してのみ、明示的に指定したときだけ実行します：

```bash
FINLIGHT_LIVE=1 FINLIGHT_API_KEY=... FINLIGHT_BASE_URL=https://api.dev.finlight.me \
  FINLIGHT_WSS_URL=wss://wss.dev.finlight.me bundle exec rspec spec/live
```

## ライセンス

MIT
