# weixin_clawbot

[![pub.dev](https://img.shields.io/pub/v/weixin_clawbot)](https://pub.dev/packages/weixin_clawbot)
[![source](https://img.shields.io/badge/source-github-blue)](https://github.com/ubuntu2204/weixin_clawbot)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)

一个 **单包双 SDK**（Dart + Flutter）package，通过微信扫码绑定 ClawBot（基于 OpenClaw iLink Bot API），并在应用中接收/发送微信消息。

- **Dart 服务器 / CLI**：直接依赖，无需 Flutter SDK —— 适合后端自动收发消息、下载入站图片。
- **Flutter 移动端 / 桌面端 / Web**：同一依赖；开箱即用的扫码绑定 Widget 见 `example/lib/qr_login_widget.dart`，发送图片 Widget 见 `example/lib/image_send_widget.dart`，均可整文件复制到你的应用。

> **源码仓库**：https://github.com/ubuntu2204/weixin_clawbot
> 协议实现参考腾讯官方插件 [Tencent/openclaw-weixin](https://github.com/Tencent/openclaw-weixin)（详见文末"参考与致谢"）。
> 灵感来源：[@claw-lab/wxclawbot-cli](https://github.com/lroolle/wxclawbot-cli) 和 [openclaw-weixin-cli](https://github.com/pzx521521/openclaw-weixin-cli)。

---

## 功能

| 功能 | 描述 |
|------|------|
| 🔗 微信扫码绑定 | 获取 QR 码 → 微信扫描 → 自动保存凭证（配对数字、IDC 重定向、二维码自动刷新≤3次） |
| 🔄 换绑（官方语义） | 同一微信用户扫描另一个 bot，confirmed 后自动删除该用户的旧账号（对齐官方 `clearStaleAccountsForUserId`） |
| ⛔ 解绑 | `unbind()`：`notifyStop` + 清除本机凭证（协议无服务端解绑接口，官方同样只清本机） |
| 📥 接收消息 | HTTP 长轮询 (`getupdates`)，消息以 `Stream<WeixinMessage>` 形式推送 |
| 📤 发送消息 | 发送文本，自动携带 `context_token`；`from_user_id` 留空（与官方一致） |
| 🖼 发送图片/文件/视频 | `getuploadurl` + AES-128-ECB 上传微信 CDN（与官方上传管线一致） |
| ⌨️ 输入状态 | `getconfig` 取 `typing_ticket` + `sendtyping` 显示/取消“正在输入” |
| 🧭 生命周期通知 | `connect` → `notifystart`，`disconnect`/`unbind` → `notifystop` |
| 💾 凭证持久化 | 可插拔 `AccountStorage`：原生为 `~/.weixin_clawbot/accounts.json` 文件，Web 为 localStorage，可注入自定义后端 |
| 🖼 接收图片/媒体 | 从微信 CDN 下载并 AES-128-ECB 解密入站图片/语音/文件/视频（与官方一致） |
| 🧩 开箱即用 Widget | `QrLoginWidget` / `showQrLoginDialog`（见 `example/lib/qr_login_widget.dart`，可复制复用） |

> **协议对齐**：官方 `docs/protocol.md` 列出的 **9 个端点已全部实现**（`get_bot_qrcode`、
> `get_qrcode_status`、`getupdates`、`sendmessage`、`getconfig`、`sendtyping`、
> `msg/notifystart`、`msg/notifystop`、`getuploadurl`），并采用相同的请求头、
> `base_info`（含 `bot_agent`）、uint64 无损解析与 `-14` 会话冷却策略。

---

## 快速开始

### 1. 添加依赖

```yaml
dependencies:
  weixin_clawbot: ^0.5.1
```

### 2. 前置要求

使用此 package 前，需要先在 OpenClaw 中安装微信插件并完成一次命令行登录，以确认账号可用：

```bash
npx -y @tencent-weixin/openclaw-weixin-cli@latest install
```

> 插件会在 `https://ilinkai.weixin.qq.com` 上为你的机器人注册一个账号，本 package 通过该地址的 REST API 工作。

### 3. 扫码绑定

```dart
import 'package:weixin_clawbot/weixin_clawbot.dart';

final clawbot = WeixinClawbot();

// 纯 Dart / 任意平台：监听事件流驱动绑定流程
await for (final event in clawbot.startQrLogin()) {
  if (event is QrReadyEvent) {
    print('请用微信扫描：${event.qrContent}'); // 交给任意二维码渲染器展示
  }
  if (event is QrConfirmedEvent) {
    // account.defaultTo 即绑定时扫码的微信用户 ID，可直接作为 toUserId 使用
    clawbot.connect(event.account).listen((msg) {
      print('收到消息：${msg.textContent}');
    });
    break;
  }
}
```

Flutter 应用可以直接复制 example 的登录对话框 / Widget（内置配对数字输入框）：

```dart
// import 'qr_login_widget.dart'; // 复制 example/lib/qr_login_widget.dart 后
final account = await showQrLoginDialog(context: context, clawbot: clawbot);
if (account != null) {
  clawbot.connect(account).listen((msg) => print(msg.textContent));
}
```

### 4. 接收消息

```dart
// 从持久化存储中恢复已绑定账号（应用重启后自动重连）
final account = await clawbot.loadAccount();
if (account != null) {
  clawbot.connect(account).listen((WeixinMessage msg) {
    if (msg.isFromUser) {
      print('[${msg.fromUserId}]: ${msg.textContent}');
    }
  });
}
```

### 5. 接收图片

图片消息会完整解析 `image_item`（CDN 下载参数 + AES 密钥）。下载并解密一张图片：

```dart
clawbot.connect(account).listen((msg) {
  final image = msg.imageItem;
  if (image != null) {
    final bytes = await clawbot.downloadImage(image); // 已解密的原始图片字节
    // 例如：Image.memory(bytes)
  }
});
```

> 实现与官方 openclaw-weixin 插件一致：优先使用 `media.full_url`，否则请求
> `{cdn}/download?encrypted_query_param=...`（默认 CDN 为
> `https://novac2c.cdn.weixin.qq.com/c2c`），再按 AES-128-ECB + PKCS7 解密。
> `image_item.aeskey`（hex）与 `media.aes_key`（base64）两种密钥形态均支持。
> Flutter Web 上 CDN 请求走 `<proxyBaseUrl>/cdn` 前缀，配套代理服务器已支持。

### 6. 发送消息

```dart
// 发给绑定时确定的微信用户（account.defaultTo）
final result = await clawbot.sendText(
  text: '你好，来自 Flutter！',
  toUserId: account.defaultTo,  // 扫码绑定时自动写入
);

// 也可以在收到对方消息后，直接回复其 fromUserId
final result = await clawbot.sendText(
  text: '已收到你的消息',
  toUserId: incomingMsg.fromUserId,
);

if (!result.ok) {
  print('发送失败：${result.error}');
}
```

> **提示**：`context_token` 由轮询器在收到消息时自动缓存，发送时无需手动传递。
> 若尚未收到过对方消息（冷启动主动发送），需确保 `account.defaultTo` 不为空，否则会返回错误。

### 7. 换绑（re-bind）

**官方协议没有“换绑”接口。** 换绑的做法就是：用同一个微信号去**扫描另一个 ClawBot**。
扫码 `confirmed` 后，本包会自动删除本机保存的、属于同一微信用户的旧账号（对齐官方
`clearStaleAccountsForUserId`），避免新旧 bot 的 `context_token` 互相混淆：

```dart
// 先拿到新 bot 的二维码（可用另一个 OpenClaw 实例 / 另一个账号），扫一次即可
final account = await showQrLoginDialog(context: context, clawbot: clawbot);
// account 已持久化；同一微信用户的旧账号已被自动清理
final remaining = await clawbot.loadAllAccounts();

// 也可以手动维护：只保留 keepAccountId，清掉同微信用户的其它账号
await clawbot.store.removeStaleForWechatUser(
  keepAccountId: account.id,
  wechatUserId: account.defaultTo,
);
```

如果扫描的 bot **已经绑定在本机**，服务端返回 `binded_redirect`，本包发出
[`QrAlreadyConnectedEvent`](#qrlogevent-子类型)——与官方一致地当作**成功**（已连接过，
不重发凭据），而不是错误。

### 8. 解绑（un-bind）

协议**也没有服务端解绑接口**（已核对官方 `src/api/api.ts` 与 `docs/protocol.md`）。
官方解绑 = `stopAccount`（`notifyStop`）+ `clearWeixinAccount`（删本机文件），
`unbind()` 完全照此实现：

```dart
// 解绑指定账号：停轮询 → POST /ilink/bot/msg/notifystop → 删除 bot_token/context_token
final removed = await clawbot.unbind(accountId: account.id);

// 不传 accountId 则解绑全部
await clawbot.unbind();

// 仅停止轮询而**保留**凭据（也会发 notifyStop）
await clawbot.disconnect(account.id);
```

> 微信端的授权记录需在**手机端微信**里查看/管理，任何客户端 API 都无法 revoke 它。
> example 的“解绑”按钮会先弹出说明这一点的确认对话框。

### 9. 输入状态（typing）

```dart
// getconfig 取 typing_ticket（按用户缓存），再 sendtyping
await clawbot.showTyping(msg.fromUserId);   // status=1 “正在输入…”
await clawbot.sendText(text: '处理完成', toUserId: msg.fromUserId);
await clawbot.cancelTyping(msg.fromUserId); // status=2 取消
```

### 10. 发送图片 / 文件 / 视频

字节先经 AES-128-ECB + PKCS#7 加密上传到微信 CDN（`no_need_thumb: true`，
仅上传原件），再从响应头 `x-encrypted-param` 取回下载参数，最后发一条媒体消息；
`caption` 会按官方做法作为**独立**的一条文本消息先发出：

```dart
final bytes = await rootBundle.load('assets/photo.png'); // 任意来源的 Uint8List
final result = await clawbot.sendImage(
  bytes: bytes.buffer.asUint8List(),
  toUserId: account.defaultTo,
  caption: '这是今日截图',
);

await clawbot.sendFile(bytes: pdfBytes, fileName: 'report.pdf', toUserId: to);
await clawbot.sendVideo(bytes: mp4Bytes, toUserId: to);
```

> example 的 Flutter Web 聊天页底部 🖼 图标即演示此流程：选图（`file_picker`，Web 走
> 浏览器文件选择）→ `sendImage` 加密上传。整套 UI 封装在可复制的
> `example/lib/image_send_widget.dart`（`showImageSendDialog` / `ImageSendWidget`），
> 其他程序可直接复用——协议细节始终留在 SDK 内部，示例不含任何上传实现。

---

## 纯 Dart / 服务端使用

0.3.0 起核心包不再依赖 Flutter，Dart 服务器可直接调用（pub.dev 已声明 Dart 支持）：

```dart
import 'package:weixin_clawbot/weixin_clawbot.dart';

Future<void> main() async {
  final clawbot = WeixinClawbot();
  ClawBotAccount? account =
      await clawbot.loadAccount(); // ~/.weixin_clawbot/accounts.json
  if (account == null) {
    // 首次使用：打印 QR 内容，用任意二维码渲染（终端/网页）完成扫码
    await for (final event in clawbot.startQrLogin()) {
      if (event is QrReadyEvent) print('QR: ${event.qrContent}');
      if (event is QrConfirmedEvent) break;
    }
    account = await clawbot.loadAccount();
  }

  clawbot.connect(account!).listen((msg) async {
    if (!msg.isFromUser) return;
    // 收到图片：下载并解密
    final image = msg.imageItem;
    if (image != null && image.isDownloadable) {
      final bytes = await clawbot.downloadImage(image);
      // bytes = 已解密原始图片字节
    }
    // 回复文本
    await clawbot.sendText(text: '已收到', toUserId: msg.fromUserId);
  });
}
```

服务器场景建议为 `AccountStore` 注入自己的存储后端（如数据库），而不是默认文件：

```dart
class DbAccountStorage implements AccountStorage {
  @override
  Future<List<String>> read() async => /* 从 DB 读取 JSON 字符串列表 */;
  @override
  Future<void> write(List<String> entries) async => /* 写回 DB */;
}

final clawbot = WeixinClawbot(store: AccountStore(storage: DbAccountStorage()));
```

---

## Flutter Web（CORS 代理）

浏览器不允许直接访问跨域 API，需通过本地代理服务器转发：

```bash
# 在 example 目录下启动代理
dart run bin/proxy_server.dart
```

然后在构建/调试时传入代理地址：

```bash
flutter run -d chrome --dart-define=PROXY_URL=http://localhost:3001
```

代码中创建 `WeixinClawbot` 时设置 `proxyBaseUrl`：

```dart
final clawbot = WeixinClawbot(
  proxyBaseUrl: kIsWeb ? 'http://localhost:3001' : null,
);
```

---

## API 参考

### `WeixinClawbot`

主门面类，管理账号、连接与官方生命周期通知。

| 方法 | 对应官方行为 | 说明 |
|------|--------------|------|
| `loadAccount()` | — | 返回第一个持久化账号，无则 `null` |
| `loadAllAccounts()` | `listWeixinAccountIds` | 返回所有持久化账号（支持多账号） |
| `startQrLogin(...)` / `startQrLoginSession(...)` | `auth.login` | QR 扫码绑定；confirmed 后自动持久化 + 换绑清理 |
| `connect(account)` | `gateway.startAccount` | 启动长轮询并发 `notifyStart`，返回 `Stream<WeixinMessage>` |
| `sendText({text, toUserId?, accountId?, runId?})` | `sendMessageWeixin` | 发送文本（`from_user_id` 留空） |
| `sendImage / sendVideo / sendFile` | `send*MessageWeixin` | 上传 CDN 后发送媒体，可选 `caption` |
| `showTyping / cancelTyping / setTyping` | `messaging/typing.ts` | 显示/取消“正在输入” |
| `downloadImage / downloadVoice / downloadFile / downloadVideo` | `media-download.ts` | 下载并解密入站媒体 |
| `disconnect(accountId, {notify: true})` | `gateway.stopAccount` | 停止轮询并发 `notifyStop`，**保留**凭据 |
| `unbind({accountId?})` | `clearWeixinAccount` + `notifyStop` | **解绑**：停轮询 → `notifyStop` → 删本机凭据与 context_token |
| `isSessionPaused(id)` / `sessionPauseRemaining(id)` | `session-guard.ts` | -14 冷却状态查询 |
| `logout({accountId?})` | — | 已废弃，请用 `unbind()` |
| `dispose()` | gateway shutdown | `Future<void>`：停所有轮询、逐个 `notifyStop`、释放连接池 |
| `store` / `sessionGuard` / `media` | — | 暴露账号存储、冷却守卫与下载器 |

构造参数：`proxyBaseUrl`（Web CORS 代理）、`cdnBaseUrl`、`botAgent`（`base_info.bot_agent`，
经官方语法清洗）、`skRouteTag`（`SKRouteTag` 头）、`channelVersion`、`store`、`httpClient`、
`sessionGuard`。

### `ClawBotAccount`

| 字段 | 官方对应 | 说明 |
|------|----------|------|
| `id` / `botId` | `ilink_bot_id` | 机器人在 iLink 平台的用户 ID |
| `token` | `token` | Bearer 鉴权令牌 |
| `baseUrl` | `baseUrl` | 服务器分配的 API 地址（可能与默认地址不同） |
| `defaultTo` | `userId` | 绑定时扫码的微信用户 ID（可直接用作 `toUserId`） |
| `contextToken` | `*.context-tokens.json` | 最近一条入站消息的 context token |
| `savedAtMs` | `savedAt` | 凭据写入时间，决定 `local_token_list` 的新旧顺序 |

### `QrLoginEvent` 子类型

| 类型 | 终止 | 说明 |
|------|------|------|
| `QrReadyEvent(qrContent, generation)` | 否 | QR 码就绪；刷新后会再次发出 |
| `QrScannedEvent` | 否 | 已扫码，等待手机端确认（每个码只一次） |
| `QrVerifyCodeRequiredEvent(isRetry)` | 否 | 手机显示配对数字，需 `submitVerifyCode` 提交 |
| `QrRefreshedEvent(attempt, maxAttempts)` | 否 | 正在刷新二维码…(n/3) |
| `QrExpiredEvent` | **否** | 二维码过期，流程会自动刷新（与官方 CLI 一致） |
| `QrVerifyCodeBlockedEvent` | **否** | 配对数字错太多，将自动刷新二维码 |
| `QrTooManyQrResetsEvent(reason)` | 是 | 刷新预算耗尽（3 个码），连接流程停止 |
| `QrLoginTimeoutEvent` | 是 | 整体超时（默认 8 分钟） |
| `QrAlreadyConnectedEvent(wechatUserId)` | 是（**成功**） | `binded_redirect`：已连接过此客户端，本机凭据仍可用 |
| `QrConfirmedEvent(account)` | 是 | 登录成功，账号已持久化，同微信用户旧账号已清理 |
| `QrErrorEvent(error, stackTrace)` | 是 | 网络或服务端错误 |

> 旧版本的 `QrAlreadyBoundEvent` 与 `allowRebind` 参数已移除：官方不会从
> `binded_redirect` 响应里读取凭据，也不会省略 `local_token_list`。

**配对数字（`need_verifycode`）**：部分账号扫码后微信会在手机上显示一组数字，
需要把它输入回应用（官方 CLI 是终端输入，Flutter 端由 `QrLoginWidget` 内置输入框处理）：

```dart
final session = await clawbot.startQrLoginSession();
session.events.listen((event) {
  if (event is QrVerifyCodeRequiredEvent) {
    // 从输入框拿到数字后提交（QrLoginWidget 已内置此交互）
    session.submitVerifyCode(userInput);
  }
  if (event is QrConfirmedEvent) {
    clawbot.connect(event.account);
  }
});
```

### `WeixinMessage`

| 属性 | 官方字段 | 说明 |
|------|----------|------|
| `messageId` | `message_id` | **`String`**（uint64 无损，Web 上不丢精度） |
| `seq` | `seq` | 消息序号 |
| `fromUserId` / `toUserId` | `from_user_id` / `to_user_id` | 发送方 / 接收方 iLink 用户 ID |
| `clientId` | `client_id` | 客户端生成的 ID |
| `createTimeMs` / `updateTimeMs` / `deleteTimeMs` | 同名 | 时间戳（毫秒） |
| `sessionId` / `groupId` / `runId` | 同名 | 会话 / 群 / 生成运行 ID |
| `messageKind` / `state` | `message_type` / `message_state` | `MessageType.user/bot` 、`MessageState.fresh/generating/finish` |
| `isFromUser` | — | `true` 表示来自真实用户 |
| `textContent` | — | 第一条文本/语音转文字内容（便捷 getter） |
| `imageItem` / `voiceItem` / `fileItem` / `videoItem` | `*_item` | 首个对应媒体段 |
| `refMessage` | `item_list[].ref_msg` | 被引用消息（含 `title`、`svrId`、`partialText`） |
| `items` | `item_list` | 消息体列表：文本/图片/语音/文件/视频/工具调用(11、12) |

`MessageItem` 额外携带 `createTimeMs`、`updateTimeMs`、`isCompleted`、`msgId`（uint64 字符串）。

---

## API 速率限制与会话失效

- 每个机器人账号约 **7 条 / 5 分钟**，服务端限制，所有客户端共享。
- 错误码 `-2`：触发频率限制，等待 5–10 秒后重试。
- 错误码 `-14`（`staleTokenErrcode`）：bot_token 已失效。与官方 `session-guard` 一致，
  本包会把该账号**冷却一小时**（期间不再发请求），轮询流以 `SessionPausedException`
  报错结束；需重新扫码登录（`showQrLoginDialog`）。冷却可用
  `isSessionPaused()` / `sessionPauseRemaining()` 查询，登录成功后自动解除。

---

## 常见问题

**Q：绑定成功后页面仍显示"未绑定"？**  
`startQrLogin` 会在 `QrConfirmedEvent` 到达监听器**之后**异步保存账号，
因此 `onLoggedIn` 触发时账号状态已正确更新。如果遇到此问题，请确认使用的是最新版本。

**Q：发送消息返回"No recipient"？**  
`toUserId` 必须显式提供，或通过 `account.defaultTo`（绑定时自动写入）获取。
若 `defaultTo` 为空，说明服务端未在登录响应中返回 `ilink_user_id`，
可先让对方发一条消息，轮询器会自动从入站消息中提取并缓存收件人 ID。

**Q：如何换绑或解绑？**  
换绑：用同一微信号去**扫描另一个 bot**，`QrConfirmedEvent` 后本机会自动清掉该微信
用户的旧账号（官方 `clearStaleAccountsForUserId`）。解绑：`await clawbot.unbind()`，
即 `notifyStop` + 删本机凭据。协议本身**没有**换绑/解绑接口，详见上方第 7、8 节。

**Q：收到 `QrAlreadyConnectedEvent` 是失败吗？**  
不是。它对应服务端 `binded_redirect`，官方也把它当成功（“已连接过此 OpenClaw，
无需重复连接”）：本机已存凭据仍然有效，直接 `connect()` 即可。

**Q：为什么轮询流突然报 `SessionPausedException`？**  
服务端返回了 `-14`（bot_token 失效）。按官方 `session-guard` 该账号会冷却一小时，
请用 `showQrLoginDialog` 重新扫码（成功后冷却自动解除）。

**Q：Flutter Web 下请求失败（CORS 错误）？**  
需要启动本地代理服务器（见上方"Flutter Web"章节）。发送媒体时若报“missing
x-encrypted-param header”，确认代理已带上 `Access-Control-Expose-Headers`（仓库自带
`example/bin/proxy_server.dart` 已支持）。

---

## 工作原理

```
Flutter App / Dart Server
    │
    ├─ POST /ilink/bot/get_bot_qrcode?bot_type=3   → 取 QR 码（携带最新 10 个 local_token_list）
    ├─ GET  /ilink/bot/get_qrcode_status           → 轮询扫码状态（wait/scaned/need_verifycode/
    │       ↑ 微信用户扫码并在手机端确认            expired/scaned_but_redirect/binded_redirect/confirmed）
    ├─ POST /ilink/bot/msg/notifystart             → 通道启动（connect 时）
    ├─ POST /ilink/bot/getupdates                  → 长轮询接收消息（服务端持有连接 ~35s）
    ├─ POST /ilink/bot/getconfig                   → 取 typing_ticket
    ├─ POST /ilink/bot/sendtyping                  → 显示/取消“正在输入”
    ├─ POST /ilink/bot/getuploadurl                → 取上传参数（出站媒体）
    │   POST {cdn}/upload?encrypted_query_param=…  → AES-128-ECB 密文，读 x-encrypted-param
    ├─ POST /ilink/bot/sendmessage                 → 发送消息（body 包 `msg`，附 context_token）
    └─ POST /ilink/bot/msg/notifystop              → 通道停止（disconnect / unbind / dispose）

Base URL: https://ilinkai.weixin.qq.com  （登录后可能切换到账号专属域名）
CDN:      https://novac2c.cdn.weixin.qq.com/c2c
Auth:     Authorization: Bearer <bot_token> + AuthorizationType: ilink_bot_token
Common:   iLink-App-Id、iLink-App-ClientVersion、X-WECHAT-UIN、(SKRouteTag)
base_info: channel_version + bot_agent（所有已鉴权请求）
```

---

## 参考与致谢

本 package 的协议实现大量参考了腾讯官方的 OpenClaw 微信通道插件：

- **[Tencent/openclaw-weixin](https://github.com/Tencent/openclaw-weixin)**（npm: `@tencent-weixin/openclaw-weixin`）——官方 OpenClaw 微信 channel 插件。本项目已逐项对齐其协议实现：全部 9 个端点（`getupdates` 长轮询、`sendmessage`、`getconfig`、`sendtyping`、`notifystart`/`notifystop`、`getuploadurl`、`get_bot_qrcode`、`get_qrcode_status`）、请求头与 `base_info`（`channel_version` + `bot_agent`及其语法清洗）、`local_token_list` 上限 10、扫码状态机（含配对数字、IDC 重定向、二维码自动刷新≤3 次、`binded_redirect` 视为成功）、换绑时的 `clearStaleAccountsForUserId`、解绑时的 `clearWeixinAccount` + `notifyStop`、`-14` 一小时会话冷却、uint64 无损解析（`parseWeixinApiJson`）、CDN 上传/下载参数与 AES-128-ECB + PKCS7 加解密。
- **[@claw-lab/wxclawbot-cli](https://github.com/lroolle/wxclawbot-cli)** 与 **[openclaw-weixin-cli](https://github.com/pzx521521/openclaw-weixin-cli)**——第三方 CLI 实现，协议细节参考。

感谢以上开源项目。

## 许可证

MIT
