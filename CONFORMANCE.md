# Conformance case map

Every case of the finlight API v3 contract kit (`conformance/conformance.md`, kit version in
`conformance/CONTRACT_VERSION`) and the RSpec file that runs it. Each case is its own example: its
description starts with the case id and it carries the metadata `kit_case: "<id>"` (D-10 has one
example per sub-case of the matrix). `spec/conformance/case_map_spec.rb` fails when a kit case is
missing here, when the mapped file has no example for it, or when `conformance/` does not match its
MANIFEST. It needs the whole suite loaded (`bundle exec rake` or `bundle exec rspec`) and skips itself when only
some spec files run.

Re-sync the kit with one command: `bundle exec rake "conformance:sync[<kit dir>]"`
(or `ruby scripts/sync_conformance.rb --from <kit dir>`).

How the cases run:

- HTTP cases (R-01 to R-12, P, E, F-04) run against a real HTTP server on 127.0.0.1 (WEBrick), so the
  bytes after serialization are checked. Retry waits go through a recording clock; tests never wait
  for real.
- WebSocket cases (S, R-13, R-14) run the SDK's own transport against an in-process WebSocket server on
  127.0.0.1, driven by `spec/support/session_engine.rb` and a fake clock. Steps the SDK can never
  produce (a truncated frame, a legacy key, a re-subscribe on the same connection, a ping before the
  subscribe, a ping on `$default`) are not sent; the server answers in the fixture still are.
- S-02 reads the raw upgrade bytes on a plain TCP listener.

