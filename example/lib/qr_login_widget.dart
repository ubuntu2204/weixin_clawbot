/// Flutter widgets for the QR login flow.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:weixin_clawbot/weixin_clawbot.dart';

/// A self-contained widget that shows the WeChat QR-code binding UI.
///
/// Embed inside any screen or dialog. It handles the full flow:
/// fetching the QR code → displaying it → polling → auto-refresh on expiry →
/// success / already connected / stopped.
///
/// The state machine mirrors the official plugin, so the UI also covers
/// **换绑**: scanning a *different* bot re-binds the same WeChat user, and
/// scanning an already-bound bot ends with [QrAlreadyConnectedEvent]
/// (`binded_redirect`), which is a success rather than an error.
///
/// ```dart
/// QrLoginWidget(
///   clawbot: clawbot,
///   onLoggedIn: (account) {
///     Navigator.of(context).pop();
///     clawbot.connect(account);
///   },
/// )
/// ```
class QrLoginWidget extends StatefulWidget {
  final WeixinClawbot clawbot;

  /// Called when login succeeds.
  final void Function(ClawBotAccount account)? onLoggedIn;

  /// Called when the server reports `binded_redirect`: this WeChat user is
  /// already connected to this client. The dialog then has nothing to store.
  final void Function(String? wechatUserId)? onAlreadyConnected;

  /// Called when the QR code expired and no refresh budget is left
  /// ([QrTooManyQrResetsEvent] / [QrLoginTimeoutEvent]).
  final VoidCallback? onExpired;

  /// Override the API base URL (optional).
  final String? baseUrl;

  /// Size of the rendered QR image in logical pixels.
  final double qrSize;

  /// Total time to wait for a scan before giving up (official default 8 min).
  final Duration loginTimeout;

  const QrLoginWidget({
    super.key,
    required this.clawbot,
    this.onLoggedIn,
    this.onAlreadyConnected,
    this.onExpired,
    this.baseUrl,
    this.qrSize = 240,
    this.loginTimeout = defaultLoginTimeout,
  });

  @override
  State<QrLoginWidget> createState() => _QrLoginWidgetState();
}

class _QrLoginWidgetState extends State<QrLoginWidget> {
  _UiState _state = _Loading();
  QrLoginSession? _session;

  /// Generation of the QR code currently on screen, used to key the image so
  /// a refreshed code always re-renders.
  int _generation = 0;

  /// 当前刷新提示文案（`正在刷新二维码…(n/3)`），在下一次 [QrReadyEvent]
  /// 到达时显示在二维码下方。
  String? _refreshNote;

