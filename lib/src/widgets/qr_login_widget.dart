/// Flutter widgets for the QR login flow.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models.dart';
import '../qr_login.dart';
import '../weixin_clawbot.dart';

/// A self-contained widget that shows the WeChat QR-code binding UI.
///
/// Embed inside any screen or dialog. It handles the full flow:
/// fetching the QR code → displaying it → polling → success / expired.
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

  /// Called when the QR code expires.
  final VoidCallback? onExpired;

  /// Override the API base URL (optional).
  final String? baseUrl;

  /// Size of the rendered QR image in logical pixels.
  final double qrSize;

  const QrLoginWidget({
    super.key,
    required this.clawbot,
    this.onLoggedIn,
    this.onExpired,
    this.baseUrl,
    this.qrSize = 240,
  });

  @override
  State<QrLoginWidget> createState() => _QrLoginWidgetState();
}

class _QrLoginWidgetState extends State<QrLoginWidget> {
  _UiState _state = _Loading();
  QrLoginSession? _session;

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
    setState(() => _state = _Loading());

    final session = await widget.clawbot.startQrLoginSession(
      baseUrl: widget.baseUrl,
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
        case QrReadyEvent():
          setState(() => _state = _QrReady(event.qrContent));
        case QrScannedEvent():
          setState(() => _state = _Scanned());
        case QrVerifyCodeRequiredEvent():
          setState(() => _state = _VerifyCode(event.isRetry));
        case QrVerifyCodeBlockedEvent():
          setState(() => _state = const _Terminal(
                icon: Icons.block,
                label: '配对码错误次数过多，请稍后重试',
                color: Colors.red,
                allowRetry: true,
              ));
        case QrAlreadyBoundEvent():
          setState(() => _state = const _Terminal(
                icon: Icons.link,
                label: '该 ClawBot 已绑定过（凭据已在本机）。\n请先在应用内使用已保存账号，或解绑后重新扫码。',
                color: Colors.orange,
              ));
        case QrConfirmedEvent():
          setState(() => _state = _Confirmed(event.account));
          widget.onLoggedIn?.call(event.account);
        case QrExpiredEvent():
          setState(() => _state = _Expired());
          widget.onExpired?.call();
        case QrErrorEvent():
          setState(() => _state = _Error(event.error.toString()));
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
              _QrImageDisplay(content: content, size: widget.qrSize),
              const SizedBox(height: 12),
              Text(
                '打开微信 → 扫一扫',
                style: theme.textTheme.bodySmall,
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
        _Expired() => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _StatusTile(
                icon: Icons.timer_off,
                label: '二维码已过期',
                color: Colors.red,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _startLogin,
                child: const Text('重新获取'),
              ),
            ],
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

final class _Scanned extends _UiState {
  _Scanned();
}

final class _VerifyCode extends _UiState {
  final bool isRetry;
  _VerifyCode(this.isRetry);
}

/// Terminal outcome (verify-code blocked / already bound). Shows a retry
/// button when [allowRetry] is set.
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

final class _Expired extends _UiState {
  _Expired();
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

  const _QrImageDisplay({required this.content, required this.size});

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
/// ```dart
/// await showQrLoginDialog(context: context, clawbot: clawbot);
/// ```
Future<ClawBotAccount?> showQrLoginDialog({
  required BuildContext context,
  required WeixinClawbot clawbot,
  String? baseUrl,
}) {
  final completer = Completer<ClawBotAccount?>();

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('绑定微信 ClawBot'),
      content: QrLoginWidget(
        clawbot: clawbot,
        baseUrl: baseUrl,
        onLoggedIn: (account) {
          Navigator.of(ctx).pop();
          if (!completer.isCompleted) completer.complete(account);
        },
        onExpired: () {
          // Widget shows a retry button; do not auto-close.
        },
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(ctx).pop();
            if (!completer.isCompleted) completer.complete(null);
          },
          child: const Text('取消'),
        ),
      ],
    ),
  );

  return completer.future;
}
