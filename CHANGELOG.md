# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- example：**发送图片给微信**（Web / 原生通用）。聊天页底部新增 🖼 图标，点击弹出
  选图对话框（`file_picker`，Web 走浏览器文件选择），确认后调用已有的
  `WeixinClawbot.sendImage`（对齐官方 `sendImageMessageWeixin`：`getuploadurl` →
  AES-128-ECB 上传微信 CDN → `sendmessage`）；成功后在本地乐观回显原图（服务端
  不会在长轮询里回显 bot 自己的媒体，与官方一致）。
- example：新增**可整文件复制**的 `lib/image_send_widget.dart`（`ImageSendWidget` /
  `showImageSendDialog`），与 `qr_login_widget.dart` 同样设作供其他程序复用的组件；
  上传协议细节全部留在 SDK，示例与 Widget 均不含任何重复的上传实现。
- example：**协议错误中文翻译**（`describeWeixinError`，`image_send_widget.dart`）——
  文本与图片发送共用。`sendmessage ret=-2 errmsg=prepare failed (rate limited,
  try again later)` 会被翻译成“该微信用户近期没先给 bot 发消息、会话未就绪，请
  让对方先发一条消息，或稍等 5–10 秒重试”；同时覆盖 -2 频率限制、-14 会话冷却、
  缺收件人、未连接、上传失败等情形；未知错误原样保留并展示原始信息供排查。

> 核心 SDK 无行为变更（出站媒体 `sendImage`/`sendVideo`/`sendFile` 自 0.5.0 起已存在）；
> 本次仅补齐 example 的发送图片入口与可复用 Widget，`file_picker` 仅为 example 依赖。

## [0.5.1] - 2026-10-13

### Added

- **多账号宿主换绑支持**（服务端托管多个应用账号的场景，官方单账号模型未覆盖）：
  - `WeixinClawbot.startQrLoginSession(omitLocalTokens: true)`（`startQrLogin` 同参）
    —— 给 `get_bot_qrcode` 发**空**的 `local_token_list`。本地缓存的 bot token 属于另一个
    应用账号时，把它交给服务端只会换来 `binded_redirect`（"这个 bot 已经连过"），
    扫码后拿不到新凭据，换绑永远无法完成；不发该列表时服务端为扫码微信签发新 bot，
    一次扫码即完成换绑。
  - `QrAlreadyConnectedEvent` 携带宿主自救所需信息：`localBotTokens`（本地已知 bot token，
    与是否发给服务端无关）、`localAccount`（命中的本地账号）、`rawStatus`、
    `resolvedFromLocalStore`。服务端未回传 `ilink_user_id` 时，`wechatUserId` 会由本地
    账号补全 —— 宿主可以据此在自己的绑定表里完成迁移，而不必再扫一次码。

## [0.5.0] - 2026-10-12