  @override
  void initState() {
    super.initState();
    _startLogin();
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  Future<void> _startLogin() async {
    setState(() {
      _state = _Loading();
      _refreshNote = null;
      _generation = 0;
    });

    // Close any previous session before starting a new one.
    _session?.dispose();
    final session = await widget.clawbot.startQrLoginSession(
      baseUrl: widget.baseUrl,
      loginTimeout: widget.loginTimeout,
    );
    if (!mounted) {
      session.dispose();
      return;
    }
    _session = session;
    session.events.listen(_onEvent, onError: _onError);
  }

  void _onEvent(QrLoginEvent event) {
    if (!mounted) return;
    // Defer setState to avoid triggering during a pointer/mouse-tracking frame,
    // which causes the !_debugDuringDeviceUpdate assertion on Flutter Web.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (event) {
        case QrReadyEvent(qrContent: final content, generation: final gen):
          _generation = gen;
          setState(() {
            _refreshNote = null;
            _state = _QrReady(content);
          });
        case QrScannedEvent():
          setState(() => _state = _Scanned());
        case QrRefreshedEvent(attempt: final n, maxAttempts: final max):
          setState(() => _refreshNote = '正在刷新二维码…($n/$max)');
        case QrExpiredEvent():
          // Non-terminal: the flow refreshes automatically.
          setState(() => _state = const _Refreshing('二维码已过期，正在刷新…'));
        case QrVerifyCodeRequiredEvent(isRetry: final isRetry):
          setState(() => _state = _VerifyCode(isRetry));
        case QrVerifyCodeBlockedEvent():
          // Non-terminal: the flow refreshes automatically as well.
          setState(() => _state = const _Refreshing('多次输入错误，正在刷新二维码…'));
        case QrAlreadyConnectedEvent(wechatUserId: final userId):
          // binded_redirect — a success in the official semantics.
          setState(() => _state = const _Terminal(
                icon: Icons.check_circle_outline,
                label: '已连接过此 OpenClaw，无需重复连接。\n'
                    '本机已保存该 bot 的凭据，可直接使用；'
                    '如需换绑请扫描另一个 ClawBot 的二维码。',
                color: Colors.green,
                allowRetry: false,
              ));
          widget.onAlreadyConnected?.call(userId);
        case QrTooManyQrResetsEvent(reason: final reason):
          setState(() => _state = _Terminal(
                icon: Icons.timer_off,
                label: reason,
                color: Colors.red,
                allowRetry: true,
              ));
          widget.onExpired?.call();
        case QrLoginTimeoutEvent():
          setState(() => _state = const _Terminal(
                icon: Icons.hourglass_empty,
                label: '登录超时，请重试。',
                color: Colors.red,
                allowRetry: true,
              ));
          widget.onExpired?.call();
        case QrConfirmedEvent(account: final account):
          setState(() => _state = _Confirmed(account));
          widget.onLoggedIn?.call(account);
        case QrErrorEvent(error: final error):
          setState(() => _state = _Error('$error'));
      }
    });
  }

  void _onError(Object err) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _state = _Error(err.toString()));
    });
  }

  void _submitVerifyCode(String code) {
    _session?.submitVerifyCode(code);
    setState(() => _state = _Scanned());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Wrap in a fixed-width SizedBox so the render box always has the same
    // type and stable layout constraints regardless of which state we're in.
    // This prevents the "Cannot hit test a render box that has never been
    // laid out" error on Flutter Web (which occurs when the root widget type
    // switches between _Loading / _QrReady and mouse events arrive before
    // the new render object finishes layout).
    return SizedBox(
      width: widget.qrSize + 40,
      child: switch (_state) {
        _Loading() => SizedBox(
            height: widget.qrSize,
            child: const Center(child: CircularProgressIndicator.adaptive()),
          ),
        _QrReady(qrContent: final content) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '用微信扫码绑定 ClawBot',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              // Keyed by generation so a refreshed code always re-renders.
              _QrImageDisplay(
                key: ValueKey('qr-$_generation'),
                content: content,
                size: widget.qrSize,
              ),
              const SizedBox(height: 12),
              Text(
                '打开微信 → 扫一扫',
                style: theme.textTheme.bodySmall,
              ),
              if (_refreshNote != null) ...[
                const SizedBox(height: 6),
                Text(
                  _refreshNote!,
                  style:
                      TextStyle(fontSize: 11, color: Colors.blueGrey.shade400),
                ),
              ],
            ],
          ),
        _Refreshing(label: final label) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StatusTile(
                  icon: Icons.refresh, label: label, color: Colors.blue),
              const SizedBox(height: 12),
              const SizedBox(
                height: 28,
                width: 28,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ),
        _Scanned() => const _StatusTile(
            icon: Icons.qr_code_scanner,
            label: '已扫码，请在手机上确认登录…',
            color: Colors.orange,
          ),
        _VerifyCode(isRetry: final isRetry) => _VerifyCodeInput(
            isRetry: isRetry,
            onSubmit: _submitVerifyCode,
          ),
        _Terminal(
          icon: final icon,
          label: final label,
          color: final color,
          allowRetry: final allowRetry,
        ) =>
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StatusTile(icon: icon, label: label, color: color),
              if (allowRetry) ...[
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _startLogin,
                  child: const Text('重试'),
                ),
              ],
            ],
          ),
        _Confirmed(account: final account) => _StatusTile(
            icon: Icons.check_circle,
            label: '绑定成功！\nBot ID: ${account.botId}',
            color: Colors.green,
          ),
        _Error(message: final msg) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StatusTile(
                icon: Icons.error_outline,
                label: '出错了：$msg',
                color: Colors.red,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _startLogin,
                child: const Text('重试'),
              ),
            ],
          ),
      },
    );
  }
}

// ── Private state types ────────────────────────────────────────────────────

sealed class _UiState {
  const _UiState();
}

final class _Loading extends _UiState {
  _Loading();
}

final class _QrReady extends _UiState {
  final String qrContent;
  _QrReady(this.qrContent);
}

/// 等待中且会自动恢复的非终止状态（二维码过期 / 配对码被封锁后会自动刷新）。
final class _Refreshing extends _UiState {
  final String label;
  const _Refreshing(this.label);
}

final class _Scanned extends _UiState {
  _Scanned();
}

final class _VerifyCode extends _UiState {
  final bool isRetry;
  _VerifyCode(this.isRetry);
}

/// Terminal outcome (refresh budget exhausted / login timeout / already
/// connected). Shows a retry button when [allowRetry] is set.
final class _Terminal extends _UiState {
  final IconData icon;
  final String label;
  final Color color;
  final bool allowRetry;
  const _Terminal({
    required this.icon,
    required this.label,
    required this.color,
    this.allowRetry = false,
  });
}

/// Input field for the pairing number shown on the phone
/// (`need_verifycode`).
class _VerifyCodeInput extends StatefulWidget {
  final bool isRetry;
  final void Function(String code) onSubmit;

  const _VerifyCodeInput({required this.isRetry, required this.onSubmit});

  @override
  State<_VerifyCodeInput> createState() => _VerifyCodeInputState();
}

class _VerifyCodeInputState extends State<_VerifyCodeInput> {
  final _controller = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              widget.isRetry ? Icons.warning_amber : Icons.pin,
              size: 32,
              color: widget.isRetry ? Colors.red : Colors.orange,
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                widget.isRetry
                    ? '输入的数字不匹配，请重新输入手机微信显示的数字：'
                    : '请输入手机微信上显示的配对数字：',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: Colors.orange.shade800),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 140,
              child: TextField(
                controller: _controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  hintText: '配对数字',
                  border: OutlineInputBorder(),
                  isDense: true,
                  counterText: '',
                ),
                maxLength: 6,
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _submit,
              child: const Text('确认'),
            ),
          ],
        ),
      ],
    );
  }

  void _submit() {
    final code = _controller.text.trim();
    if (code.isEmpty) return;
    widget.onSubmit(code);
  }
}