| Case | Title | Test |
|---|---|---|
| V-01 | Known constants equal vocab.json | `spec/conformance/vocab_spec.rb` |
| D-01 | Full article: every include, every entitlement | `spec/conformance/decode_spec.rb` |
| D-02 | Raw skeleton (raw channel ignores include and entitlements) | `spec/conformance/decode_spec.rb` |
| D-03 | No include, every entitlement | `spec/conformance/decode_spec.rb` |
| D-04 | Every include requested, no entitlement | `spec/conformance/decode_spec.rb` |
| D-05 | events requested and entitled, companies not requested | `spec/conformance/decode_spec.rb` |
| D-06 | events and companies requested, entityAccess missing | `spec/conformance/decode_spec.rb` |
| D-07 | Legacy values delivered as they are | `spec/conformance/decode_spec.rb` |
| D-08 | Non-ASCII text | `spec/conformance/decode_spec.rb` |
| D-09 | Sentiment with a null label, event with null direction/importance/confidence, companies [] | `spec/conformance/decode_spec.rb` |
| D-10 | Decode matrix (include x entitlements x enriched/raw) | `spec/conformance/decode_spec.rb` |
| D-11 | Blank summary and content arrive as null | `spec/conformance/decode_spec.rb` |
| F-01 | Unknown fields at every level of the article | `spec/conformance/forward_compat_spec.rb` |
| F-02 | Unknown values in every open response enum | `spec/conformance/forward_compat_spec.rb` |
| F-03 | New keys on REST, webhook and WebSocket envelopes | `spec/conformance/forward_compat_spec.rb` |
| F-04 | Unknown webhook event name, unknown problem code, unknown 429 limitType | `spec/conformance/forward_compat_spec.rb` |
| R-01 | articles.search with one parameter sends exactly that parameter | `spec/conformance/requests_spec.rb` |
| R-02 | articles.search with every parameter | `spec/conformance/requests_spec.rb` |
| R-03 | articles.search without parameters | `spec/conformance/requests_spec.rb` |
| R-04 | articles.get with include, comma-joined | `spec/conformance/requests_spec.rb` |
| R-05 | articles.getByLink URL-encodes the link | `spec/conformance/requests_spec.rb` |
| R-06 | companies.search with q and mic | `spec/conformance/requests_spec.rb` |
| R-07 | companies.getMany joins ids with commas | `spec/conformance/requests_spec.rb` |
| R-08 | companies.get returns ETag and Cache-Control | `spec/conformance/requests_spec.rb` |
| R-09 | companies.get with If-None-Match answers 304 | `spec/conformance/requests_spec.rb` |
| R-10 | sources.list with fullArticleAccess | `spec/conformance/requests_spec.rb` |
| R-11 | sources.list without fullArticleAccess | `spec/conformance/requests_spec.rb` |
| R-12 | An unknown request key is dropped silently by the server | `spec/conformance/requests_spec.rb` |
| R-13 | WebSocket subscribe frame, enriched | `spec/conformance/ws_sessions_spec.rb` |
| R-14 | WebSocket subscribe frame, raw | `spec/conformance/ws_sessions_spec.rb` |
| P-01 | Three-page cursor walk | `spec/conformance/pagination_spec.rb` |
| P-02 | limit and include may change between pages | `spec/conformance/pagination_spec.rb` |
| P-03 | Adding "to" on page 2 breaks the cursor | `spec/conformance/pagination_spec.rb` |
| P-04 | Adding the default languages ["en"] on page 2 breaks the cursor | `spec/conformance/pagination_spec.rb` |
| P-05 | Changing order on page 2 | `spec/conformance/pagination_spec.rb` |
| P-06 | Reordering list values keeps the cursor valid | `spec/conformance/pagination_spec.rb` |
| E-01 | Unknown enum value | `spec/conformance/errors_spec.rb` |
| E-02 | Several invalid fields at once | `spec/conformance/errors_spec.rb` |
| E-03 | Unknown field in the query language | `spec/conformance/errors_spec.rb` |
| E-04 | Empty languages array | `spec/conformance/errors_spec.rb` |
| E-05 | Unknown include value on a GET lookup | `spec/conformance/errors_spec.rb` |
| E-06 | companies.search without q and ids | `spec/conformance/errors_spec.rb` |
| E-07 | companies.search with q and ids | `spec/conformance/errors_spec.rb` |
| E-08 | Non-integer company id in ids | `spec/conformance/errors_spec.rb` |
| E-09 | Non-integer companyId in the path | `spec/conformance/errors_spec.rb` |
| E-10 | Cursor that is not a cursor | `spec/conformance/errors_spec.rb` |
| E-11 | Cursor of an unsupported version | `spec/conformance/errors_spec.rb` |
| E-12 | No API key | `spec/conformance/errors_spec.rb` |
| E-13 | Unknown API key | `spec/conformance/errors_spec.rb` |
| E-14 | Company lookup without entityAccess | `spec/conformance/errors_spec.rb` |
| E-15 | Unknown article id | `spec/conformance/errors_spec.rb` |
| E-16 | Unknown article link | `spec/conformance/errors_spec.rb` |
| E-17 | Unknown company id | `spec/conformance/errors_spec.rb` |
| E-18 | Monthly token limit reached | `spec/conformance/errors_spec.rb` |
| E-19 | Burst limit reached | `spec/conformance/errors_spec.rb` |
| E-20 | Server failure | `spec/conformance/errors_spec.rb` |
| E-21 | Malformed JSON body (NestJS fallback form) | `spec/conformance/errors_spec.rb` |
| E-22 | Unknown route under /v3 (NestJS fallback form) | `spec/conformance/errors_spec.rb` |
| E-23 | No X-Request-Id sent: the server generates one | `spec/conformance/errors_spec.rb` |
| E-24 | Non-JSON error body | `spec/conformance/errors_spec.rb` |
| E-25 | Cursor issued for another sort order | `spec/conformance/errors_spec.rb` |
| W-01 | article.created, enriched, every include, non-ASCII body | `spec/conformance/webhooks_spec.rb` |
| W-02 | article.updated with changedFields | `spec/conformance/webhooks_spec.rb` |
| W-03 | article.updated for a plan without fullArticleAccess | `spec/conformance/webhooks_spec.rb` |
| W-04 | article.created on a raw webhook | `spec/conformance/webhooks_spec.rb` |
| W-05 | Dashboard test webhook (evt_test…) | `spec/conformance/webhooks_spec.rb` |
| W-06 | v2 body is reported as wrong payload version | `spec/conformance/webhooks_spec.rb` |
| W-07 | Body changed after signing | `spec/conformance/webhooks_spec.rb` |
| W-08 | Timestamp older than the tolerance | `spec/conformance/webhooks_spec.rb` |
| W-09 | Timestamp further in the future than the tolerance | `spec/conformance/webhooks_spec.rb` |
| W-10 | Timestamp header is not ISO 8601 | `spec/conformance/webhooks_spec.rb` |
| W-11 | Timestamp in unix seconds instead of ISO 8601 | `spec/conformance/webhooks_spec.rb` |
| W-12 | No X-Webhook-Timestamp header | `spec/conformance/webhooks_spec.rb` |
| W-13 | No X-Webhook-Signature header | `spec/conformance/webhooks_spec.rb` |
| W-14 | Signature without the sha256= prefix | `spec/conformance/webhooks_spec.rb` |
| W-15 | Signature computed with the hex-decoded secret | `spec/conformance/webhooks_spec.rb` |
| W-16 | Case-insensitive header lookup | `spec/conformance/webhooks_spec.rb` |
| S-01 | Ping before subscribe gets a v2 pong; after the v3 subscribe pongs are v3 | `spec/conformance/ws_sessions_spec.rb` |
| S-02 | Lowercase x-api-key on the wire | `spec/conformance/ws_raw_bytes_spec.rb` |
| S-03 | connection.admitted echoes the nonce; a re-subscribe re-admits only with the same nonce | `spec/conformance/ws_sessions_spec.rb` |
| S-04 | article.created then article.updated for the same id, then an exact duplicate | `spec/conformance/ws_sessions_spec.rb` |
| S-05 | An unknown event name arrives | `spec/conformance/ws_sessions_spec.rb` |
| S-06 | connection.error PING_ON_DEFAULT_ROUTE | `spec/conformance/ws_sessions_spec.rb` |
| S-07 | VALIDATION_FAILED for a v2 key in a v3 subscribe | `spec/conformance/ws_sessions_spec.rb` |
| S-08 | VALIDATION_FAILED for include on raw | `spec/conformance/ws_sessions_spec.rb` |
| S-09 | connection.preempted, reason connection_limit (another connection took over) | `spec/conformance/ws_sessions_spec.rb` |
| S-10 | connection.preempted, reason quota_exceeded | `spec/conformance/ws_sessions_spec.rb` |
| S-11 | Preempted before the first subscribe: the frame comes in v2 form | `spec/conformance/ws_sessions_spec.rb` |
| S-12 | Error for an unreadable message comes in v2 form | `spec/conformance/ws_sessions_spec.rb` |
| S-13 | connection.error HANDSHAKE_FAILED | `spec/conformance/ws_sessions_spec.rb` |
| S-14 | connection.error SEARCH_FAILED | `spec/conformance/ws_sessions_spec.rb` |
| S-15 | connection.error INTERNAL_ERROR | `spec/conformance/ws_sessions_spec.rb` |
| S-16 | No pong for 60 s | `spec/conformance/ws_sessions_spec.rb` |
| S-17 | Raw stream: admitted, no initial push, skeleton frames | `spec/conformance/ws_sessions_spec.rb` |
| S-18 | Proactive rotation before the 2 h connection lifetime | `spec/conformance/ws_sessions_spec.rb` |
| S-19 | Dial refused: no API key | `spec/conformance/ws_sessions_spec.rb` |
| S-20 | Dial refused: invalid API key | `spec/conformance/ws_sessions_spec.rb` |
| S-21 | Dial refused: API key in the wrong format | `spec/conformance/ws_sessions_spec.rb` |
| S-22 | Dial refused: plan without WebSockets | `spec/conformance/ws_sessions_spec.rb` |
| S-23 | Dial refused: connection limit reached, no takeover | `spec/conformance/ws_sessions_spec.rb` |
| S-24 | Dial refused: WebSocket quota exhausted | `spec/conformance/ws_sessions_spec.rb` |
| S-25 | Dial refused: lost the admit race | `spec/conformance/ws_sessions_spec.rb` |
| S-26 | Dial refused: server error | `spec/conformance/ws_sessions_spec.rb` |
| S-27 | connection.preempted, reason quota_exceeded, with quotaReconnect turned off | `spec/conformance/ws_sessions_spec.rb` |
| S-28 | Dial refused: WebSocket quota exhausted, with quotaReconnect turned off | `spec/conformance/ws_sessions_spec.rb` |
| S-29 | VALIDATION_FAILED for an unknown sourceTypes value | `spec/conformance/ws_sessions_spec.rb` |
