import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:weixin_clawbot/weixin_clawbot.dart';
import 'qr_login_widget.dart';

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
  // 官方 base_info.bot_agent（仅用于服务端观测，不参与鉴权/路由）。
  botAgent: 'WeixinClawbotExample/0.5.0',
);

// ─────────────────────────────────────────────────────────────────────────────

/// 示例应用的首页，整合了**绑定 / 换绑 / 解绑**、多账号管理与消息收发。
///
/// 页面状态由 [_account] 决定：
/// - `null`  → 显示扫码绑定页（[_buildLogin]）
/// - 非 null → 显示聊天页（[_buildChat]）
///
/// 三个绑定相关操作的协议依据（与官方 openclaw-weixin 一致）：
///
/// | 操作 | 协议依据 |
/// | ---- | -------- |
/// | 绑定 | `get_bot_qrcode` + `get_qrcode_status` 扫码握手 |
/// | 换绑 | 无专用接口：用同一微信号扫描**另一个 bot**，confirmed 后本机自动删除该微信用户的旧账号（官方 `clearStaleAccountsForUserId`） |
/// | 解绑 | 无服务端接口：`notifyStop` + 删除本机凭证（官方 `stopAccount` + `clearWeixinAccount`） |
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// 当前使用的账号（`null` 表示未绑定）。
  ClawBotAccount? _account;

  /// 本机保存的全部账号（支持多账号，与官方一致）。
  List<ClawBotAccount> _accounts = [];

  final List<WeixinMessage> _messages = [];
  final _controller = TextEditingController();
  final _toController = TextEditingController();
  bool _sending = false;

  /// 长轮询订阅（切换/解绑账号时取消）。
  StreamSubscription<WeixinMessage>? _sub;

  /// 会话被 -14（bot_token 失效）冷却时的剩余分钟数；null 表示正常。
  int? _sessionPausedMinutes;

  /// 是否在收到消息时发送“正在输入”状态（`getconfig` + `sendtyping`）。
  bool _typingEnabled = false;

  /// Flutter Web：本地 CORS 代理可达性（null=检测中）。
  bool? _proxyReachable;

  @override
  void initState() {
    super.initState();
    // 应用启动时尝试从本地存储中恢复已绑定账号，若存在则直接重连。
    _init();
    _checkProxy();
  }

  /// 探测本地 CORS 代理是否在线。任何 HTTP 响应（包括上游的 404）都算
  /// 可达；只有网络层失败（连接拒绝等）才算离线。
  Future<void> _checkProxy() async {
    if (!kIsWeb) return;
    try {
      await http
          .get(Uri.parse('$_webProxyUrl/'))
          .timeout(const Duration(seconds: 4));
      if (mounted) setState(() => _proxyReachable = true);
    } catch (_) {
      if (mounted) setState(() => _proxyReachable = false);
    }
  }

  /// 从持久化存储中加载全部已绑定账号并自动重连第一个。
  /// 如果尚未绑定，[_account] 保持为 null，页面展示扫码入口。
  Future<void> _init() async {
    final accounts = await _clawbot.loadAllAccounts();
    if (!mounted) return;
    setState(() => _accounts = accounts);
    if (accounts.isNotEmpty) _connectAccount(accounts.first);
  }

  /// 将 [account] 设为当前账号并启动长轮询消息监听。
  ///
  /// - 更新 UI 状态（切换到聊天页）。
  /// - 若收件人框为空，用 [ClawBotAccount.defaultTo] 预填（绑定时自动写入）。
  /// - 监听 [WeixinClawbot.connect] 返回的消息流，收到消息后追加到列表。
  /// - `connect()` 会像官方 `startAccount` 一样发送 `notifyStart`。
  void _connectAccount(ClawBotAccount account) {
    _sub?.cancel();
    setState(() {
      _account = account;
      _messages.clear();
      _sessionPausedMinutes = null;
    });
    if (_toController.text.isEmpty && account.defaultTo != null) {
      _toController.text = account.defaultTo!;
    }
    _sub = _clawbot.connect(account).listen(_onMessage, onError: (Object e) {
      // 长轮询在 bot_token 失效（errcode -14）时抛错并进入一小时冷却，
      // 与官方 session-guard 行为一致。
      if (!mounted) return;
      final minutes =
          (_clawbot.sessionPauseRemaining(account.id).inMilliseconds / 60000)
              .ceil();
      setState(() => _sessionPausedMinutes = minutes <= 0 ? 1 : minutes);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('会话已过期（errcode -14）：$e')),
      );
    });
  }

  void _onMessage(WeixinMessage msg) {
    if (!mounted) return;
    setState(() => _messages.add(msg));
    // 演示 getconfig + sendtyping：对方发来消息时显示“正在输入”。
    if (_typingEnabled && msg.isFromUser) {
      _clawbot.showTyping(msg.fromUserId, accountId: _account?.id);
    }
  }

  /// 弹出 QR 扫码绑定对话框（新增账号）。
  Future<void> _login() async {
    final account = await showQrLoginDialog(
      context: context,
      clawbot: _clawbot,
      onAlreadyConnected: (_) => _showAlreadyConnected(),
    );
    if (account != null && mounted) {
      await _refreshAccounts();
      _connectAccount(account);
    }
  }

  /// `binded_redirect`：官方把它当作成功态（alreadyConnected），本机凭据仍然有效。
  void _showAlreadyConnected() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('该 ClawBot 已连接过此客户端（本机已存凭据），无需重复扫码。'),
      ),
    );
    // 保证列表与当前账号同步，方便直接使用已保存的凭据。
    final stored = _accounts;
    if (_account == null && stored.isNotEmpty) _connectAccount(stored.first);
  }

  /// **换绑（re-bind）**。
  ///
  /// iLink 协议没有换绑接口：换绑就是让同一个微信用户扫描“另一个 bot”。
  /// 扫码 confirmed 后，本体会自动删除该微信用户的其它旧账号（官方
  /// `clearStaleAccountsForUserId`），从而把该微信用户接到新 bot 上。
  ///
  /// 若扫描的 bot 已经绑定在本机，服务端返回 `binded_redirect`，
  /// 登录流以 [QrAlreadyConnectedEvent]（成功态）结束，不会产生新凭据。
  Future<void> _rebind() async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('换绑微信账号'),
        content: const SelectableText(
          '官方协议没有“换绑”接口，换绑的做法是：用同一个微信号扫描另一个 '
          'ClawBot 的二维码。\n\n'
          '扫码成功后，本机会自动删除该微信用户的其它旧账号'
          '（等价于官方 clearStaleAccountsForUserId），避免新旧 bot 的 '
          'context_token 互相混淆。\n\n'
          '如果扫描的 bot 已经绑定在本机，服务端会返回“已连接过”，'
          '不会重复发放凭据。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('继续扫码'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    final before = _accounts.map((a) => a.id).toSet();
    final account = await showQrLoginDialog(
      context: context,
      clawbot: _clawbot,
      title: '换绑：扫码新的 ClawBot',
      onAlreadyConnected: (_) => _showAlreadyConnected(),
    );
    if (account == null || !mounted) return;

    await _refreshAccounts();
    if (!mounted) return;
    final removed = before.difference(_accounts.map((a) => a.id).toSet());
    _connectAccount(account);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(removed.isEmpty
            ? '已连接到 ${account.botId}（无旧账号被清理）'
            : '已换绑到 ${account.botId}，清理旧账号 ${removed.length} 个：'
                '${removed.map((e) => e.split('@').first).join('、')}'),
      ),
    );
  }

  /// **解绑（un-bind）**。
  ///
  /// iLink 协议没有服务端解绑接口，官方解绑 = `notifyStop`（停止投递）
  /// + 删除本机保存的凭据。微信侧的授权记录需在手机端微信里管理。
  Future<void> _unbind(ClawBotAccount account) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解绑该 ClawBot？'),
        content: SelectableText(
          '将执行：\n'
          '1. 停止消息长轮询；\n'
          '2. 调用 POST /ilink/bot/msg/notifystop 通知服务端停止投递；\n'
          '3. 删除本机保存的 bot_token / baseUrl / context_token。\n\n'
          '注意：协议没有服务端解绑接口（官方插件同样只清理本机凭据），'
          '微信端的授权记录需要在手机端微信中查看和管理。\n\n'
          'Bot: ${account.botId}\n'
          '微信用户: ${account.defaultTo ?? '未知'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认解绑'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    final removed = await _clawbot.unbind(accountId: account.id);
    if (!mounted) return;
    await _refreshAccounts();
    if (!mounted) return;

    final next = _accounts.isEmpty ? null : _accounts.first;
    if (next == null) {
      _sub?.cancel();
      setState(() {
        _account = null;
        _messages.clear();
        _sessionPausedMinutes = null;
      });
    } else {
      _connectAccount(next);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已解绑 ${removed.length} 个账号（notifyStop 已发送）')),
    );
  }

  /// 切换当前使用的账号（多账号）。
  void _switchAccount(ClawBotAccount account) {
    if (account.id == _account?.id) return;
    _connectAccount(account);
  }

  Future<void> _refreshAccounts() async {
    final accounts = await _clawbot.loadAllAccounts();
    if (!mounted) return;
    setState(() => _accounts = accounts);
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
    final result = await _clawbot.sendText(
      text: text,
      toUserId: to,
      accountId: _account?.id,
    );
    // 回复已发出，取消“正在输入”状态（官方在回复完成后同样如此）。
    if (_typingEnabled) {
      await _clawbot.cancelTyping(to, accountId: _account?.id);
    }
    if (!mounted) return;
    setState(() => _sending = false);

    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: SelectableText('发送失败：${result.error}')),
      );
    } else {
      _controller.clear();
      // 服务器不会在 getupdates 长轮询里回显 bot 自己发出的消息（与官方
      // openclaw-weixin 行为一致），这里本地乐观插入，让聊天界面立即显示
      // 刚刚发送的内容。messageType=2 → 绿色气泡、居右。
      setState(() {
        _messages.add(WeixinMessage(
          seq: 0,
          messageId: result.messageId,
          fromUserId: _account!.botId,
          toUserId: to,
          clientId: result.clientId,
          createTimeMs: DateTime.now().millisecondsSinceEpoch,
          messageType: MessageType.bot.value,
          messageState: MessageState.finish.value,
          items: [
            MessageItem.text(text),
          ],
        ));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = _account;
    return Scaffold(
      appBar: AppBar(
        title: const Text('WeChat ClawBot'),
        actions: [
          if (_accounts.length > 1) _accountMenu(),
          if (account != null) ...[
            IconButton(
              icon: const Icon(Icons.swap_horiz),
              tooltip: '换绑（扫描另一个 ClawBot）',
              onPressed: _rebind,
            ),
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: '解绑（notifyStop + 清理本机凭据）',
              onPressed: () => _unbind(account),
            ),
          ] else
            IconButton(
              icon: const Icon(Icons.swap_horiz),
              tooltip: '换绑（扫描另一个 ClawBot）',
              onPressed: _rebind,
            ),
        ],
      ),
      body: account == null ? _buildLogin() : _buildChat(account),
    );
  }

  /// 多账号切换菜单（官方支持一个 Gateway 上挂多个微信账号）。
  Widget _accountMenu() {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.account_circle),
      tooltip: '切换账号（${_accounts.length} 个）',
      onSelected: (id) {
        final target = _accounts.firstWhere((a) => a.id == id);
        _switchAccount(target);
      },
      itemBuilder: (_) => [
        for (final a in _accounts)
          PopupMenuItem<String>(
            value: a.id,
            enabled: a.id == _account?.id,
            child: Row(
              children: [
                Icon(
                  a.id == _account?.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(a.botId, overflow: TextOverflow.ellipsis)),
                if (a.id == _account?.id && _sessionPausedMinutes != null)
                  const Icon(Icons.warning_amber,
                      size: 16, color: Colors.orange),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildLogin() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (kIsWeb)
            _proxyReachable == true
                ? const _ProxyStatusChip(proxyUrl: _webProxyUrl)
                : _WebProxyBanner(
                    proxyUrl: _webProxyUrl,
                    checking: _proxyReachable == null,
                    onRetry: _checkProxy,
                  ),
          const Icon(Icons.qr_code, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text('尚未绑定微信账号'),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              '也可以先解绑再重新扫码，或使用“换绑”扫描另一个 ClawBot。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _login,
            icon: const Icon(Icons.link),
            label: const Text('扫码绑定微信'),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _rebind,
            icon: const Icon(Icons.swap_horiz, size: 18),
            label: const Text('换绑到另一个 ClawBot'),
          ),
        ],
      ),
    );
  }

  Widget _buildChat(ClawBotAccount account) {
    return Column(
      children: [
        // Account info banner
        Container(
          color: _sessionPausedMinutes == null
              ? Colors.green.shade50
              : Colors.orange.shade50,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(
                _sessionPausedMinutes == null
                    ? Icons.check_circle
                    : Icons.error,
                color: _sessionPausedMinutes == null
                    ? Colors.green
                    : Colors.orange,
                size: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _sessionPausedMinutes == null
                    ? Text(
                        '已绑定 · Bot: ${account.botId}\n'
                        '微信用户: ${account.defaultTo ?? '未知'} · '
                        '账号 ${_accounts.indexOf(account) + 1}/${_accounts.length}',
                        style: const TextStyle(fontSize: 12, height: 1.4),
                      )
                    : Text(
                        '会话已过期（errcode -14），冷却中：剩余约 '
                        '$_sessionPausedMinutes 分钟。请解绑后重新扫码。',
                        style: const TextStyle(fontSize: 12),
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
              // getconfig + sendtyping 演示开关
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Checkbox(
                    value: _typingEnabled,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (v) =>
                        setState(() => _typingEnabled = v ?? false),
                  ),
                  const Text('收到消息时显示“正在输入”', style: TextStyle(fontSize: 11)),
                  const SizedBox(width: 4),
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
    _sub?.cancel();
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
        _nonTextPlaceholder(msg) ??
        (msg.items.isNotEmpty ? '[非文本消息]' : '');

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
            if (msg.refMessage != null)
              Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0x0D000000),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '引用: ${msg.refMessage!.title ?? msg.refMessage!.svrId ?? '(未知消息)'}',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
                ),
              ),
            if (image != null)
              _ImageMessageView(image: image, downloadImage: downloadImage),
            if (text.isNotEmpty) ...[
              if (image != null) const SizedBox(height: 4),
              Text(text),
            ],
            const SizedBox(height: 2),
            Text(
              '$timeStr · ${msg.fromUserId.split('@').first}'
              '${msg.messageId != null ? ' · #${msg.messageId}' : ''}',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  /// Label for item types the bubble cannot render as text.
  static String? _nonTextPlaceholder(WeixinMessage msg) {
    if (msg.fileItem != null) return '[文件] ${msg.fileItem!.fileName ?? ''}';
    if (msg.videoItem != null) return '[视频]';
    if (msg.voiceItem != null) return '[语音]';
    for (final item in msg.items) {
      switch (item.type) {
        case MessageItemType.toolCallStart:
          return '[工具调用] ${item.toolCallStart?.toolName ?? ''}';
        case MessageItemType.toolCallResult:
          return '[工具结果] ${item.toolCallResult?.status ?? ''}';
        default:
          break;
      }
    }
    return null;
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
                  child: SelectableText(
                    detail,
                    maxLines: 3,
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

  /// null = 正在检测代理，非 null = 上次检测离线后用户可重试。
  final bool checking;
  final Future<void> Function()? onRetry;

  const _WebProxyBanner({
    required this.proxyUrl,
    this.checking = false,
    this.onRetry,
  });

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
                checking ? '正在检查 CORS 代理…' : '未连接到 CORS 代理',
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
          if (!checking && onRetry != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('我已启动代理，重新检测'),
            ),
          ],
        ],
      ),
    );
  }
}

/// 代理在线时的绿色确认条。
class _ProxyStatusChip extends StatelessWidget {
  final String proxyUrl;

  const _ProxyStatusChip({required this.proxyUrl});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        border: Border.all(color: Colors.green.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 15, color: Colors.green.shade700),
          const SizedBox(width: 6),
          Text(
            '已连接 CORS 代理：$proxyUrl',
            style: TextStyle(fontSize: 12, color: Colors.green.shade800),
          ),
        ],
      ),
    );
  }
}
