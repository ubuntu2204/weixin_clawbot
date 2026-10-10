/// Data models for the WeChat iLink Bot API.
library;

import 'dart:convert';
import 'dart:typed_data';

// ─── Login / QR Code ───────────────────────────────────────────────────────

/// Response from `GET /ilink/bot/get_bot_qrcode`.
class QrCodeResponse {
  /// Opaque QR code identifier used for polling.
  final String qrCode;

  /// Text content that should be rendered as a QR image and scanned by WeChat.
  final String qrCodeImgContent;

  const QrCodeResponse({required this.qrCode, required this.qrCodeImgContent});

  factory QrCodeResponse.fromJson(Map<String, dynamic> json) {
    return QrCodeResponse(
      qrCode: json['qrcode'] as String? ?? '',
      qrCodeImgContent: json['qrcode_img_content'] as String? ?? '',
    );
  }
}

/// Possible states during QR login polling.
enum QrLoginStatus {
  /// Waiting for user to scan.
  wait,

  /// User has scanned but not yet confirmed on their phone.
  scanned,

  /// Login confirmed – credentials are available.
  confirmed,

  /// QR code has expired; re-fetch a new one.
  expired,

  /// Server asks the client to switch the polling host (IDC redirect).
  /// See [QrStatusResponse.redirectHost].
  scanedButRedirect,

  /// The phone displays a pairing number that must be submitted back via
  /// `verify_code` on the next status poll.
  needVerifyCode,

  /// The verify code was wrong too many times; polling is paused server-side.
  verifyCodeBlocked,

  /// The scanned bot is already bound; no new credentials will be issued.
  bindedRedirect,

  /// Unknown or unrecognised status string.
  unknown,
}

/// Response from `GET /ilink/bot/get_qrcode_status`.
class QrStatusResponse {
  final QrLoginStatus status;

  /// Raw status string as sent by the server (useful for diagnostics).
  final String? rawStatus;

  /// Bearer token for the bot. Populated when [status] == [QrLoginStatus.confirmed].
  final String? botToken;

  /// Bot's iLink user ID.
  final String? ilinkBotId;

  /// Bound WeChat user's iLink user ID.
  final String? ilinkUserId;

  /// API base URL returned by the server (may differ from the default).
  final String? baseUrl;

  /// New polling host when [status] == [QrLoginStatus.scanedButRedirect].
  final String? redirectHost;

  const QrStatusResponse({
    required this.status,
    this.rawStatus,
    this.botToken,
    this.ilinkBotId,
    this.ilinkUserId,
    this.baseUrl,
    this.redirectHost,
  });

  factory QrStatusResponse.fromJson(Map<String, dynamic> json) {
    final rawStatus = json['status'] as String? ?? '';
    final status = switch (rawStatus) {
      'wait' => QrLoginStatus.wait,
      'scaned' => QrLoginStatus.scanned,
      'confirmed' => QrLoginStatus.confirmed,
      'expired' => QrLoginStatus.expired,
      'scaned_but_redirect' => QrLoginStatus.scanedButRedirect,
      'need_verifycode' => QrLoginStatus.needVerifyCode,
      'verify_code_blocked' => QrLoginStatus.verifyCodeBlocked,
      'binded_redirect' => QrLoginStatus.bindedRedirect,
      _ => QrLoginStatus.unknown,
    };

    return QrStatusResponse(
      status: status,
      rawStatus: rawStatus,
      botToken: json['bot_token'] as String?,
      ilinkBotId: json['ilink_bot_id'] as String?,
      ilinkUserId: json['ilink_user_id'] as String?,
      baseUrl: json['baseurl'] as String?,
      redirectHost: json['redirect_host'] as String?,
    );
  }
}

// ─── Account ───────────────────────────────────────────────────────────────

/// Persisted bot account credentials.
///
/// Obtained from [QrConfirmedEvent.account] after a successful QR login and
/// automatically stored by [WeixinClawbot] via [AccountStore].
class ClawBotAccount {
  /// Unique account identifier – same value as [botId].
  final String id;

  /// Bearer token used in the `Authorization` header for all API calls.
  final String token;

