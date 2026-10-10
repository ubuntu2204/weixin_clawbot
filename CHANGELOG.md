# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-10-10

### Added

- README 增加源码仓库地址与官方参考致谢（[Tencent/openclaw-weixin](https://github.com/Tencent/openclaw-weixin)）。
- 扫码绑定对齐官方 `waitForWeixinLogin` 状态机：
  - `need_verifycode`：手机微信显示配对数字时，UI 弹出输入框（`QrVerifyCodeRequiredEvent` +
    `QrLoginSession.submitVerifyCode`），以 `&verify_code=` 提交后继续登录；
  - `scaned_but_redirect`：IDC 重定向自动切换轮询域名（Web 端经代理 `/redirect/<host>`）；
  - `binded_redirect` / `verify_code_blocked`：明确的终止提示事件；
  - `get_bot_qrcode` 改为 POST + `local_token_list`（携带本机已存 bot token，可判定已绑定）。
- 接收图片：完整解析 `image_item`（`CdnMedia` 下载参数 + AES 密钥，`WeixinMessage.imageItem`）。
- `WeixinClawbot.downloadImage()` / `downloadMedia()`：从微信 CDN 下载并按
  AES-128-ECB + PKCS7 解密入站媒体，支持 `image_item.aeskey`（hex）与
  `media.aes_key`（base64）两种密钥形态，与官方 openclaw-weixin 接收逻辑一致。
- Flutter Web：CDN 请求经 `<proxyBaseUrl>/cdn` 转发，`proxy_server.dart` 已支持。
- example：消息气泡直接渲染入站图片（下载解密 → `Image.memory`）。

### Fixed

- Flutter Web 接收图片失败（"图片下载失败"）：服务端常直接下发 `media.full_url`，
  原实现会让浏览器直连 CDN（无 CORS 头，必被拦截）。现在 `full_url` 与自拼 URL
  一样经本地代理转发——代理新增 `/cdnfull/<host>/<path>` 路由
 （白名单 `weixin.qq.com` / `qq.com` 及子域）。
- `image_item.aeskey` 非法（奇数长度/非 hex/非 16 字节）时回退 `media.aes_key`
  或按明文下载，与官方 Node 侧宽松语义一致，不再让整次下载抛异常。
- example 图片气泡显示具体错误详情并支持点击重试；无下载参数时显示 `[图片]`
  占位而非发起注定失败的请求。

## [0.1.0] - 2026-05-08

### Added

- `WeixinClawbot` 门面类：统一管理账号、连接与消息收发。
- QR 扫码绑定流程（`startQrLogin`、`QrLoginWidget`、`showQrLoginDialog`）。
- HTTP 长轮询接收微信消息（`connect` → `Stream<WeixinMessage>`）。
- 发送文本消息（`sendText`），自动携带 `context_token`。
- `AccountStore`：使用 `shared_preferences` 跨重启持久化账号凭证。
- Flutter Web 支持：通过 `proxyBaseUrl` 绕过浏览器 CORS 限制，配套 `proxy_server.dart`。
- 完整示例应用（`example/`）演示绑定、接收、发送全流程。