本版把 API 面**逐项对齐官方** [Tencent/openclaw-weixin](https://github.com/Tencent/openclaw-weixin)
（依据 `docs/protocol.md`、`src/api/api.ts`、`src/api/types.ts`、`src/auth/login-qr.ts`、
`src/auth/accounts.ts`、`src/cdn/upload.ts`、`src/api/session-guard.ts`）。包含大量破坏性改动。

### Added

- **补齐官方端点**（此前完全缺失）：
  - `POST /ilink/bot/getconfig` → `ILinkClient.getConfig`（取 `typing_ticket`）
  - `POST /ilink/bot/sendtyping` → `ILinkClient.sendTyping` + `MessagePoller.showTyping/cancelTyping`
    + `WeixinClawbot.showTyping/cancelTyping/setTyping`
  - `POST /ilink/bot/msg/notifystart` / `notifystop` → `ILinkClient.notifyStart/notifyStop`
  - `POST /ilink/bot/getuploadurl` → `ILinkClient.getUploadUrl`
- **出站媒体上传**：`CdnMediaUploader` 复刻官方上传管线（明文 MD5 + `aesEcbPaddedSize`、
  16 字节随机 key 与 `filekey`（hex）、`no_need_thumb: true`、AES-128-ECB + PKCS#7 密文
  POST `application/octet-stream`、读取 `x-encrypted-param`、4xx 立即中止 / 其他失败共 3 次尝试），
  并新增 `WeixinClawbot.sendImage / sendVideo / sendFile`（字幕按官方做法作为独立请求发送）。
  `buildCdnUploadUrl` / `buildCdnDownloadUrl` 与官方 `cdn-url.ts` 一致。
- **解绑 `WeixinClawbot.unbind()`**：协议**没有**服务端解绑接口，官方解绑 =
  `stopAccount`（`notifyStop`）+ `clearWeixinAccount`（清本机凭据）。`unbind()` 完全照此实现：
  停止轮询 → 发送 `notifyStop` → 删除本机 `bot_token`/`context_token` → 解除 -14 冷却；
  返回被移除的账号 ID。`logout()` 保留为 `@Deprecated` 别名。
- **换绑（官方语义）**：`AccountStore.removeStaleForWechatUser()` 对应官方
  `clearStaleAccountsForUserId` —— 扫码 confirmed 后自动删除同一微信用户的旧账号；
  `AccountStore.botTokenList()` 对应 `getLocalBotTokenList()`（最新优先、上限 10 个），
  `AccountStore.clearContextToken()` 对应 `clearContextTokensForAccount`；
  `ClawBotAccount.savedAtMs` 对应官方 `savedAt`。
- **`base_info.bot_agent`**：所有已鉴权请求都携带（官方 `buildBaseInfo()` 总是给出两个字段），
  `sanitizeBotAgent()` 完整移植官方 UA 语法校验（`Name/Version` + 可选 `(comment)`、仅 ASCII、
  超 256 字节按 token 截断、非法回落 `OpenClaw`）；门面新增 `botAgent` 参数。
- **`SKRouteTag`** 请求头支持（`skRouteTag` 参数），与官方可选部署路由标签一致。
- **会话冷却 `SessionGuard`**：`errcode/ret == -14` 时按官方 `session-guard` 冷却**一小时**，
  轮询循环带 `SessionPausedException` 停止而不是用失效 token 继续重试；
  暴露 `WeixinClawbot.isSessionPaused / sessionPauseRemaining`。
- **完整官方类型面**：`MessageItem` 增加 `createTimeMs/updateTimeMs/isCompleted/msgId/refMsg`
  与 `voice/file/video/toolCallStart/toolCallResult` 载荷；新增 item 类型 11/12、
  `RefMessageData`/`PartialTextData`、`VoiceItemData`/`FileItemData`/`VideoItemData`、
  `thumb_media`、`url/hd_size` 等字段；`WeixinMessage` 增加 `updateTimeMs/deleteTimeMs/
  sessionId/groupId/runId`；新增 `MessageType`/`MessageState`/`UploadMediaType`/`TypingStatus`
  官方常量枚举，以及 `GetConfigResponse`/`NotifyResponse`/`GetUploadUrlRequest·Response`/
  `SendMessageResponse`。入站语音/文件/视频新增 `downloadVoice/downloadFile/downloadVideo`。
- example：**换绑与解绑入口**（带协议依据说明的确认对话框）、多账号切换菜单、
  已连接（`binded_redirect`）提示、二维码自动刷新进度、-14 冷却横幅、打字状态演示。

### Changed

- **`message_id` / `msg_id` / `svr_id` 由 `int` 改为 `String`（Breaking）**：官方用
  `parseWeixinApiJson` 把 uint64 预加引号无损解析；原实现在 Flutter Web（JS double 仅 53 位）
  会丢精度。新增同名移植 `parseWeixinApiJson` / `quoteLosslessIdFields`。
- **`binded_redirect` 改为终止且成功的事件 `QrAlreadyConnectedEvent`（Breaking）**：替换 0.4.0
  自创的 `QrAlreadyBoundEvent` + “接管服务端回传凭据”逻辑——官方从不读取该响应里的
  `bot_token`，只当作“已连接过此 OpenClaw”。
- **移除 `allowRebind`（Breaking）**：0.4.0 的“省略 `local_token_list` 以换取新 bot”并非官方行为；
  现在始终携带最新 10 个本机 token，换绑改由官方 `clearStaleAccountsForUserId` 语义完成。
- **`expired` / `verify_code_blocked` 变为非终止事件（Breaking）**：与官方 CLI 一致自动刷新二维码，
  预算为 `MAX_QR_REFRESH_COUNT = 3` 个码；新增 `QrRefreshedEvent`、`QrTooManyQrResetsEvent`、
  `QrLoginTimeoutEvent`，`QrReadyEvent` 附带 `generation`；`scaned` 每个码只播报一次。
- **QR 请求总是瞄准固定 API 主机**（官方 `FIXED_BASE_URL`），只有状态轮询跟随 IDC 重定向切主机；
  轮询超时改为官方 35s；任何轮询网络/网关错误视为 `wait` 继续重试，不再连续 3 次即失败。
- **`sendmessage` 的 `from_user_id` 固定为空字符串**（官方 sender 均如此，由服务端归属 bot）；
  `sendText/sendItems` 不再接受 `botId`。`client_id` 改为 `<prefix>-<uuid>`（官方 `generateId`）。
- **`ILinkClient.sendMessage` 在 `ret != 0` 时抛 `ILinkApiException`**（与官方一致）；
  `sendText/sendItems/sendItemsSequentially` 仍捕获为 `SendResult`（不抛异常）。
- **`getupdates` 超时返回 `ret:0` 空结果并保留游标**（官方行为）；客户端超时 slack 对小超时等比例缩放。
- 不再手写 `Content-Length`（官方交由 fetch，`package:http` 自行设置）；各端点采用官方分级超时
  （15s / 10s / 35s）。
- `WeixinClawbot.dispose()` 改为 `Future<void>`，会先对所有已连接账号发 `notifyStop`；
  `disconnect()` 也默认发 `notifyStop`（可用 `notify: false` 关闭）。
- example 代理：放行并透传 `SKRouteTag`，新增 `Access-Control-Expose-Headers` 与上游
  `x-encrypted-param` / `x-error-message` 透传（否则 Web 端无法完成媒体上传）。

### Fixed

- `sendmessage` 请求体正确包裹 `msg` 字段（对齐官方 `SendMessageReq`；本次重构中曾经遗漏，
  由新增的协议测试发现并修正）。

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
