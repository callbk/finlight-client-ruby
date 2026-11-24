# Changelog

## 1.0.0 (unreleased)

**Breaking release.** 1.0.0 speaks only the finlight API v3 (REST `/v3`, WebSocket `payloadVersion` 3,
v3 webhooks). Code written for 0.x does not run unchanged. To stay on 0.x, pin
`gem "finlight-client", "~> 0.1.0"`. Migration guide: <https://docs.finlight.me/migration/v2-to-v3>

Contract kit: 3.0.0-rc.3.

### Removed

- Everything from API v1 and v2: `Finlight::Client#websocket` and `#raw_websocket`, `ArticleService`,
  `SourceService`, `WebhookService`, `ApiClient`, the v2 models and params, `FlexTime`, `BlockedError`,
  `Finlight::Client::VERSION` and `CLIENT_VERSION`.
- The entry point `require "finlight/client"`; use `require "finlight"`. `require "finlight/client"` now
  raises a `LoadError` that says so and links the migration guide.

### Added

- `Finlight::Client` with `articles.search`, `articles.search_all`, `articles.get`, `articles.get_by_link`,
  `companies.search`, `companies.get_many`, `companies.get` (with ETag revalidation and `cache_info`) and
  `sources.list`. Parameters are explicit keyword arguments; unknown keys and wrong shapes raise
  `Finlight::ValidationError` before any request. Only the keys you pass are sent.
- `search_all` freezes the request body and changes only the cursor; it stops after `max_pages` (default 10),
  logs a warning and keeps `next_cursor`. It can be iterated once.
- Immutable `Data` models (`Article`, `Company`, `CompanyRecord`, `Source`, ...) that ignore unknown keys,
  keep the raw JSON (`raw_json`, `to_wire`) and tell absent from null (`content_present?`,
  `sentiment_present?`, `companies_present?`, `events_present?`). Timestamps stay Strings, with strict
  `*_time` readers. Broken list entries are skipped, logged and kept in `skipped`.
- Open vocabularies as String constants (`Finlight::EventType`, `Finlight::CompanyRole`, ...).
- `client.stream(...)` and `client.raw_stream(...)`: a blocking `each` with ping and pong watchdog, rotation
  before the 2 hour limit, the same subscribe after every reconnect, a duplicate filter, hooks
  `on_admitted`, `on_reconnect`, `on_error` and `on_quota_wait`, and typed terminal errors
  (`PreemptedError`, `ApiError`). When the monthly WebSocket quota is used up (dial 403 "quota exceeded" or
  `connection.preempted` with reason `quota_exceeded`) the stream tries again every hour until the quota
  allows it, logging a warning and calling `on_quota_wait` each time. On by default; `quota_reconnect: false`
  ends the stream with the error instead; `quota_reconnect_interval` sets the interval. A preempt with
  reason `connection_limit` stays terminal.
- The WebSocket dial sends `x-api-key` in lowercase and reads the body of a refused upgrade.
- `Finlight::Webhooks.construct_event`, `construct_event_from_values` and `verify_signature`. A correctly
  signed body that is not `payloadVersion` 3 returns `Finlight::WrongPayloadVersion` (answer it with 2xx).
- Errors: `Finlight::ApiError` with one subclass per problem code, `ValidationError` (an `ArgumentError`),
  `NetworkError`, `TimeoutError`, `DecodeError`, `WebhookVerificationError`, `PreemptedError`. Every error
  includes `Finlight::Error` and has a `kind` String.
- Retries: up to 3 for 5xx, network errors and timeouts; never for 400, 401, 403, 404 and a monthly 429,
  which fails at once on REST, also inside `search_all`. A burst 429 waits `Retry-After` (10 s without it)
  and retries once; on by default, `retry_on_burst: "off"` turns it off.
- `User-Agent: finlight-client-ruby/1.0.0` and `x-client-version: 1.0.0` on every request and dial.
- Conformance suite: the shared API v3 contract kit runs in RSpec, one example per case (`CONFORMANCE.md`).

### Requirements

- Ruby 3.2+, `websocket-driver` >= 0.7.7 (< 1.0), `logger` >= 1.5.

## 0.1.0

Initial release (API v2).