  /// iLink API base URL assigned by the server.
  /// May differ from the default `https://ilinkai.weixin.qq.com` for some accounts.
  final String baseUrl;

  /// Bot's own iLink user ID, used as `from_user_id` when sending messages.
  final String botId;

  /// iLink user ID of the WeChat user who scanned the QR code during binding.
  /// Populated at login time from the server's `ilink_user_id` field.
  /// Use this as the default `toUserId` for proactive sends.
  final String? defaultTo;

  /// The most-recently-seen `context_token` for [defaultTo].
  /// Required for proactive push notifications; automatically updated by
  /// [WeixinClawbot.connect] as inbound messages arrive.
  final String? contextToken;

  const ClawBotAccount({
    required this.id,
    required this.token,
    required this.baseUrl,
    required this.botId,
    this.defaultTo,
    this.contextToken,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'token': token,
        'baseUrl': baseUrl,
        'botId': botId,
        if (defaultTo != null) 'defaultTo': defaultTo,
        if (contextToken != null) 'contextToken': contextToken,
      };

  factory ClawBotAccount.fromJson(Map<String, dynamic> json) {
    return ClawBotAccount(
      id: json['id'] as String,
      token: json['token'] as String,
      baseUrl: json['baseUrl'] as String,
      botId: json['botId'] as String,
      defaultTo: json['defaultTo'] as String?,
      contextToken: json['contextToken'] as String?,
    );
  }

  ClawBotAccount copyWith({String? contextToken, String? defaultTo}) {
    return ClawBotAccount(
      id: id,
      token: token,
      baseUrl: baseUrl,
      botId: botId,
      defaultTo: defaultTo ?? this.defaultTo,
      contextToken: contextToken ?? this.contextToken,
    );
  }
}

// ─── Messages ──────────────────────────────────────────────────────────────

/// Type discriminator for a [MessageItem].
enum MessageItemType {
  text(1),
  image(2),
  voice(3),
  file(4),
  video(5),
  unknown(0);

  final int value;
  const MessageItemType(this.value);

  static MessageItemType fromInt(int v) => MessageItemType.values.firstWhere(
        (e) => e.value == v,
        orElse: () => MessageItemType.unknown,
      );
}

/// One segment inside a [WeixinMessage].
class MessageItem {
  final MessageItemType type;

  /// Non-null when [type] == [MessageItemType.text].
  final String? text;

  /// Non-null when [type] == [MessageItemType.voice] (speech-to-text result).
  final String? voiceText;

  /// Non-null when [type] == [MessageItemType.image]. Contains the CDN
  /// download parameters and AES key needed to fetch and decrypt the picture.
  final ImageItemData? image;

  /// Raw JSON for unsupported item types (file, video).
  final Map<String, dynamic>? raw;

  const MessageItem({
    required this.type,
    this.text,
    this.voiceText,
    this.image,
    this.raw,
  });

  factory MessageItem.fromJson(Map<String, dynamic> json) {
    final type = MessageItemType.fromInt(json['type'] as int? ?? 0);
    final rawImage = json['image_item'] as Map<String, dynamic>?;
    return MessageItem(
      type: type,
      text: (json['text_item'] as Map<String, dynamic>?)?['text'] as String?,
      voiceText:
          (json['voice_item'] as Map<String, dynamic>?)?['text'] as String?,
      image: rawImage == null ? null : ImageItemData.fromJson(rawImage),
      raw: json,
    );
  }
}

/// Media descriptor shared by CDN-backed message items (image/file/video).
///
/// Mirrors the `CDNMedia` structure of the official openclaw-weixin plugin.
class CdnMedia {
  /// Opaque parameter used to build the CDN download URL:
  /// `{cdnBaseUrl}/download?encrypted_query_param=<this value>`.
  final String? encryptQueryParam;

  /// AES key as sent by the server (usually base64). See
  /// [resolveAesKeyBytes] in [ImageItemData] for decoding rules.
  final String? aesKey;

  /// Optional pre-built download URL. Takes precedence over
  /// [encryptQueryParam] when present.
  final String? fullUrl;

