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
      setState(() => _error = '打开文件选择器失败：$e');
      return;
    }
    final file = result?.files.isNotEmpty == true ? result!.files.first : null;
    if (file == null) return; // user cancelled
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      // `path` is unavailable on web, so an unreadable file is a hard error.
      setState(() => _error = '无法读取图片内容（${file.name}）');
      return;
    }
    setState(() {
      _picked = PickedImage(bytes: bytes, fileName: file.name);
      _error = null;
    });
  }

  Future<void> _send() async {
    final picked = _picked;
    if (picked == null || _sending) return;
    final caption = _captionController.text.trim();

    setState(() {
      _sending = true;
      _error = null;
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
      setState(() => _error = '发送失败：${result.error}');
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
            style: TextStyle(fontSize: 12, color: Colors.red.shade700),
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
