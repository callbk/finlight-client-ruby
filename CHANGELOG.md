# Changelog

## 0.1.0

Initial release.

- REST API: search articles, fetch single articles by link, list sources
- Request retries with exponential backoff (429/5xx)
- Real-time streaming: enriched and raw article streams over WebSocket with
  auto-reconnect, keepalive with pong watchdog, proactive connection rotation
  and rate-limit handling
- Webhook support: HMAC-SHA256 signature verification with replay protection