final class _Confirmed extends _UiState {
  final ClawBotAccount account;
  _Confirmed(this.account);
}

final class _Error extends _UiState {
  final String message;
  _Error(this.message);
}

// ── QR image display ──────────────────────────────────────────────────────

/// Displays the QR code from [content].
///
/// The iLink API can return `qrcode_img_content` in two forms:
///   1. A **base64-encoded PNG** image (server pre-renders the QR code).
///   2. A **short text/URL** string the client should encode as a QR image.
///
/// This widget detects which form is used and renders accordingly.
class _QrImageDisplay extends StatelessWidget {
  final String content;
  final double size;

  const _QrImageDisplay({
    required this.content,
    required this.size,
    super.key,
  });

  /// Returns the raw PNG bytes if [content] is valid base64-encoded PNG/JPEG,
  /// otherwise returns null.
  static Uint8List? _tryDecodeImage(String content) {
    try {
      // Normalise: strip possible "data:image/...;base64," prefix, then
      // remove any whitespace/newlines that would cause base64Decode to throw.
      final raw = content.contains(',') ? content.split(',').last : content;
      final clean = raw.replaceAll(RegExp(r'\s+'), '');
      final bytes = base64Decode(clean);
      // PNG magic:  89 50 4E 47
      // JPEG magic: FF D8 FF
      if (bytes.length > 4 &&
          ((bytes[0] == 0x89 &&
                  bytes[1] == 0x50 &&
                  bytes[2] == 0x4E &&
                  bytes[3] == 0x47) ||
              (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF))) {
        return bytes;
      }
    } catch (_) {
      // Not valid base64 → fall through
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final imageBytes = _tryDecodeImage(content);

    if (imageBytes != null) {
      // Server returned a pre-rendered QR PNG – display directly.
      return Image.memory(
        imageBytes,
        width: size,
        height: size,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, err, __) => _QrError(message: err.toString()),
      );
    }

    // Content is a URL / text – render as QR code client-side.
    return QrImageView(
      data: content,
      size: size,
      backgroundColor: Colors.white,
      errorStateBuilder: (_, err) =>
          _QrError(message: err?.toString() ?? 'QR 渲染失败'),
    );
  }
}

class _QrError extends StatelessWidget {
  final String message;
  const _QrError({required this.message});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image_outlined, size: 48, color: Colors.red),
          const SizedBox(height: 8),
          SelectableText(
            'QR 码渲染失败\n$message',
            style: const TextStyle(color: Colors.red, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Helper widget ──────────────────────────────────────────────────────────

class _StatusTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _StatusTile({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 32),
        const SizedBox(width: 12),
        Flexible(
          // SelectableText so error details (e.g. `出错了：...`) can be copied.
          child: SelectableText(
            label,
            style:
                Theme.of(context).textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

// ── Convenience dialog ─────────────────────────────────────────────────────

/// Shows [QrLoginWidget] inside a Material dialog.
///
/// Returns the newly bound account, or `null` when the user cancelled or the
/// bot turned out to be already connected (`binded_redirect`). In the latter
/// case [onAlreadyConnected] fires so the caller can fall back to the stored
/// credentials.
///
/// ```dart
/// await showQrLoginDialog(context: context, clawbot: clawbot);
/// // 换绑入口可用不同标题提示用户这是"扫描另一个 bot"：
/// await showQrLoginDialog(
///   context: context,
///   clawbot: clawbot,
///   title: '换绑：扫码新的 ClawBot',
/// );
/// ```
Future<ClawBotAccount?> showQrLoginDialog({
  required BuildContext context,
  required WeixinClawbot clawbot,
  String? baseUrl,
  String title = '绑定微信 ClawBot',
  void Function(String? wechatUserId)? onAlreadyConnected,
}) {
  final completer = Completer<ClawBotAccount?>();

  void closeWith(ClawBotAccount? account) {
    if (!completer.isCompleted) completer.complete(account);
  }

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: QrLoginWidget(
        clawbot: clawbot,
        baseUrl: baseUrl,
        onLoggedIn: (account) {
          Navigator.of(ctx).pop();
          closeWith(account);
        },
        onAlreadyConnected: (userId) {
          onAlreadyConnected?.call(userId);
          // Give the user a moment to read the notice before closing.
          Timer(const Duration(milliseconds: 900), () {
            if (Navigator.of(ctx).mounted) Navigator.of(ctx).pop();
            closeWith(null);
          });
        },
        onExpired: () {
          // Widget shows a retry button; do not auto-close.
        },
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(ctx).pop();
            closeWith(null);
          },
          child: const Text('取消'),
        ),
      ],
    ),
  );

  return completer.future;
}
