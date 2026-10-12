# weixin_clawbot_example

`weixin_clawbot` package 的完整示例应用，演示**扫码绑定、换绑、解绑**、多账号管理、
接收/发送消息（含图片与“正在输入”状态）的全流程。

---

## 运行方式

### 原生平台（macOS / Linux / Windows）

```bash
cd example
flutter run
```

### Flutter Web（需要本地 CORS 代理）

iLink API 不返回 CORS 头，浏览器会拦截直接请求。需先启动本地代理再运行：

**终端 1 — 启动代理**

```bash
cd example
dart run bin/proxy_server.dart
# 输出：✓ CORS proxy running on http://localhost:3001
```

**终端 2 — 启动 Flutter Web**

```bash
cd example
flutter run -d chrome --dart-define=PROXY_URL=http://localhost:3001
```

> 不传 `PROXY_URL` 时默认也是 `http://localhost:3001`，无需每次手动指定。

---

## 目录结构

```
example/
├── bin/
│   └── proxy_server.dart   # 本地 CORS 反向代理（仅 Flutter Web 开发需要）
└── lib/
    ├── main.dart           # 示例 Flutter 应用（绑定/换绑/解绑/多账号/聊天）
    └── qr_login_widget.dart # 可复制到你应用里的 QR 登录 Widget 与对话框
```

---

## 示例功能说明

| 功能 | 入口 | 说明 |
|------|------|------|
| 扫码绑定 | 「扫码绑定微信」 | 弹出二维码对话框，微信扫码后自动切到聊天页；`connect` 会发 `notifyStart` |
| 换绑 | 右上角 ⇄ 图标 | 协议无换绑接口：用同一微信号**扫描另一个 bot**，confirmed 后自动清除该微信用户的旧账号（对齐官方 `clearStaleAccountsForUserId`），并以 SnackBar 告知被清理的账号 |
| 解绑 | 右上角退出图标 | 先弹确认框说明“协议无服务端解绑接口”，确认后执行 `unbind()`：停轮询 → `notifyStop` → 删本机 `bot_token`/`context_token` |
| 多账号切换 | 右上角账号图标（≥ 2 个时） | 对应官方“一个 Gateway 挂多个微信账号” |
| 已连接提示 | 重复扫描同一 bot | 服务端返回 `binded_redirect`，示例按官方语义当作**成功**提示，不当失败 |
| 二维码自动刷新 | 自动 | 过期 / 配对码错乱时自动换新码（最多 3 个）并显示刷新进度 |
| 接收消息 | 聊天页 | 长轮询实时接收，气泡左右区分用户/机器人；图片自动下载解密；引用/文件/视频/语音显示类型标签 |
| 发送消息 | 聊天页底部 | 自动携带 `context_token`；收件人框默认填入绑定的微信用户 ID |
| 输入状态 | 聊天页底部开关 | 开启后收到消息时 `getconfig` + `sendtyping` 显示“正在输入”，回复后自动取消 |
| 会话过期横幅 | 自动 | 收到 `-14` 时按官方 `session-guard` 冷却一小时，页面提示剩余时间并要求重新扫码 |
| 持久化重连 | 自动 | 应用重启后自动从本地存储恢复账号并重新建立连接 |

---

## 关于收件人 ID

绑定成功后，`account.defaultTo` 字段中保存了扫码用户的 iLink ID（格式通常为 `xxxxxx@im.wechat`）。
示例应用会自动将其填入"收件人"输入框，无需手动输入即可直接发消息测试。

若收件人框为空，说明服务端本次登录未返回 `ilink_user_id`，可先让对方发一条消息，
轮询器会自动从入站消息中提取并回填。

---

## CORS 代理说明

`bin/proxy_server.dart` 使用 [`shelf`](https://pub.dev/packages/shelf) 在 `localhost:3001` 启动一个 HTTP 服务器，
它将来自浏览器的请求原样转发到 `https://ilinkai.weixin.qq.com`，并在响应头中注入 `Access-Control-Allow-*`。

只转发必要的请求头（`Content-Type`、`Authorization`、`AuthorizationType`、`X-WECHAT-UIN`、`iLink-App-ClientVersion`），其余头不透传。

**注意**：代理仅用于本地开发，不要将其暴露到公网。