  /// `1` = AES-128-ECB encrypted payload.
  final int? encryptType;

  const CdnMedia({
    this.encryptQueryParam,
    this.aesKey,
    this.fullUrl,
    this.encryptType,
  });

  factory CdnMedia.fromJson(Map<String, dynamic> json) {
    return CdnMedia(
      encryptQueryParam: json['encrypt_query_param'] as String?,
      aesKey: json['aes_key'] as String?,
      fullUrl: json['full_url'] as String?,
      encryptType: (json['encrypt_type'] as num?)?.toInt(),
    );
  }
}

/// Payload of an image message item (`type == 2`).
class ImageItemData {
  final CdnMedia? media;

  /// Top-level AES key in hex form (seen on inbound image items). When
  /// present it takes precedence over [media.aesKey].
  final String? aesKeyHex;

  /// Ciphertext size in bytes (AES-ECB padded).
  final int? midSize;

  const ImageItemData({this.media, this.aesKeyHex, this.midSize});

  factory ImageItemData.fromJson(Map<String, dynamic> json) {
    return ImageItemData(
      media: json['media'] == null
          ? null
          : CdnMedia.fromJson(json['media'] as Map<String, dynamic>),
      aesKeyHex: json['aeskey'] as String?,
      midSize: (json['mid_size'] as num?)?.toInt(),
    );
  }

  /// Whether this item carries enough information to be downloaded.
  bool get isDownloadable =>
      (media?.encryptQueryParam?.isNotEmpty ?? false) ||
      (media?.fullUrl?.isNotEmpty ?? false);

  /// Resolves the raw 16-byte AES key from either [aesKeyHex] or
  /// [media.aesKey], or `null` when the item carries no key (plain payload).
  ///
  /// Mirrors the official openclaw-weixin key handling:
  /// - top-level `aeskey` is a 32-char hex string;
  /// - `media.aes_key` is base64 of either the raw 16 bytes (images) or of a
  ///   32-char hex string (files/voice/videos).
  ///
  /// An unusable top-level hex string (odd length, non-hex characters, or not
  /// exactly 16 decoded bytes) falls back to [media.aesKey] instead of
  /// failing the whole download — same observable behaviour as the official
  /// plugin, where `Buffer.from(aeskey, 'hex')` yields an empty buffer and the
  /// plain-download path is taken.
  Uint8List? resolveAesKeyBytes() {
    final hex = aesKeyHex;
    if (hex != null && hex.isNotEmpty) {
      try {
        final bytes = hexToBytes(hex);
        if (bytes.length == 16) return bytes;
      } on FormatException {
        // fall through to media.aes_key
      }
    }
    final base64Key = media?.aesKey;
    if (base64Key == null || base64Key.isEmpty) return null;
    try {
      final decoded = base64Decode(base64Key);
      if (decoded.length == 16) return Uint8List.fromList(decoded);
      final ascii = String.fromCharCodes(decoded);
      if (decoded.length == 32 && RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(ascii)) {
        return hexToBytes(ascii);
      }
    } on FormatException {
      return null;
    }
    return null;
  }
}

/// Decodes a hex string into bytes. Throws [FormatException] on odd-length
/// input or invalid characters.
Uint8List hexToBytes(String hex) {
  final cleaned = hex.replaceAll(RegExp(r'\s'), '');
  if (cleaned.length.isOdd) {
    throw const FormatException('hex string has odd length');
  }
  final out = Uint8List(cleaned.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final hi = _hexDigit(cleaned.codeUnitAt(i * 2));
    final lo = _hexDigit(cleaned.codeUnitAt(i * 2 + 1));
    out[i] = (hi << 4) | lo;
  }
  return out;
}

int _hexDigit(int codeUnit) {
  // '0'..'9'
  if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30;
  // 'A'..'F'
  if (codeUnit >= 0x41 && codeUnit <= 0x46) return codeUnit - 0x41 + 10;
  // 'a'..'f'
  if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x61 + 10;
  throw FormatException('invalid hex digit: ${String.fromCharCode(codeUnit)}');
}

/// A WeChat iLink message (inbound or outbound).
class WeixinMessage {
  final int seq;
  final int messageId;
  final String fromUserId;
  final String toUserId;
  final String clientId;

