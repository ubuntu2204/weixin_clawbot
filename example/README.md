# weixin_clawbot_example

`weixin_clawbot` package 的完整示例应用，演示微信扫码绑定、接收消息、发送消息的全流程。

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
    └── main.dart           # 示例 Flutter 应用
```

---

## 示例功能说明

| 功能 | 说明 |
|------|------|
| 扫码绑定 | 点击"扫码绑定微信"弹出二维码对话框，微信扫码后自动切换到聊天页 |
| 接收消息 | 长轮询实时接收来自微信的消息，气泡左右区分用户/机器人 |
| 发送消息 | 在收件人框填入对方 iLink ID，输入消息后点击发送；绑定后自动填入默认收件人 |
| 断开绑定 | 点击右上角退出图标，清除本地凭证并返回绑定页 |
| 持久化重连 | 应用重启后自动从本地存储恢复账号并重新建立连接 |

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
