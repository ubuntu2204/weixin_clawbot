import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:weixin_clawbot/weixin_clawbot.dart';

/// Flutter Web 需要通过本地 CORS 代理访问 iLink API。
/// 运行代理服务器：dart run bin/proxy_server.dart
/// 然后用 --dart-define=PROXY_URL=http://localhost:3001 启动 Flutter Web。
const _webProxyUrl = String.fromEnvironment(
  'PROXY_URL',
  defaultValue: 'http://localhost:3001',
);

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WeChat ClawBot 示例',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

/// 应用全局唯一的 ClawBot 实例。
/// 在 Flutter Web 上通过本地 CORS 代理转发请求；原生平台直连 iLink API。
final _clawbot = WeixinClawbot(
  proxyBaseUrl: kIsWeb ? _webProxyUrl : null,
);

// ─────────────────────────────────────────────────────────────────────────────

/// 示例应用的首页，整合了扫码绑定、消息接收与发送三个核心流程。
///
/// 页面状态由 [_account] 决定：
/// - `null`  → 显示扫码绑定页（[_buildLogin]）
/// - 非 null → 显示聊天页（[_buildChat]）
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  ClawBotAccount? _account;
  final List<WeixinMessage> _messages = [];
  final _controller = TextEditingController();
  final _toController = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // 应用启动时尝试从本地存储中恢复已绑定账号，若存在则直接重连。
    _init();
  }

  /// 从持久化存储中加载已绑定账号并自动重连。
  /// 如果尚未绑定，[_account] 保持为 null，页面展示扫码入口。
  Future<void> _init() async {
    final account = await _clawbot.loadAccount();
    if (account != null && mounted) {
      _connectAccount(account);
    }
  }

  /// 将 [account] 设为当前账号并启动长轮询消息监听。
  ///
  /// - 更新 UI 状态（切换到聊天页）。
  /// - 若收件人框为空，用 [ClawBotAccount.defaultTo] 预填（绑定时自动写入）。
  /// - 监听 [WeixinClawbot.connect] 返回的消息流，收到消息后追加到列表。
  void _connectAccount(ClawBotAccount account) {
    setState(() => _account = account);
    if (_toController.text.isEmpty && account.defaultTo != null) {
      _toController.text = account.defaultTo!;
    }
    _clawbot.connect(account).listen((msg) {
      if (mounted) {
        setState(() => _messages.add(msg));
      }
    });
  }

  /// 弹出 QR 扫码绑定对话框。
  ///
  /// 用户在微信扫码并确认后，[showQrLoginDialog] 返回新账号；
  /// 此时调用 [_connectAccount] 切换页面并开始接收消息。
  Future<void> _login() async {
    final account = await showQrLoginDialog(
      context: context,
      clawbot: _clawbot,
    );
    if (account != null && mounted) {
      _connectAccount(account);
    }
  }

  /// 发送输入框中的文本消息。
  ///
  /// 校验逻辑：
  /// 1. 消息内容不能为空。
  /// 2. 收件人 ID 不能为空（通常由 [ClawBotAccount.defaultTo] 自动填充）。
  ///
  /// 发送成功后清空消息输入框；失败时通过 [SnackBar] 显示错误原因。
  Future<void> _send() async {
    final text = _controller.text.trim();
    final to = _toController.text.trim();
    if (text.isEmpty) return;
    if (to.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写收件人 ID')),
      );
      return;
    }

    setState(() => _sending = true);
    final result = await _clawbot.sendText(text: text, toUserId: to);
    setState(() => _sending = false);

    if (!mounted) return;
    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发送失败：${result.error}')),
      );
    } else {
      _controller.clear();
    }
  }

  /// 解绑当前账号：清除持久化凭证、停止消息轮询、重置页面状态。
  Future<void> _logout() async {
    await _clawbot.logout();
    if (mounted) {
      setState(() {
        _account = null;
        _messages.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WeChat ClawBot'),
        actions: [
          if (_account != null)
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: '解绑',
              onPressed: _logout,
            ),
        ],
      ),
      body: _account == null ? _buildLogin() : _buildChat(),
    );
  }

  Widget _buildLogin() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (kIsWeb) const _WebProxyBanner(proxyUrl: _webProxyUrl),
          const Icon(Icons.qr_code, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text('尚未绑定微信账号'),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _login,
            icon: const Icon(Icons.link),
            label: const Text('扫码绑定微信'),
          ),
        ],
      ),
    );
  }

  Widget _buildChat() {
    return Column(
      children: [
        // Account info banner
        Container(
          color: Colors.green.shade50,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.green, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '已绑定 · Bot: ${_account!.botId}',
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),

        // Message list
        Expanded(
          child: _messages.isEmpty
              ? const Center(
                  child: Text(
                    '暂无消息\n等待微信消息中…',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _messages.length,
                  itemBuilder: (_, i) => _MessageBubble(
                    msg: _messages[i],
                    downloadImage: _clawbot.downloadImage,
                  ),
                ),
        ),

        // Input bar
        Padding(
          padding: EdgeInsets.fromLTRB(
            8,
            4,
            8,
            MediaQuery.of(context).viewInsets.bottom + 8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _toController,
                decoration: const InputDecoration(
                  hintText: '收件人 ID（to_user_id）',
                  labelText: '收件人',
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        hintText: '发送消息…',
                        border: OutlineInputBorder(),
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _sending
                      ? const SizedBox(
                          width: 44,
                          height: 44,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton.filled(
                          onPressed: _send,
                          icon: const Icon(Icons.send),
                        ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _toController.dispose();
    _clawbot.dispose();
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final WeixinMessage msg;

  /// Downloads & decrypts an inbound image item (provided by the app's
  /// `WeixinClawbot` instance).
  final Future<Uint8List> Function(ImageItemData) downloadImage;

  const _MessageBubble({required this.msg, required this.downloadImage});

  @override
  Widget build(BuildContext context) {
    final isUser = msg.isFromUser;
    final time = DateTime.fromMillisecondsSinceEpoch(msg.createTimeMs);
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    // Prefer the first image item; fall back to text (or a placeholder for
    // other non-text types such as files/videos).
    final image = msg.imageItem;
    final text = msg.textContent ??
        (image == null && msg.items.isNotEmpty ? '[非文本消息]' : '');

    return Align(
      alignment: isUser ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        decoration: BoxDecoration(
          color: isUser ? Colors.grey.shade200 : Colors.green.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.start : CrossAxisAlignment.end,
          children: [
            if (image != null)
              _ImageMessageView(image: image, downloadImage: downloadImage),
            if (text.isNotEmpty) ...[
              if (image != null) const SizedBox(height: 4),
              Text(text),
            ],
            const SizedBox(height: 2),
            Text(
              '$timeStr · ${msg.fromUserId.split('@').first}',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders an inbound picture: downloads + decrypts it once and keeps the
/// result cached for the lifetime of this widget.
class _ImageMessageView extends StatefulWidget {
  final ImageItemData image;
  final Future<Uint8List> Function(ImageItemData) downloadImage;

  const _ImageMessageView({required this.image, required this.downloadImage});

  @override
  State<_ImageMessageView> createState() => _ImageMessageViewState();
}

class _ImageMessageViewState extends State<_ImageMessageView> {
  late Future<Uint8List> _future;

  @override
  void initState() {
    super.initState();
    _future = _download();
  }

  Future<Uint8List> _download() async {
    try {
      return await widget.downloadImage(widget.image);
    } catch (e) {
      // Surface the real cause (CORS/proxy、HTTP 状态码、解密失败等) in the
      // console — the bubble itself only shows a short headline.
      debugPrint('图片下载失败: $e');
      rethrow;
    }
  }

  void _retry() {
    setState(() => _future = _download());
  }

  @override
  Widget build(BuildContext context) {
    // 没有可用的下载参数（无 encrypt_query_param / full_url）时不要发起
    // 注定失败的请求，直接显示占位文本。
    if (!widget.image.isDownloadable) {
      return const Text('[图片]',
          style: TextStyle(fontSize: 12, color: Colors.grey));
    }
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            width: 160,
            height: 120,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        if (snapshot.hasError) {
          final detail = '${snapshot.error}';
          return InkWell(
            onTap: _retry,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.broken_image_outlined,
                        size: 18, color: Colors.grey),
                    SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '图片下载失败（点击重试）',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                  ],
                ),
                Flexible(
                  child: Text(
                    detail,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ),
              ],
            ),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            snapshot.data!,
            fit: BoxFit.contain,
            width: 240,
            errorBuilder: (_, __, ___) =>
                const Text('[图片]（无法解码）', style: TextStyle(fontSize: 12)),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Shown on Flutter Web to guide the user to start the CORS proxy server.
class _WebProxyBanner extends StatelessWidget {
  final String proxyUrl;

  const _WebProxyBanner({required this.proxyUrl});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        border: Border.all(color: Colors.amber.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: Colors.amber.shade800),
              const SizedBox(width: 6),
              Text(
                'Flutter Web 需要 CORS 代理',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.amber.shade900,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '在 example 目录运行：',
            style: TextStyle(fontSize: 12, color: Colors.amber.shade900),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.grey.shade900,
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'dart run bin/proxy_server.dart',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Colors.greenAccent,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '代理地址：$proxyUrl',
            style: TextStyle(fontSize: 11, color: Colors.amber.shade700),
          ),
        ],
      ),
    );
  }
}
