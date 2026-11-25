# finlight Ruby 클라이언트

*[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | 한국어*

> 이 번역은 영문 [README.md](README.md)에 맞춰 나중에 갱신됩니다. 내용이 다르면 영문판이 우선합니다.

[![Gem Version](https://badge.fury.io/rb/finlight-client.svg)](https://rubygems.org/gems/finlight-client)
[![Test](https://github.com/callbk/finlight-client-ruby/actions/workflows/test.yml/badge.svg)](https://github.com/callbk/finlight-client-ruby/actions/workflows/test.yml)

> **Breaking release.** 1.0.0 버전은 finlight API v3만 지원합니다. 0.x용 코드는 그대로 동작하지 않습니다.
> 0.x(API v2)를 계속 쓰려면 `gem "finlight-client", "~> 0.1.0"`으로 고정하세요. `~> 0.1`은 1.0을 받지 않지만,
> `>= 0.1` 같은 열린 지정은 받습니다. [0.x에서 이전하기](#0x에서-이전하기)를 참고하세요.

[finlight](https://finlight.me) 뉴스 API의 Ruby 클라이언트입니다. REST로 금융 뉴스, 기업, 소스를 검색하고 조회하며,
WebSocket으로 기사를 실시간으로 받고, Webhook을 검증합니다.

## 버전

| SDK version | API version | Status |
|---|---|---|
| 1.x | v3 (REST `/v3`, WebSocket `payloadVersion` 3, v3 Webhook) | 현재 |
| 0.x | v2 | 더 이상 릴리스 없음 |

SDK 버전과 API 버전은 서로 독립적입니다. API v3를 지원하는 다른 finlight SDK: TypeScript 4.x, Python 3.x, PHP 2.x,
Go 모듈 `/v2`, .NET 2.x, Java 1.x, Ruby 1.x, Rust 0.2.

## 요구 사항

- Ruby 3.2 이상 (3.2, 3.3, 3.4, 4.0에서 테스트)
- `websocket-driver` 0.7.7 이상(1.0 미만), `logger` 1.5 이상
- 나머지는 모두 표준 라이브러리 (`net/http`, `json`, `openssl`)

## 설치

```bash
bundle add finlight-client --version "~> 1.0"
```

## 빠른 시작

```ruby
require "finlight"

client = Finlight::Client.new(api_key: ENV.fetch("FINLIGHT_API_KEY"))
page = client.articles.search(query: "ticker:NVDA", limit: 10)
page.articles.each { |article| puts "#{article.published_at} #{article.title}" }
```

인수는 snake_case 키워드 인수입니다. 각 인수는 API의 키 하나에 정확히 대응합니다(`event_types`는 `eventTypes`).
전달한 인수만 전송됩니다. 인수 없는 검색은 `{}`를 보냅니다. 어휘 값(이벤트 유형, 역할 등)은 일반 문자열로 남고
로컬에서 검사하지 않으므로, 서버의 새 값도 SDK 업데이트 없이 동작합니다.

## 기사 검색

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

`search_all`은 페이지를 차례로 가져옵니다. 호출할 때 요청을 고정하고, 이후 페이지에서는 `cursor`만 바꿉니다.
페이지마다 할당량을 쓰므로 `max_pages` 페이지(기본 10) 후에 멈춥니다.

```ruby
results = client.articles.search_all(query: "ticker:AAPL", limit: 100, max_pages: 5)
results.each { |article| puts article.title } # or: results.pages.each { |page| ... }
puts "continue with cursor #{results.next_cursor}" if results.truncated?
```

결과는 한 번만 순회할 수 있습니다. 두 번째 순회는 `Finlight::ValidationError`를 발생시킵니다. `cursor:`로 멈춘 곳부터 이어갈 수 있습니다.
알 수 없는 키워드와 잘못된 형태(`limit: 0`, `languages: []`, 4개 이상의 `include` 값)는 전송 전에
`Finlight::ValidationError`(`ArgumentError`이기도 함)를 발생시킵니다. `Time`은 밀리초가 있는 UTC ISO 8601,
`Date`는 `YYYY-MM-DD`, 문자열은 그대로 전송됩니다.

`source_types`와 `exclude_source_types`는 소스 유형으로 거릅니다(`Finlight::SourceType::ALL`, 예:
`Finlight::SourceType::NEWSWIRE`). 분류되지 않은 소스의 기사는 `source_types`에 일치하지 않고,
`exclude_source_types`에서는 남습니다. 둘 다 이미 받을 수 있는 소스를 좁히기만 합니다.
`client.stream`과 `client.raw_stream`에서도 쓸 수 있습니다.

## 기사, 기업, 소스 조회

```ruby
article = client.articles.get("EU8JwpsZ8iJehuyPZjMqRz", include: ["content"])
article = client.articles.get_by_link("https://www.reuters.com/...")

companies = client.companies.search("NVDA", mic: "XNAS") # at most 10, no pages
companies = client.companies.get_many([4821, 1001])
company = client.companies.get(4821)
etag = company.cache_info.etag                           # keep it with the record if you cache it
company = client.companies.get(4821, if_none_match: etag) # nil on 304 ("not modified")

sources = client.sources.list
```

- 찾지 못하면 `Finlight::NotFoundError`가 발생하며, 빈 결과가 되지 않습니다. 기사 ID 도입 전에 수집된 기사는 ID로 조회하면 404이므로 링크로 조회하세요.
- `companies.*`에는 `entityAccess` 권한이 필요합니다(없으면 `Finlight::ForbiddenError`).
- 기업·소스 조회도 기사 요청처럼 크레딧을 씁니다. 요청 1건당 1크레딧입니다(`get_many`는 ID별이 아니라 요청당 1). 304와 오류도 1크레딧입니다. 여기서도 429가 올 수 있습니다.
- SDK는 기업 레코드를 캐시하지 않습니다. `companies.get`은 매번 요청을 보냅니다. `company.cache_info`에 응답의 `etag`와 `cache_control`이 있습니다.
  크레딧을 아끼려면 레코드를 직접 보관하고 `max-age` 동안 다시 호출하지 마세요. ETag를 다시 넘길 수도 있습니다.
  `companies.get(id, if_none_match: etag)`는 `If-None-Match`를 보내고 304에서 `nil`("변경 없음")을 반환합니다. 304도 1크레딧이므로 아끼는 것은 다운로드이지 크레딧이 아닙니다.
  `if_none_match`가 없으면 `If-None-Match`를 보내지 않습니다. 주요 기업 필드는 기사 페이로드에 이미 들어 있습니다.
- `CompanyList`와 `SourceList`는 Enumerable입니다. 읽을 수 없는 항목은 제외되고 경고로 기록되며 `skipped`
  (인덱스, 원본 JSON, 이유)에 남습니다. `search`의 페이지에도 `skipped`가 있습니다.

## 없음, null, 빈 값

일부 키는 요금제와 `include`에 따라 달라집니다. 상태는 세 가지입니다: 없음(요청하지 않음, 권한 없음, raw 기사), `null`(값 없음), 값 있음.

```ruby
article.content_present?    # was "content" sent? (null counts as sent)
article.content             # nil when absent or null
article.sentiment_present?  # the same for "sentiment"
article.companies_present?  # companies is nil when absent; [] means "tagged, nothing found"
article.events_present?     # the same for events
article.raw_json            # the JSON as received, unknown keys included
```

- `companies: []`는 기사가 태깅되었지만 기업이 없다는 뜻입니다. `nil`은 블록 자체를 받지 못했다는 뜻입니다. 없음을 "기업 없음"으로 읽지 마세요.
- `events[].company_ids`는 같은 응답에 `companies`가 있을 때만 전송되며, 아니면 `nil`입니다.
- 타임스탬프는 전송된 문자열 그대로입니다(`published_at`). `published_at_time`, `first_seen_at_time`, `revised_at_time`,
  `available_at_time`은 RFC 3339로 엄격하게 파싱하며 읽을 수 없으면 `nil`을 반환합니다.
- 새 서버의 알 수 없는 키는 무시됩니다. `raw_json`과 `to_wire`로 JSON을 다시 얻을 수 있습니다.
- 모델은 불변 `Data` 객체입니다. 어휘 값은 문자열이며 Symbol이 아닙니다. 상수(`Finlight::EventType::MNA`,
  `Finlight::CompanyRole::ACQUIRER`)와 비교하세요. `ALL`은 알려진 값 목록입니다. 알 수 없는 값은 그대로 유지됩니다.

## 실시간 스트림

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

- `each`는 블로킹합니다. `break`로 빠져나오거나 다른 스레드에서 `stream.close`를 호출하면 소켓이 1000으로 닫히고 모든 백그라운드 스레드가 끝납니다. 스트림은 한 번만 순회할 수 있습니다.
- `event.kind`는 `created`, `updated`, `other` 중 하나입니다. `event.raw_json`은 프레임 전체입니다.
- `client.raw_stream(query:, sources:, exclude_sources:, source_types:, exclude_source_types:, language:, include_updates:)`는 가공 전의 기사를 전달합니다.
  `include`를 받지 않으며 본문, 감성, 기업, 이벤트가 없습니다.
- 스트림은 25초마다 ping을 보내고, 60초 동안 pong이 없으면 다시 연결하며, 115분 후 새 연결을 엽니다. 재연결할 때마다 같은 구독을 보내고 중복을 버립니다.
- 누락분을 자동으로 채우지 않습니다. `on_reconnect`는 마지막으로 본 `availableAt`(raw는 `firstSeenAt`)을 전달합니다.
  `client.articles.search_all(from: info.last_seen_at, order_by: "availableAt")`로 빈틈을 채우세요.
- 훅은 순회하는 스레드에서 요소 사이에 실행됩니다. 훅의 오류는 기록되며 스트림을 멈추지 않습니다.
- 종료되는 문제는 `each`에서 예외로 발생합니다: 잘못된 키(`UnauthorizedError`), WebSocket이 없는 요금제(`ForbiddenError`),
  거부된 구독(`ValidationFailedError`), 다른 연결이 인계받은 경우 이유가 `connection_limit`인 `PreemptedError`, 종료 코드 1008.
  그 밖의 문제는 다시 연결하고 `on_error`로 전달됩니다.
- 월간 WebSocket 할당량을 다 쓰면(연결이 거부되거나 이유가 `quota_exceeded`인 `connection.preempted`) 스트림은 끝나지 않고,
  할당량이 돌아올 때까지 1시간마다 다시 시도합니다. 대기할 때마다 경고를 기록하고 `on_quota_wait`(`on_error`가 아님)로 전달합니다.
  `quota_reconnect: false`로 설정하면 오류로 스트림을 끝냅니다. `quota_reconnect_interval`로 간격을 바꿀 수 있습니다.

알아 둘 제한:

- 요금제의 연결 수 제한은 enriched, raw, 이전 SDK 연결이 함께 씁니다. 제한에 도달하면 새 연결이 거부되고 SDK는 60초 후 다시 시도합니다.
  `stream`에 `takeover: true`를 넘기면 가장 오래된 연결을 대체합니다.
- 연결은 최대 2시간 유지되며, SDK는 115분 후 연결을 교체합니다. 요금제가 연결 한도에 도달해 있으면(예: 한도 1) 이전 연결이 아직 계산되어 새 연결이 거부됩니다. 이때 SDK는 이전 연결을 닫고 바로 다시 연결하므로 끊김은 연결 한 번 정도입니다. 그 연결마저 거부될 때만 평소처럼 최소 60초를 기다립니다.
- 구독 직후 서버는 일치하는 최신 기사를 한 번 보내며, 재연결과 교체 때마다 다시 보냅니다. 오래된 기사일 수 있습니다. 이미 받았다면 중복 필터가 버립니다.
- 32,000바이트를 넘는 라이브 프레임은 서버가 알림 없이 버립니다. 긴 기사에 `include: ["content"]`를 쓰면 발생할 수 있습니다. `articles.get`으로 가져오세요.
- `connection.admitted`는 서버가 구독을 검사하기 전에 도착합니다. 구독이 수락되었다는 뜻이 아닙니다.

## Webhook

finlight는 모든 Webhook에 서명합니다. 무엇이든 파싱하기 전에 **원본** 요청 본문으로 검증하세요:

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

- `headers`에는 대소문자 무관 Hash, Rack env(`HTTP_X_WEBHOOK_SIGNATURE`), 이름/값 쌍을 넘길 수 있습니다.
  `construct_event_from_values(raw_body, signature, timestamp, secret)`는 두 헤더 값을 직접 받습니다. `verify_signature`는 검증만 합니다.
- 타임스탬프는 앞뒤 300초(`tolerance:`) 이내여야 합니다. `now:`로 시계를 바꿀 수 있습니다.
- 전달은 반복될 수 있습니다. `event_id`로 중복을 제거하세요. 대시보드 테스트 Webhook에서는 `result.test?`가 true입니다.
- 5초 안에 2xx로 응답하고 오래 걸리는 작업은 그 후에 하세요. 410으로 응답하지 마세요. Webhook이 즉시 비활성화됩니다. 2xx가 아닌 응답이 10번 연속되어도 비활성화됩니다.
- 서명은 올바르지만 `payloadVersion`이 3이 아닌 본문은 `Finlight::WrongPayloadVersion`을 반환합니다. 오류가 아닌 결과이며, 2xx로 응답하세요.

원본 본문 얻기:

| 프레임워크 | 원본 본문 |
|---|---|
| Rack | `env["rack.input"].read` |
| Rails | `request.raw_post` |
| Sinatra | `request.body.read` |
| Hanami | `request.body.read` |

`examples/webhook_endpoint.rb`는 완전한 Rack 앱입니다.

Webhook을 v3로 전환하기: 먼저 이 SDK를 배포하고, `WrongPayloadVersion`에 2xx로 응답하며 원본 JSON을 보관합니다.
그다음 대시보드에서 Webhook을 `payloadVersion` 3으로 바꾸고, 약 2시간 기다립니다. 전환 전에 대기열에 들어간 재전송은 이전 형식으로 도착하기 때문입니다.

## 오류와 재시도

모든 오류는 모듈 `Finlight::Error`를 포함하며(`rescue Finlight::Error`) `kind` 문자열을 가집니다.

| 오류 | Kind | 언제 |
|---|---|---|
| `Finlight::ApiError` | `api` | API가 오류로 응답함: `status`, `code`, `type`, `title`, `detail`, `request_id`, `errors`(`FieldIssue`), `api_kind`, `raw`(본문 텍스트), `raw_json`. |
| `ValidationFailedError`, `CursorInvalidError`, `CursorMismatchError`, `UnauthorizedError`, `ForbiddenError`, `NotFoundError`, `RateLimitedError`, `InternalServerError` | `api` | 문제 코드마다 하나의 하위 클래스. 알 수 없는 코드는 일반 `ApiError`(`api_kind`는 `other`). |
| `Finlight::RateLimitedError` | `api` | `limit_type`은 `monthly`, `burst` 또는 더 새로운 값. `retry_after`는 초 단위. |
| `Finlight::ValidationError` | `validation` | 전송 전에 로컬에서 거부됨. `ArgumentError`이기도 함. `param`이 키 이름. |
| `Finlight::NetworkError`, `Finlight::TimeoutError` | `network`, `timeout` | 네트워크 장애 또는 시간 초과. 원래 오류는 `cause`. |
| `Finlight::DecodeError` | `decode` | 단일 응답을 읽을 수 없음(`path`, `raw`). |
| `Finlight::WebhookVerificationError` | `webhook_verification` | Webhook 검증 실패(`reason`). |
| `Finlight::PreemptedError` | `preempted` | 다른 연결이 스트림을 인계받음(`reason`, `new_lease_id`). `quota_reconnect: false`이면 할당량 소진 시에도. |

재시도: 5xx, 네트워크 오류, 시간 초과는 대기 시간을 늘려 가며 최대 3번 재시도하며 검색도 마찬가지입니다. 400, 401, 403, 404와 월간 429는 재시도하지 않습니다.
REST 호출은 새 할당량 기간을 기다리지 않습니다. 월간 429는 즉시 실패하며 `search_all` 안에서도 같습니다. 할당량을 기다리는 것은 스트림뿐입니다.
버스트 429는 정확히 `Retry-After`초(헤더가 없으면 10초) 기다린 뒤 한 번 더 시도하며, 이는 `max_retries`에 포함되지 않습니다.
`retry_on_burst: "off"`로 끌 수 있습니다. 호출마다 고유한 `X-Request-Id`를 보내며 재시도 때도 같습니다. 오류 객체는 이를 `request_id`로 가집니다.

호출을 취소하려면 해당 스레드를 멈추거나(`Thread#raise`, `Thread#kill`) `Timeout.timeout`으로 감싸세요. 대기는 즉시 끝나고 재시도하지 않습니다.
`total_timeout:`은 재시도와 버스트 대기를 포함한 호출 전체의 상한입니다.

## 설정

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

모든 시간은 초(Float)입니다. `Finlight::Config`를 만들어 `config:`로 넘길 수도 있습니다.

| 키 | 기본값 |
|---|---|
| `api_key` | 필수, 비어 있으면 안 됨 |
| `base_url` | `https://api.finlight.me` |
| `wss_url` | `wss://wss.finlight.me` (raw: `/raw`) |
| `timeout` | 시도당 30초 |
| `total_timeout` | 없음 |
| `max_retries` | 3 |
| `retry_base_delay`, `retry_max_delay` | 0.5초, 8초 |
| `retry_on_burst` | `"once"` (또는 `"off"`) |
| `burst_wait` | 10초, `Retry-After`가 없을 때만 |
| `max_pages` | 10 |
| `max_response_bytes` | 32 MiB |
| `ping_interval`, `watchdog_timeout`, `rotation_interval` | 25초, 60초, 115분 |
| `reconnect_base_delay`, `reconnect_max_delay` | 1초, 30초 |
| `long_backoff` | 60초 |
| `quota_reconnect`, `quota_reconnect_interval` | 켬, 1시간 |
| `search_failed_threshold` | 5 |
| `dedupe_cache_size` | 1000 |
| `max_message_bytes` | 32 MiB |
| `connect_timeout` | 30초 (WebSocket 연결과 핸드셰이크) |
| `logger` | 출력 없음 |
| `clock` | 시스템 시계 (`monotonic`과 `sleep`이 있는 모든 객체) |
| `http_client` | `Net::HTTP` |
| `ws_connect` | 내장 websocket-driver 전송 |

자체 HTTP 클라이언트: `http_client:`에는 `call(method, url, headers, body)`가 있고 `[status, headers, body]`를 반환하는
객체를 넘길 수 있습니다. 이때는 `timeout:`이 아니라 그 클라이언트의 시간 제한이 적용됩니다. 재시도를 추가하지 마세요.
시도마다 할당량을 씁니다. 자체 WebSocket 전송: `ws_connect:`에는 `(url, headers)`를 받아 `send_text`, `receive`,
`close(code)`가 있는 연결을 반환하는 callable을 넘깁니다(`Finlight::Transport` 참고). 헤더 이름은 주어진 그대로 보내세요.
게이트웨이는 소문자 `x-api-key`가 필요합니다. SDK는 자신이 만들지 않은 클라이언트를 닫지 않습니다. 내장 전송은 환경 변수의 프록시 설정을 읽지 않습니다.

모든 REST 요청과 WebSocket 연결은 `User-Agent: finlight-client-ruby/1.0.0`과 `x-client-version: 1.0.0`을 보냅니다.

## 로깅

SDK는 `logger:`로 넘긴 표준 `Logger`에 progname `finlight`로 기록합니다. 지정하지 않으면 아무것도 출력하지 않습니다.
stdout이나 stderr에 직접 쓰지 않고, 전역 로그 설정을 바꾸지 않으며, 시그널 핸들러를 설치하지 않습니다. 메시지마다 info로 기록하지도 않습니다.
API 키, Webhook 시크릿, 서명, 전체 본문은 로그, 오류 메시지, `inspect` 출력에 나타나지 않습니다.

## 데이터 참고

- 오래된 기사의 `published_at`이 `"1970-01-01T00:00:00.000Z"`일 수 있습니다. 그대로 전달됩니다.
- 빈 텍스트는 `nil`(`summary`, `content`)이며 `""`가 아닙니다.
- 역할 도입 전에 태깅된 기사는 `role`과 `relevance`가 `nil`, `events`가 `[]`입니다.
- ID 도입 전에 수집된 기사는 `articles.get(id)`가 404를 반환합니다. `get_by_link`를 쓰세요.
- `available_at`은 오래된 기사에서는 `nil`이고, raw 스트림과 raw Webhook에서는 항상 `nil`입니다.
- `source.type`과 `Source#type`은 소스가 분류되지 않았으면 `nil`입니다. 소스 유형이 생기기 전에 색인된
  기사도 `nil`입니다. 소스가 다시 분류되어도 오래된 기사는 이전 유형을 유지합니다.

## 0.x에서 이전하기

전체 안내는 [docs.finlight.me](https://docs.finlight.me/migration/v2-to-v3)에 있습니다. 요약:

| 0.x | 1.x |
|---|---|
| `require "finlight/client"` | `require "finlight"` |
| `Finlight::Client::VERSION` | `Finlight::VERSION` |
| `client.articles.fetch_articles(query:, page_size:, page:)` | `client.articles.search(query:, limit:)`, `client.articles.search_all(...)` |
| `page` / `page_size` | `limit` / `cursor` |
| `client.articles.fetch_article_by_link(link:)` | `client.articles.get_by_link(link)`, `client.articles.get(id)` |
| `include_content`, `include_entities`, `extended` | `include: ["content", "companies", "events"]` |
| `order: "DESC"` | `order: "desc"` |
| `publish_date`, `created_at`, `revised_date` | `published_at`, `first_seen_at`, `revised_at` (문자열, `*_time`으로 파싱) |
| `images` | `media.map(&:url)` |
| `source` (문자열) | `source.domain` |
| `sentiment`, `confidence` | `sentiment.label`, `sentiment.confidence` |
| `client.sources.get_sources` | `client.sources.list` |
| `client.websocket.connect(**params) { \|article\| }` | `client.stream(**params).each { \|event\| event.data }` |
| `client.raw_websocket` | `client.raw_stream(...)` |
| `Finlight::BlockedError` | `each`에서 발생하는 `Finlight::ApiError` |
| `Finlight::WebhookService.construct_event(...)` | `Finlight::Webhooks.construct_event(raw_body, headers, secret)` |
| Webhook `isUpdate` | `event.event == "article.updated"`, `event.changed_fields` |
| Webhook 본문 | `event.data`, 중복 제거용 `event.event_id` |
| (신규) | `client.companies.search`, `get_many`, `get` |

같은 키로 0.x와 1.x 스트림을 동시에 실행하지 마세요. 연결 수 제한을 함께 씁니다.

Webhook 전환 4단계:

1. 이 SDK를 배포합니다.
2. `Finlight::WrongPayloadVersion`에 2xx로 응답하고 `result.raw`를 보관합니다.
3. 대시보드에서 Webhook을 `payloadVersion` 3으로 전환합니다.
4. 약 2시간 기다립니다. 전환 전에 대기열에 들어간 재전송은 이전 형식으로 도착합니다.

## 개발

```bash
bundle install
bundle exec rake                 # kit check, every conformance case, unit tests, RuboCop, README, examples
bundle exec rake "conformance:sync[../path/to/shared/contracts/api-v3]"
ruby scripts/check_package.rb    # build the gem into an empty pkg/ and check its contents
```

`conformance/`는 API v3 계약 키트의 사본입니다(`CONTRACT_VERSION`, sha256이 있는 `MANIFEST`).
`CONFORMANCE.md`는 키트의 각 케이스를 테스트와 연결합니다. 단위 테스트와 적합성 테스트는 127.0.0.1만 쓰며 키가 필요 없습니다.
라이브 테스트는 dev에 대해서만, 명시적으로 요청할 때만 실행합니다:

```bash
FINLIGHT_LIVE=1 FINLIGHT_API_KEY=... FINLIGHT_BASE_URL=https://api.dev.finlight.me \
  FINLIGHT_WSS_URL=wss://wss.dev.finlight.me bundle exec rspec spec/live
```

## 라이선스

MIT
