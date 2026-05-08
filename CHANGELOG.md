# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-05-08

### Added

- `WeixinClawbot` 门面类：统一管理账号、连接与消息收发。
- QR 扫码绑定流程（`startQrLogin`、`QrLoginWidget`、`showQrLoginDialog`）。
- HTTP 长轮询接收微信消息（`connect` → `Stream<WeixinMessage>`）。
- 发送文本消息（`sendText`），自动携带 `context_token`。
- `AccountStore`：使用 `shared_preferences` 跨重启持久化账号凭证。
- Flutter Web 支持：通过 `proxyBaseUrl` 绕过浏览器 CORS 限制，配套 `proxy_server.dart`。
- 完整示例应用（`example/`）演示绑定、接收、发送全流程。
