# weixin_clawbot

一个 Flutter package，通过微信扫码绑定 ClawBot（基于 OpenClaw iLink Bot API），并在 Flutter 应用中接收/发送微信消息。

灵感来源：[@claw-lab/wxclawbot-cli](https://github.com/lroolle/wxclawbot-cli) 和 [openclaw-weixin-cli](https://github.com/pzx521521/openclaw-weixin-cli)。

---

## 功能

| 功能 | 描述 |
|------|------|
| 🔗 微信扫码绑定 | 获取 QR 码 → 微信扫描 → 自动保存凭证 |
| 📥 接收消息 | HTTP 长轮询 (`getupdates`)，消息以 `Stream<WeixinMessage>` 形式推送 |
| 📤 发送消息 | 发送文本消息，自动携带 `context_token` |
| 💾 凭证持久化 | 使用 `shared_preferences` 跨应用重启保存账号 |
| 🧩 开箱即用 Widget | `QrLoginWidget` / `showQrLoginDialog` 直接放入 UI |

---

## 快速开始

### 1. 添加依赖

```yaml
dependencies:
  weixin_clawbot: ^0.1.0
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

// 方式 A：对话框（推荐）
final account = await showQrLoginDialog(
  context: context,
  clawbot: clawbot,
);
if (account != null) {
  // account.defaultTo 即绑定时扫码的微信用户 ID，可直接作为 toUserId 使用
  clawbot.connect(account).listen((msg) {
    print('收到消息：${msg.textContent}');
  });
}

// 方式 B：嵌入到自定义页面
QrLoginWidget(
  clawbot: clawbot,
  onLoggedIn: (account) {
    clawbot.connect(account).listen((msg) {
      print('收到消息：${msg.textContent}');
    });
  },
)
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

### 5. 发送消息

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

主门面类，管理账号与连接。

| 方法 | 说明 |
|------|------|
| `loadAccount()` | 返回第一个持久化账号，无则返回 `null` |
| `loadAllAccounts()` | 返回所有持久化账号 |
| `startQrLogin()` | 返回 `Stream<QrLoginEvent>`，驱动 QR 扫码绑定流程 |
| `connect(account)` | 启动长轮询，返回 `Stream<WeixinMessage>` |
| `sendText({text, toUserId?, accountId?})` | 向指定用户发送文本消息 |
| `disconnect(accountId)` | 停止指定账号的长轮询 |
| `logout({accountId?})` | 删除持久化账号并停止轮询（`null` 则清除全部） |
| `dispose()` | 停止所有轮询并释放 HTTP 连接池 |

### `ClawBotAccount`

| 字段 | 说明 |
|------|------|
| `id` / `botId` | 机器人在 iLink 平台的用户 ID |
| `token` | Bearer 鉴权令牌 |
| `baseUrl` | 服务器分配的 API 地址（可能与默认地址不同） |
| `defaultTo` | 绑定时扫码的微信用户 ID（扫码登录后自动写入，可直接用作 `toUserId`） |
| `contextToken` | 最近一条入站消息携带的 context token，用于主动推送通知 |

### `QrLoginEvent` 子类型

| 类型 | 说明 |
|------|------|
| `QrReadyEvent(qrContent)` | QR 码内容就绪，传给 `QrImageView` 显示 |
| `QrScannedEvent` | 用户已在微信扫码，等待手机端确认 |
| `QrConfirmedEvent(account)` | 登录成功，账号已自动持久化 |
| `QrExpiredEvent` | QR 码超时过期，需重新获取 |
| `QrErrorEvent(error, stackTrace)` | 网络或服务端错误 |

### `WeixinMessage`

| 属性 | 说明 |
|------|------|
| `fromUserId` | 发送方 iLink 用户 ID |
| `toUserId` | 接收方 iLink 用户 ID |
| `textContent` | 第一条文本/语音转文字内容（便捷 getter） |
| `isFromUser` | `true` 表示来自真实用户（`messageType == 1`） |
| `contextToken` | 回复所需的 token，轮询器自动缓存，无需手动管理 |
| `createTimeMs` | 消息创建时间戳（毫秒级 Unix 时间） |
| `items` | 消息体列表，支持文本、图片、语音、文件、视频 |

---

## API 速率限制

- 每个机器人账号约 **7 条 / 5 分钟**，服务端限制，所有客户端共享。
- 错误码 `-2`：触发频率限制，等待 5–10 秒后重试。
- 错误码 `-14`：会话已过期，需重新扫码登录（`showQrLoginDialog`）。

---

## 常见问题

**Q：绑定成功后页面仍显示"未绑定"？**  
`startQrLogin` 会在 `QrConfirmedEvent` 到达监听器**之后**异步保存账号，
因此 `onLoggedIn` 触发时账号状态已正确更新。如果遇到此问题，请确认使用的是最新版本。

**Q：发送消息返回"No recipient"？**  
`toUserId` 必须显式提供，或通过 `account.defaultTo`（绑定时自动写入）获取。
若 `defaultTo` 为空，说明服务端未在登录响应中返回 `ilink_user_id`，
可先让对方发一条消息，轮询器会自动从入站消息中提取并缓存收件人 ID。

**Q：Flutter Web 下请求失败（CORS 错误）？**  
需要启动本地代理服务器（见上方"Flutter Web"章节）。

---

## 工作原理

```
Flutter App
    │
    ├─ GET /ilink/bot/get_bot_qrcode     → 获取 QR 码内容（bot_type=3）
    ├─ GET /ilink/bot/get_qrcode_status  → 轮询扫码状态（wait / scaned / confirmed）
    │       ↑ 微信用户扫码并在手机端确认
    ├─ POST /ilink/bot/getupdates        → 长轮询接收消息（服务端持有连接 ~35s）
    └─ POST /ilink/bot/sendmessage       → 发送消息（附带 context_token 可触发通知）

Base URL: https://ilinkai.weixin.qq.com  （登录后可能切换到账号专属域名）
Auth:     Authorization: Bearer <bot_token>
```

---

## 许可证

MIT
