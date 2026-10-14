/// Flutter widget + helpers for **sending an image to the bound WeChat user**
/// through a [WeixinClawbot].
///
/// Like `qr_login_widget.dart`, this whole file is meant to be **copied into
/// your own app** — it only depends on `flutter`, `file_picker` and the public
/// `weixin_clawbot` API.
///
/// The wire protocol is intentionally NOT reimplemented here: every upload
/// goes through [WeixinClawbot.sendImage], which mirrors the official
/// Tencent/openclaw-weixin send pipeline (`getuploadurl` → AES-128-ECB +
/// PKCS#7 upload to the WeChat CDN → `sendmessage` with an `image_item`). That
/// keeps a single source of truth for the protocol, so any host — this example
/// or another program that copies the widget — behaves identically.
///
/// ## Usage
///
/// ```dart
/// // 1. A ready-made dialog that returns what was sent:
/// final outcome = await showImageSendDialog(
///   context: context,
///   clawbot: clawbot,
///   toUserId: account.defaultTo!,
///   accountId: account.id,
/// );
/// if (outcome != null && outcome.result.ok) {
///   // outcome.image.bytes 是原图，可用于本地乐观回显
/// }
///
/// // 2. Or embed the widget inside your own panel:
/// ImageSendWidget(
///   clawbot: clawbot,
///   toUserId: account.defaultTo!,
///   onSent: (outcome) => debugPrint('已发送 ${outcome.image.fileName}'),
/// )
/// ```
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:weixin_clawbot/weixin_clawbot.dart';

/// 把 `weixin_clawbot` 返回的协议 / 英文错误翻译成可操作的中文提示。
///
/// 入参通常是 [SendResult.error]。示例的**文本发送**与**图片发送**都用它，保证两处
/// 提示一致；未知错误原样返回，绝不吞掉诊断信息。
///
/// 最常见的一种：`sendmessage ret=-2 errmsg=prepare failed (rate limited, try
/// again later)` —— 服务端还没为该会话就绪，往往是因为**微信用户近期没主动给这个
/// bot 发过消息**（bot 无法凭空主动推送），叠加 `-2` 频率限制。
String describeWeixinError(String raw) {
  final e = raw.toLowerCase();

  // ret=-2 + prepare failed：会话未就绪（微信用户没先说话），也可能叠加频率限制。
  if (e.contains('prepare failed')) {
    return '该微信用户近期没有给这个 ClawBot 发过消息，服务端会话还没就绪'
        '（ret=-2，prepare failed）。\n'
        'ClawBot 不能凭空主动推送——请让对方先在微信里给机器人发一条消息，系统会'
        '自动记住这次会话，之后再发送即可。若对方刚发过仍失败，多半是同时触发了'
        '频率限制（约 7 条 / 5 分钟），稍等 5–10 秒再重试。';
  }

  // 纯频率限制（ret=-2）。
  if (e.contains('ret=-2') ||
      e.contains('rate limited') ||
      e.contains('try again later')) {
    return '发送过于频繁，已触发服务端频率限制（每个 bot 约 7 条 / 5 分钟），'
        '请稍等 5–10 秒后重试。';
  }

  // bot_token 失效（-14），账号按官方 session-guard 冷却一小时。
  if (e.contains('ret=-14') ||
      e.contains('stale bot token') ||
      e.contains('session paused')) {
    return '登录会话已过期（bot_token 失效，错误码 -14），该账号将冷却约一小时。'
        '请重新扫码绑定后再发送。';
  }

  if (e.contains('no recipient')) {
    return '缺少收件人：请填写收件人 ID，或让对方先发一条消息由系统自动获取。';
  }

  if (e.contains('no active connection') || e.contains('connect()')) {
    return '尚未连接账号：请先扫码绑定并连接后再发送。';
  }

  // 出站媒体上传失败（Web 端多为 CORS 代理未启动）。
  if (e.contains('x-encrypted-param') || e.contains('cdn upload')) {
    return '图片 / 文件上传失败：Web 端请确认本地 CORS 代理已启动'
        '（dart run bin/proxy_server.dart）后重试。';
  }

  return raw; // 未知错误原样展示，避免丢失信息
}