  /// Unix time in milliseconds.
  final int createTimeMs;

  /// Message origin: `1` = sent by a real WeChat user, `2` = sent by the bot.
  /// Use the convenience getter [isFromUser] instead of comparing directly.
  final int messageType;

  /// Streaming state: `0` = new/complete, `1` = generating (streaming),
  /// `2` = generation finished. For non-streaming bots this is always `2`.
  final int messageState;

  /// Opaque token required to send a reply that triggers a WeChat notification.
  /// The [MessagePoller] caches this value per sender automatically; you do not
  /// need to manage it manually.
  final String? contextToken;

  /// Ordered list of content segments. Most messages contain a single item.
  final List<MessageItem> items;

  const WeixinMessage({
    required this.seq,
    required this.messageId,
    required this.fromUserId,
    required this.toUserId,
    required this.clientId,
    required this.createTimeMs,
    required this.messageType,
    required this.messageState,
    this.contextToken,
    required this.items,
  });

  factory WeixinMessage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['item_list'] as List<dynamic>? ?? [];
    return WeixinMessage(
      seq: json['seq'] as int? ?? 0,
      messageId: json['message_id'] as int? ?? 0,
      fromUserId: json['from_user_id'] as String? ?? '',
      toUserId: json['to_user_id'] as String? ?? '',
      clientId: json['client_id'] as String? ?? '',
      createTimeMs: json['create_time_ms'] as int? ?? 0,
      messageType: json['message_type'] as int? ?? 0,
      messageState: json['message_state'] as int? ?? 0,
      contextToken: json['context_token'] as String?,
      items: rawItems
          .map((e) => MessageItem.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Returns the first text or voice-to-text content from [items], or `null`
  /// if the message contains no text segment (e.g. image-only messages).
  String? get textContent {
    for (final item in items) {
      if (item.type == MessageItemType.text && item.text != null) {
        return item.text;
      }
      if (item.type == MessageItemType.voice && item.voiceText != null) {
        return item.voiceText;
      }
    }
    return null;
  }

  /// `true` when the message was sent by a real WeChat user (`messageType == 1`).
  /// `false` for messages sent by the bot itself (e.g. echoed outbound sends).
  bool get isFromUser => messageType == 1;

  /// First image segment in [items], or `null` for non-image messages.
  ImageItemData? get imageItem {
    for (final item in items) {
      if (item.image != null) return item.image;
    }
    return null;
  }
}

/// Long-poll response from `POST /ilink/bot/getupdates`.
class GetUpdatesResponse {
  final int ret;
  final int errCode;
  final String errMsg;
  final List<WeixinMessage> messages;
  final String getUpdatesBuf;
  final int longPollingTimeoutMs;

  const GetUpdatesResponse({
    required this.ret,
    required this.errCode,
    required this.errMsg,
    required this.messages,
    required this.getUpdatesBuf,
    required this.longPollingTimeoutMs,
  });

  bool get isOk => ret == 0 && errCode == 0;

  factory GetUpdatesResponse.fromJson(Map<String, dynamic> json) {
    final rawMsgs = json['msgs'] as List<dynamic>? ?? [];
    return GetUpdatesResponse(
      ret: json['ret'] as int? ?? 0,
      errCode: json['errcode'] as int? ?? 0,
      errMsg: json['errmsg'] as String? ?? '',
      messages: rawMsgs
          .map((e) => WeixinMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
      getUpdatesBuf: json['get_updates_buf'] as String? ?? '',
      longPollingTimeoutMs: json['longpolling_timeout_ms'] as int? ?? 0,
    );
  }
}

// ─── Send result ───────────────────────────────────────────────────────────

/// Result of a send-message call.
class SendResult {
  final bool ok;
  final String to;
  final String clientId;
  final String? error;

  const SendResult({
    required this.ok,
    required this.to,
    required this.clientId,
    this.error,
  });

  @override
  String toString() =>
      ok ? 'SendResult(ok, to=$to)' : 'SendResult(error=$error)';
}
