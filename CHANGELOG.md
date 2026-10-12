# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-10-12

### Added

- **换绑（re-bind / account hand-over）支持**：`QrLoginFlow` / `startQrLogin` /
  `startQrLoginSession` 新增 `allowRebind` 参数。开启后：
  - `get_bot_qrcode` 不携带 `local_token_list`，服务端为扫码微信创建**新 bot**，
    一次扫码即可把该微信换绑到新账号；
  - 若服务端仍返回 `binded_redirect` 并回传已有 bot 凭据，则直接以
    `QrConfirmedEvent` 收尾（接管既有绑定）；
  - 否则发一次 `QrAlreadyBoundEvent` 后自动获取新二维码供二次扫码（限一次）。
- `QrAlreadyBoundEvent` 携带 `existingWechatUserid`（响应中的
  `ilink_user_id`）与 `existingAccount`（响应回传凭据时非空），调用方可据此
  在自有用户体系中定位旧绑定做迁移或接管。

### Changed

- `QrLoginFlow` 内部 `confirmed` / `binded_redirect` 凭据组装统一为
  `_accountFromStatus`（行为不变）。

## [0.3.0] - 2026-10-10

### Changed

- **包改为纯 Dart 核心，单包声明双 SDK（Breaking）**：移除 `flutter` /
  `shared_preferences` / `qr_flutter` 依赖 —— Dart 服务器（如 REST 后端）可直接
  依赖本包调用 iLink Bot API（绑定、收发消息、CDN 媒体下载解密）。pubspec
  `environment` 保留 `flutter:` 声明，pub.dev 显示 Dart + Flutter 双 SDK 徽章，
  Flutter 项目照常依赖。
- **Flutter 登录 UI 移到 example**（Breaking）：`QrLoginWidget` /
  `showQrLoginDialog` 不再从 `package:weixin_clawbot` 导出，需要时复制
  `example/lib/qr_login_widget.dart`（依赖 `qr_flutter`）到你的应用，
  行为与 0.2.0 一致。
- **`AccountStore` 持久化后端可插拔**（`AccountStorage` 接口）：
  - 原生平台 / Dart 服务器：JSON 文件 `~/.weixin_clawbot/accounts.json`
    （可用 `AccountStore(storage: ...)` 注入自定义后端）；
  - Web：浏览器 localStorage，读写兼容 0.2.x `shared_preferences` 的
    `flutter.weixin_clawbot_accounts` 旧键；
  - 不再依赖 `shared_preferences`，纯 Dart 服务器开箱即用。
- SDK 下限提升到 Dart `>=3.4.0`（Web 存储后端需要 `package:web`）。

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