/// An image selected on the client, before (or after) it is uploaded.
class PickedImage {
  /// The original, unencrypted picture bytes (JPEG / PNG / GIF / …). This is
  /// exactly what [WeixinClawbot.sendImage] encrypts and uploads to the CDN.
  final Uint8List bytes;

  /// Display name chosen by the user (may be empty on some platforms).
  final String fileName;

  const PickedImage({required this.bytes, this.fileName = ''});

  /// Human-readable size, e.g. `1.4 MB`.
  String get readableSize {
    const kb = 1024;
    const mb = kb * 1024;
    final n = bytes.length;
    if (n >= mb) return '${(n / mb).toStringAsFixed(1)} MB';
    if (n >= kb) return '${(n / kb).toStringAsFixed(0)} KB';
    return '$n B';
  }
}

/// Result of a completed send from [ImageSendWidget] / [showImageSendDialog].
class ImageSendOutcome {
  /// The image that was sent (bytes kept for optimistic local echo).
  final PickedImage image;

  /// The caption the user typed, if any (sent as a separate text message by
  /// the SDK, matching the official one-request-per-item behaviour).
  final String? caption;

  /// The raw SDK result — check [SendResult.ok] for success.
  final SendResult result;

  const ImageSendOutcome({
    required this.image,
    required this.result,
    this.caption,
  });
}

/// Picks a local image and sends it through [WeixinClawbot.sendImage].
///
/// Self-contained: it manages selection, preview, an optional caption, upload
/// progress and error reporting on its own. It never throws for a failed send —
/// the failure is shown inline and reported through [onSent] with
/// [SendResult.ok] `false`.
///
/// On Flutter Web remember to construct the [clawbot] with a `proxyBaseUrl`
/// pointing at the bundled CORS proxy; outbound CDN uploads on the web route
/// through `<proxyBaseUrl>/cdn` (and `upload_full_url` via `/cdnfull`) exactly
/// like inbound downloads.
class ImageSendWidget extends StatefulWidget {
  final WeixinClawbot clawbot;

  /// Recipient iLink user id — usually `account.defaultTo` or the inbound
  /// message's `fromUserId`.
  final String toUserId;

  /// Which connected account to send from (defaults to the active one).
  final String? accountId;

  /// Fires after every send attempt (success **or** failure). The dialog uses
  /// it to close; embedded usages can refresh their chat list.
  final void Function(ImageSendOutcome outcome)? onSent;

  /// Optional pre-selected image (e.g. pasted / dropped by the host). When set
  /// the widget shows the preview immediately.
  final PickedImage? initialImage;

  const ImageSendWidget({
    super.key,
    required this.clawbot,
    required this.toUserId,
    this.accountId,
    this.onSent,
    this.initialImage,
  });

  @override
  State<ImageSendWidget> createState() => _ImageSendWidgetState();
}

class _ImageSendWidgetState extends State<ImageSendWidget> {
  PickedImage? _picked;
  bool _sending = false;
  String? _error;

