# finlight client for Ruby

*English | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md)*

[![Gem Version](https://badge.fury.io/rb/finlight-client.svg)](https://rubygems.org/gems/finlight-client)
[![Test](https://github.com/callbk/finlight-client-ruby/actions/workflows/test.yml/badge.svg)](https://github.com/callbk/finlight-client-ruby/actions/workflows/test.yml)

> **Breaking release.** Version 1.0.0 speaks only the finlight API v3. Code written for 0.x does not run
> unchanged. To stay on 0.x (API v2), pin `gem "finlight-client", "~> 0.1.0"`. A pin of `~> 0.1` does not
> pull in 1.0, but an open pin such as `>= 0.1` does. See [Migrating from 0.x](#migrating-from-0x).

Ruby client for the [finlight](https://finlight.me) news API: search and look up financial news,
companies and sources over REST, stream articles in real time over WebSocket, and verify webhooks.

## Versions

| SDK version | API version | Status |
|---|---|---|
| 1.x | v3 (REST `/v3`, WebSocket `payloadVersion` 3, v3 webhooks) | current |
| 0.x | v2 | no further releases |

SDK and API versions are independent. Other finlight SDKs that speak API v3: TypeScript 4.x,
Python 3.x, PHP 2.x, Go module `/v2`, .NET 2.x, Java 1.x, Ruby 1.x, Rust 0.2.

## Requirements

- Ruby 3.2 or newer (tested on 3.2, 3.3, 3.4 and 4.0)
- `websocket-driver` 0.7.7 or newer (below 1.0), `logger` 1.5 or newer
- Everything else comes from the standard library (`net/http`, `json`, `openssl`)

## Installation

```bash
bundle add finlight-client --version "~> 1.0"
```

## Quick start

```ruby
require "finlight"

client = Finlight::Client.new(api_key: ENV.fetch("FINLIGHT_API_KEY"))
page = client.articles.search(query: "ticker:NVDA", limit: 10)
page.articles.each { |article| puts "#{article.published_at} #{article.title}" }
```

Arguments are keyword arguments in snake_case. Each one maps to exactly one key of the API
(`event_types` is `eventTypes`). Only the arguments you pass are sent: a search without arguments
sends `{}`. Values from vocabularies (event types, roles, ...) stay plain Strings and are not checked
locally, so new server values work without an SDK update.

## Search articles

```ruby
page = client.articles.search(
  query: "eventType:mna AND companyCountry:US",
  languages: ["en", "de"],
  from: Time.utc(2026, 11, 1),      # a Time, a Date or a String
  event_types: ["mna"],
  min_relevance: 0.5,
  order_by: "availableAt",
  include: ["content", "companies", "events"],
  limit: 50
)
puts page.pagination.has_more, page.pagination.next_cursor
```

`search_all` walks the pages for you. It freezes the request when you call it; later pages change only
the `cursor`. It stops after `max_pages` pages (default 10), because every page costs quota.

```ruby
results = client.articles.search_all(query: "ticker:AAPL", limit: 100, max_pages: 5)
results.each { |article| puts article.title } # or: results.pages.each { |page| ... }
puts "continue with cursor #{results.next_cursor}" if results.truncated?
```

A result can be iterated once; a second pass raises `Finlight::ValidationError`. Pass `cursor:` to go
on where a walk stopped. Unknown keywords and wrong shapes (`limit: 0`, `languages: []`, more than 3
`include` values) raise `Finlight::ValidationError` (an `ArgumentError`) before anything is sent.
`Time` values go out as UTC ISO 8601 with milliseconds, `Date` values as `YYYY-MM-DD`, Strings unchanged.

## Look up articles, companies and sources

```ruby
article = client.articles.get("EU8JwpsZ8iJehuyPZjMqRz", include: ["content"])
article = client.articles.get_by_link("https://www.reuters.com/...")

companies = client.companies.search("NVDA", mic: "XNAS") # at most 10, no pages
companies = client.companies.get_many([4821, 1001])
company = client.companies.get(4821)                     # revalidated with its ETag next time
puts company.cache_info.etag

sources = client.sources.list
```

- A miss raises `Finlight::NotFoundError`; it is never an empty result. Articles indexed before article
  ids existed answer 404 by id; look them up by link.
- `companies.*` needs the `entityAccess` entitlement (`Finlight::ForbiddenError` otherwise).
- `companies.get` keeps up to 256 records (`company_cache_size`) and revalidates them with their ETag.
  A 304 returns the cached record. With your own ETag, `companies.get(id, if_none_match: etag)` returns
  `nil` on 304 ("not modified").
- `CompanyList` and `SourceList` are Enumerable. Entries that could not be read are left out, logged
  as a warning and kept in `skipped` (index, raw JSON, reason). Pages of `search` have `skipped` too.

## Absent, null and empty

Some keys depend on your plan and on `include`. They have three states: absent (not requested, not
entitled, or a raw article), `null` (no value), or a value.

```ruby
article.content_present?    # was "content" sent? (null counts as sent)
article.content             # nil when absent or null
article.sentiment_present?  # the same for "sentiment"
article.companies_present?  # companies is nil when absent; [] means "tagged, nothing found"
article.events_present?     # the same for events
article.raw_json            # the JSON as received, unknown keys included
```

- `companies: []` means the article was tagged and no company was found. `nil` means you did not get
  the block at all. Never read absent as "no companies".
- `events[].company_ids` is only sent when `companies` is in the same answer; otherwise it is `nil`.
- Timestamps stay the Strings that were sent (`published_at`). `published_at_time`, `first_seen_at_time`,
  `revised_at_time`, `available_at_time` parse them strictly (RFC 3339) and return `nil` for anything
  unreadable.
- Unknown keys from newer servers are ignored. `raw_json` and `to_wire` give the JSON back.
- Models are immutable `Data` objects. Vocabulary values are Strings, never Symbols. Compare them with
  the constants (`Finlight::EventType::MNA`, `Finlight::CompanyRole::ACQUIRER`); `ALL` lists the known
  values. Unknown values are kept as sent.

## Real-time streams

```ruby
stream = client.stream(
  query: "ticker:NVDA",
  language: "en",
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

- `each` blocks. Leave it with `break`, or call `stream.close` from another thread: the socket closes
  with 1000 and every background thread ends. A stream can be iterated once.
- `event.kind` is `created`, `updated` or `other`. `event.raw_json` is the whole frame.
- `client.raw_stream(query:, sources:, exclude_sources:, language:, include_updates:)` delivers articles
  before enrichment. It takes no `include`; there is no content, sentiment, companies or events.
- The stream pings every 25 s, reconnects when no pong came for 60 s, and opens a fresh connection after
  115 minutes. After each reconnect it sends the same subscribe and drops duplicates.
- It never backfills. `on_reconnect` gets the latest `availableAt` you saw (raw: `firstSeenAt`). Fill gaps
  with `client.articles.search_all(from: info.last_seen_at, order_by: "availableAt")`.
- Hooks run on the iterating thread, between elements. An error in a hook is logged and does not stop
  the stream.
- Terminal problems raise out of `each`: an invalid key (`UnauthorizedError`), a plan without WebSockets
  (`ForbiddenError`), a rejected subscribe (`ValidationFailedError`), `PreemptedError` with reason
  `connection_limit` when another connection took over, and close code 1008. Other problems reconnect
  and go to `on_error`.
- When the monthly WebSocket quota is used up (the dial is refused, or `connection.preempted` with reason
  `quota_exceeded`), the stream does not end. It tries again every hour until the quota allows it. Each
  wait is logged as a warning and passed to `on_quota_wait` (not to `on_error`). Set
  `quota_reconnect: false` to end the stream with the error instead; `quota_reconnect_interval` changes
  the hour.

Limits to know:

- Your plan's connection limit is shared by enriched, raw and older SDK connections. When the limit is
  reached, a new connection is refused and the SDK retries after 60 s. Pass `takeover: true` to
  `stream` to replace the oldest connection instead.
- Connections live at most 2 hours; the SDK rotates them after 115 minutes.
- Right after subscribing, the server sends the newest matching article once, also after every
  reconnect and rotation. It can be old. The duplicate filter drops it when you already had it.
- Live frames over 32,000 bytes are dropped by the server without notice. This can happen with
  `include: ["content"]` on long articles. Fetch them with `articles.get`.
- `connection.admitted` arrives before the server checks the subscribe. It does not mean it was accepted.

## Webhooks

finlight signs every webhook. Verify it with the **raw** request body, before parsing anything:

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

- `headers` can be a Hash in any case, the Rack env (`HTTP_X_WEBHOOK_SIGNATURE`), or name/value pairs.
  `construct_event_from_values(raw_body, signature, timestamp, secret)` takes the two header values;
  `verify_signature` only checks.
- The timestamp must be within 300 s (`tolerance:`) in both directions. `now:` replaces the clock.
- Deliveries can repeat: deduplicate on `event_id`. `result.test?` is true for the dashboard test webhook.
- Answer within 5 s with 2xx and do slow work afterwards. Never answer 410: it disables the webhook at
  once. Ten non-2xx answers in a row disable it too.
- A correctly signed body that is not `payloadVersion` 3 returns `Finlight::WrongPayloadVersion`, a result
  and not an error. Answer it with 2xx.

Getting the raw body:

| Framework | Raw body |
|---|---|
| Rack | `env["rack.input"].read` |
| Rails | `request.raw_post` |
| Sinatra | `request.body.read` |
| Hanami | `request.body.read` |

`examples/webhook_endpoint.rb` is a complete Rack app.

Switching a webhook to v3: deploy this SDK first; answer `WrongPayloadVersion` with 2xx and keep its raw
JSON; then switch the webhook to `payloadVersion` 3 in the dashboard; then wait about 2 hours, because
retries queued before the switch still arrive in the old format.

## Errors and retries

Every error includes the module `Finlight::Error` (`rescue Finlight::Error`) and has a `kind` String.

| Error | Kind | When |
|---|---|---|
| `Finlight::ApiError` | `api` | The API answered with an error: `status`, `code`, `type`, `title`, `detail`, `request_id`, `errors` (`FieldIssue`), `api_kind`, `raw` (body text), `raw_json`. |
| `ValidationFailedError`, `CursorInvalidError`, `CursorMismatchError`, `UnauthorizedError`, `ForbiddenError`, `NotFoundError`, `RateLimitedError`, `InternalServerError` | `api` | One subclass per problem code. Unknown codes stay a plain `ApiError` (`api_kind` `other`). |
| `Finlight::RateLimitedError` | `api` | `limit_type` is `monthly`, `burst` or a newer value; `retry_after` in seconds. |
| `Finlight::ValidationError` | `validation` | Rejected locally, before anything was sent. Also an `ArgumentError`. `param` names the key. |
| `Finlight::NetworkError`, `Finlight::TimeoutError` | `network`, `timeout` | Network failure or timeout. The original error is `cause`. |
| `Finlight::DecodeError` | `decode` | A single answer could not be read (`path`, `raw`). |
| `Finlight::WebhookVerificationError` | `webhook_verification` | A webhook failed verification (`reason`). |
| `Finlight::PreemptedError` | `preempted` | Another connection took over the stream (`reason`, `new_lease_id`). With `quota_reconnect: false` also when the quota ran out. |

Retries: 5xx answers, network errors and timeouts are retried up to 3 times with growing waits, the
search included. 400, 401, 403, 404 and a monthly 429 are never retried. A REST call never waits for a new
quota period: a monthly 429 fails at once, also inside `search_all`. Only streams wait for the quota.
A burst 429 waits exactly `Retry-After` seconds (10 without the header) and tries once more; this does
not count against `max_retries`. Set `retry_on_burst: "off"` to turn it off. Every call sends its own
`X-Request-Id`, the same on each retry; error objects carry it as `request_id`.

To cancel a call, stop its thread (`Thread#raise`, `Thread#kill`) or wrap it in `Timeout.timeout`: waits
end at once and nothing is retried. `total_timeout:` caps a whole call, retries and burst wait included.

## Configuration

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

All times are seconds (Float). You can also build a `Finlight::Config` and pass `config:`.

| Key | Default |
|---|---|
| `api_key` | required, not empty |
| `base_url` | `https://api.finlight.me` |
| `wss_url` | `wss://wss.finlight.me` (raw: `/raw`) |
| `timeout` | 30 s per attempt |
| `total_timeout` | none |
| `max_retries` | 3 |
| `retry_base_delay`, `retry_max_delay` | 0.5 s, 8 s |
| `retry_on_burst` | `"once"` (or `"off"`) |
| `burst_wait` | 10 s, only without `Retry-After` |
| `max_pages` | 10 |
| `max_response_bytes` | 32 MiB |
| `company_cache_size` | 256 (0 = off) |
| `ping_interval`, `watchdog_timeout`, `rotation_interval` | 25 s, 60 s, 115 min |
| `reconnect_base_delay`, `reconnect_max_delay` | 1 s, 30 s |
| `long_backoff` | 60 s |
| `quota_reconnect`, `quota_reconnect_interval` | on, 1 h |
| `search_failed_threshold` | 5 |
| `dedupe_cache_size` | 1000 |
| `max_message_bytes` | 32 MiB |
| `connect_timeout` | 30 s (WebSocket dial and handshake) |
| `logger` | silent |
| `clock` | system clock (any object with `monotonic` and `sleep`) |
| `http_client` | `Net::HTTP` |
| `ws_connect` | the built-in websocket-driver transport |

Your own HTTP client: `http_client:` takes any object with `call(method, url, headers, body)` that returns
`[status, headers, body]`. Its timeouts apply, not `timeout:`. Do not add retries to it: every attempt
costs quota. Your own WebSocket transport: `ws_connect:` takes a callable `(url, headers)` that returns
a connection with `send_text`, `receive` and `close(code)` (see `Finlight::Transport`). Send the header
names exactly as given: the gateway needs a lowercase `x-api-key`. The SDK never closes a client it did
not create. The built-in transport does not read proxy settings from the environment.

Every REST request and WebSocket dial sends `User-Agent: finlight-client-ruby/1.0.0` and
`x-client-version: 1.0.0`.

## Logging

The SDK logs through the standard `Logger` you pass as `logger:`, with the progname `finlight`. Without
one it is silent. It never writes to stdout or stderr itself, never changes global log settings and
installs no signal handlers. It does not log every message on info. The API key, the webhook secret,
signatures and full bodies never appear in logs, error messages or `inspect` output.

## Data notes

- Old articles can carry `published_at` `"1970-01-01T00:00:00.000Z"`. It is delivered as sent.
- Empty texts come as `nil` (`summary`, `content`), never `""`.
- Articles tagged before roles existed have `role` and `relevance` `nil`, and `events` `[]`.
- `articles.get(id)` answers 404 for articles indexed before ids existed. Use `get_by_link`.
- `available_at` is `nil` on older articles and always `nil` on raw streams and raw webhooks.

## Migrating from 0.x

The full guide is on [docs.finlight.me](https://docs.finlight.me/migration/v2-to-v3). The short version:

| 0.x | 1.x |
|---|---|
| `require "finlight/client"` | `require "finlight"` |
| `Finlight::Client::VERSION` | `Finlight::VERSION` |
| `client.articles.fetch_articles(query:, page_size:, page:)` | `client.articles.search(query:, limit:)`, `client.articles.search_all(...)` |
| `page` / `page_size` | `limit` / `cursor` |
| `client.articles.fetch_article_by_link(link:)` | `client.articles.get_by_link(link)`, `client.articles.get(id)` |
| `include_content`, `include_entities`, `extended` | `include: ["content", "companies", "events"]` |
| `order: "DESC"` | `order: "desc"` |
| `publish_date`, `created_at`, `revised_date` | `published_at`, `first_seen_at`, `revised_at` (Strings; `*_time` parses) |
| `images` | `media.map(&:url)` |
| `source` (String) | `source.domain` |
| `sentiment`, `confidence` | `sentiment.label`, `sentiment.confidence` |
| `client.sources.get_sources` | `client.sources.list` |
| `client.websocket.connect(**params) { \|article\| }` | `client.stream(**params).each { \|event\| event.data }` |
| `client.raw_websocket` | `client.raw_stream(...)` |
| `Finlight::BlockedError` | `Finlight::ApiError` raised out of `each` |
| `Finlight::WebhookService.construct_event(...)` | `Finlight::Webhooks.construct_event(raw_body, headers, secret)` |
| webhook `isUpdate` | `event.event == "article.updated"`, `event.changed_fields` |
| webhook body | `event.data`, plus `event.event_id` for deduplication |
| (new) | `client.companies.search`, `get_many`, `get` |

Do not run 0.x and 1.x streams side by side on one key: they share the connection limit.

Switching your webhook, in four steps:

1. Deploy this SDK.
2. Answer `Finlight::WrongPayloadVersion` with 2xx and keep `result.raw`.
3. Switch the webhook to `payloadVersion` 3 in the dashboard.
4. Wait about 2 hours: retries queued before the switch still arrive in the old format.

## Development

```bash
bundle install
bundle exec rake                 # kit check, every conformance case, unit tests, RuboCop, README, examples
bundle exec rake "conformance:sync[../path/to/shared/contracts/api-v3]"
ruby scripts/check_package.rb    # build the gem into an empty pkg/ and check its contents
```

`conformance/` is a copy of the API v3 contract kit (`CONTRACT_VERSION`, `MANIFEST` with sha256 sums).
`CONFORMANCE.md` maps every kit case to its test. Unit and conformance tests use only 127.0.0.1 and need
no keys. Live tests run only against dev and only on request:

```bash
FINLIGHT_LIVE=1 FINLIGHT_API_KEY=... FINLIGHT_BASE_URL=https://api.dev.finlight.me \
  FINLIGHT_WSS_URL=wss://wss.dev.finlight.me bundle exec rspec spec/live
```

## License

MIT
