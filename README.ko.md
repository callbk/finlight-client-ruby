# finlight-client (Ruby)

*[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | 한국어*

[![Gem Version](https://img.shields.io/gem/v/finlight-client)](https://rubygems.org/gems/finlight-client)
[![CI](https://github.com/callbk/finlight-client-ruby/actions/workflows/test.yml/badge.svg)](https://github.com/callbk/finlight-client-ruby/actions/workflows/test.yml)

[finlight.me](https://finlight.me) API의 공식 Ruby 클라이언트입니다. 감성 분석, 엔티티 인식, 실시간 스트리밍을 갖춘 금융 뉴스를 제공합니다.

📚 **전체 API 문서: [docs.finlight.me](https://docs.finlight.me)**

## 주요 기능

- **REST API**: 기사 검색, 링크로 단일 기사 조회, 뉴스 소스 목록 조회
- **실시간 스트리밍**: WebSocket을 통한 enhanced 및 raw 기사 스트림
- **기본적으로 견고함**: 지수 백오프를 적용한 요청 재시도, WebSocket 자동 재연결, pong 워치독 기반 킵얼라이브, 선제적 연결 교체, 속도 제한 처리
- **Webhook 지원**: HMAC-SHA256 서명 검증 및 재생 공격 방지
- **최소한의 의존성**: 표준 라이브러리 `Net::HTTP`와 `OpenSSL`, 그리고 순수 Ruby로 구현된 `websocket-driver`

Ruby 3.2 이상이 필요합니다.

## 설치

```ruby
# Gemfile
gem "finlight-client"
```

또는 직접 설치:

```bash
gem install finlight-client
```

## 빠른 시작

```ruby
require "finlight/client"

client = Finlight::Client.new(api_key: ENV["FINLIGHT_API_KEY"])

response = client.articles.fetch_articles(query: "nvidia", page_size: 10)
response.articles.each { |article| puts "[#{article.source}] #{article.title}" }
```

## REST API

### 기사 검색

`query`의 전체 문법은 [쿼리 언어 레퍼런스](https://docs.finlight.me)를 참조하세요. 파라미터는 snake_case 키워드이며, API의 camelCase 필드와 1:1로 대응합니다.

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

### 링크로 단일 기사 조회

```ruby
article = client.articles.fetch_article_by_link(
  link: "https://www.reuters.com/technology/example",
  include_content: true
)
```

### 뉴스 소스 목록 조회

```ruby
sources = client.sources.get_sources
defaults = sources.select(&:is_default_source)
```

## 실시간 스트리밍

`connect`는 블로킹되며 `stop`을 호출할 때까지 자동으로 재연결합니다. 백그라운드 스레드에서 실행하려면 `connect_async`를 사용하세요. enhanced 스트림은 감성과 엔티티가 포함된 기사를, raw 스트림(`client.raw_websocket`)은 최소 지연으로 보강되지 않은 기사를 전달합니다.

```ruby
websocket = client.websocket
websocket.connect(tickers: %w[AAPL NVDA], extended: true) do |article|
  puts article.title
end
```

스트림 옵션 사용자 지정:

```ruby
websocket = client.websocket(
  takeover: true, # 동일한 키의 기존 연결을 테이크오버
  on_close: ->(code, reason) { puts "closed: #{code} #{reason}" }
)
thread = websocket.connect_async(query: "bitcoin") { |article| puts article.title }
# ...
websocket.stop
thread.join
```

서버가 연결을 영구적으로 거부하면(클로즈 코드 1008) `connect`는 `Finlight::BlockedError`를 발생시킵니다. 재연결해도 해결되지 않으므로 지원팀에 문의하세요.

## Webhook

원본(파싱되지 않은) 요청 본문으로 수신한 Webhook을 검증합니다:

```ruby
# 예: Rails controller에서
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

## 설정

| 옵션           | 기본값                    | 설명                                            |
| -------------- | ------------------------- | ----------------------------------------------- |
| `base_url:`    | `https://api.finlight.me` | REST 엔드포인트                                 |
| `wss_url:`     | `wss://wss.finlight.me`   | WebSocket 엔드포인트                            |
| `timeout:`     | 5                         | 요청당 및 연결 타임아웃(초)                     |
| `retry_count:` | 3                         | 재시도 대상 실패(429/5xx)에 대한 총 시도 횟수   |
| `logger:`      | stderr, WARN              | 표준 라이브러리와 호환되는 임의의 `Logger`      |

```ruby
client = Finlight::Client.new(
  api_key: api_key,
  timeout: 10,
  retry_count: 5,
  logger: Logger.new($stdout, level: Logger::INFO)
)
```

## 개발

```bash
bundle install
bundle exec rake        # 테스트 스위트 실행
```

### 실제 API 대상 검증

`local/` 디렉터리는 gitignore되어 있으며, 다른 언어의 클라이언트와 마찬가지로 스모크 실행 스크립트를 담고 있습니다. 자격 증명은 환경 변수에 두고 코드에는 절대 넣지 마세요.

```bash
# 일회성 스모크: REST 엔드포인트 + 30초 기사 스트림
FINLIGHT_API_KEY=sk_... bundle exec ruby local/smoke.rb

# REST 통합 테스트(키가 설정되지 않으면 자동 건너뜀)
FINLIGHT_API_KEY=sk_... bundle exec rspec spec/integration
```

선택 사항: dev 환경을 대상으로 하려면 `FINLIGHT_BASE_URL` / `FINLIGHT_WSS_URL`을 지정하세요.

## 라이선스

[MIT](LICENSE)

## 관련 링크

- 한국어 제품 페이지: https://finlight.me/ko/news-api