  /// 当 [_error] 是翻译后的中文提示时，这里保留服务端原始错误供排查（小字灰色）。
  String? _errorRaw;
  final _captionController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _picked = widget.initialImage;
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  /// Opens the platform file picker (browser file input on the web) and reads
  /// the image bytes into memory.
  Future<void> _pick() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true, // required on web — bytes are the only payload there
        allowMultiple: false,
        dialogTitle: '选择要发送的图片',
      );
    } catch (e) {
      setState(() {
        _error = '打开文件选择器失败：$e';
        _errorRaw = null;
      });
      return;
    }
    final file = result?.files.isNotEmpty == true ? result!.files.first : null;
    if (file == null) return; // user cancelled
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      // `path` is unavailable on web, so an unreadable file is a hard error.
      setState(() {
        _error = '无法读取图片内容（${file.name}）';
        _errorRaw = null;
      });
      return;
    }
    setState(() {
      _picked = PickedImage(bytes: bytes, fileName: file.name);
      _error = null;
      _errorRaw = null;
    });
  }

  Future<void> _send() async {
    final picked = _picked;
    if (picked == null || _sending) return;
    final caption = _captionController.text.trim();

    setState(() {
      _sending = true;
      _error = null;
      _errorRaw = null;
    });

    // All protocol work lives in the SDK — this widget just hands it the
    // bytes, exactly like any other caller ("供其他程序调用").
    final result = await widget.clawbot.sendImage(
      bytes: picked.bytes,
      toUserId: widget.toUserId,
      accountId: widget.accountId,
      caption: caption.isEmpty ? null : caption,
    );

    if (!mounted) return;
    setState(() => _sending = false);

    if (!result.ok) {
      // 把协议错误翻译成中文提示，同时保留原始信息供排查。
      final raw = result.error ?? '未知错误';
      final friendly = describeWeixinError(raw);
      setState(() {
        _error = '发送失败：$friendly';
        _errorRaw = friendly == raw ? null : raw;
      });
    } else {
      _captionController.clear();
    }
    widget.onSent?.call(ImageSendOutcome(
      image: picked,
      result: result,
      caption: caption.isEmpty ? null : caption,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final picked = _picked;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 选择 / 预览区
        InkWell(
          onTap: _sending ? null : _pick,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 140),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: picked == null
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.add_photo_alternate_outlined,
                          size: 42, color: Colors.grey),
                      const SizedBox(height: 8),
                      Text('点击选择图片',
                          style: TextStyle(color: Colors.grey.shade700)),
                      const SizedBox(height: 4),
                      Text(
                        '支持 JPEG / PNG / GIF，经微信 CDN 加密上传',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade500),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      Image.memory(
                        picked.bytes,
                        fit: BoxFit.contain,
                        height: 160,
                        errorBuilder: (_, __, ___) => const SizedBox(
                          height: 120,
                          child: Center(
                              child: Text('[图片]（无法预览）',
                                  style: TextStyle(color: Colors.grey))),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${picked.fileName} · ${picked.readableSize}',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: _sending ? null : _pick,
                              icon: const Icon(Icons.swap_horiz, size: 16),
                              label: const Text('重选'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 8),

        // 可选说明（SDK 会作为独立文本消息发出，与官方一致）
        TextField(
          controller: _captionController,
          enabled: !_sending,
          maxLines: 2,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: '图片说明（可选，作为一条文本消息发送）',
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            isDense: true,
          ),
          style: const TextStyle(fontSize: 13),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          SelectableText(
            _error!,
            style: TextStyle(
                fontSize: 12, color: Colors.red.shade700, height: 1.4),
          ),
        ],
        if (_errorRaw != null) ...[
          const SizedBox(height: 4),
          SelectableText(
            '原始信息：$_errorRaw',
            style: TextStyle(
              fontSize: 10,
              color: Colors.grey.shade600,
              fontFamily: 'monospace',
            ),
          ),
        ],
        const SizedBox(height: 12),

        // 发送
        FilledButton.icon(
          onPressed: (picked == null || _sending) ? null : _send,
          icon: _sending
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.send),
          label: Text(_sending ? '上传发送中…' : '发送图片'),
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
          ),
        ),
      ],
    );
  }
}

// ── Convenience dialog ─────────────────────────────────────────────────────

/// Shows [ImageSendWidget] inside a Material dialog and returns the outcome.
///
/// Returns `null` when the user cancels without sending; otherwise an
/// [ImageSendOutcome] whose [ImageSendOutcome.result] carries success/failure.
/// The returned [ImageSendOutcome.image.bytes] let the caller echo the sent
/// picture locally (the server does not resend the bot's own messages over the
/// long-poll, same as the official plugin).
Future<ImageSendOutcome?> showImageSendDialog({
  required BuildContext context,
  required WeixinClawbot clawbot,
  required String toUserId,
  String? accountId,
  String title = '发送图片给微信',
}) {
  final completer = Completer<ImageSendOutcome?>();

  void closeWith(ImageSendOutcome? outcome) {
    if (!completer.isCompleted) completer.complete(outcome);
  }

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 360,
        child: ImageSendWidget(
          clawbot: clawbot,
          toUserId: toUserId,
          accountId: accountId,
          onSent: (outcome) {
            // Keep the dialog open on failure so the user can retry; only
            // auto-close after a successful send.
            if (outcome.result.ok) {
              Navigator.of(ctx).pop();
              closeWith(outcome);
            }
          },
        ),
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
