/// Data models for the WeChat iLink Bot API.
library;

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

  /// Unknown or unrecognised status string.
  unknown,
}

/// Response from `GET /ilink/bot/get_qrcode_status`.
class QrStatusResponse {
  final QrLoginStatus status;

  /// Bearer token for the bot. Populated when [status] == [QrLoginStatus.confirmed].
  final String? botToken;

  /// Bot's iLink user ID.
  final String? ilinkBotId;

  /// Bound WeChat user's iLink user ID.
  final String? ilinkUserId;

  /// API base URL returned by the server (may differ from the default).
  final String? baseUrl;

  const QrStatusResponse({
    required this.status,
    this.botToken,
    this.ilinkBotId,
    this.ilinkUserId,
    this.baseUrl,
  });

  factory QrStatusResponse.fromJson(Map<String, dynamic> json) {
    final rawStatus = json['status'] as String? ?? '';
    final status = switch (rawStatus) {
      'wait' => QrLoginStatus.wait,
      'scaned' => QrLoginStatus.scanned,
      'confirmed' => QrLoginStatus.confirmed,
      'expired' => QrLoginStatus.expired,
      _ => QrLoginStatus.unknown,
    };

    return QrStatusResponse(
      status: status,
      botToken: json['bot_token'] as String?,
      ilinkBotId: json['ilink_bot_id'] as String?,
      ilinkUserId: json['ilink_user_id'] as String?,
      baseUrl: json['baseurl'] as String?,
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

  /// Raw JSON for unsupported item types (image, file, video).
  final Map<String, dynamic>? raw;

  const MessageItem({required this.type, this.text, this.voiceText, this.raw});

  factory MessageItem.fromJson(Map<String, dynamic> json) {
    final type = MessageItemType.fromInt(json['type'] as int? ?? 0);
    return MessageItem(
      type: type,
      text: (json['text_item'] as Map<String, dynamic>?)?['text'] as String?,
      voiceText:
          (json['voice_item'] as Map<String, dynamic>?)?['text'] as String?,
      raw: json,
    );
  }
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
