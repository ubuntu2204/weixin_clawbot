/// Data models for the WeChat iLink Bot API.
///
/// The type surface mirrors the official openclaw-weixin protocol types
/// (`src/api/types.ts`) one-to-one: same wire field names, same numeric
/// constants, and the same lossless handling of uint64 identifiers.
library;

import 'dart:convert';
import 'dart:typed_data';

// ─── Protocol constants (mirror official `types.ts`) ───────────────────────

/// proto: `MessageType` — who produced the message.
enum MessageType {
  none(0),
  user(1),
  bot(2);

  final int value;
  const MessageType(this.value);

  static MessageType fromInt(int? v) => MessageType.values.firstWhere(
        (e) => e.value == v,
        orElse: () => MessageType.none,
      );
}

/// proto: `MessageState` — streaming state of a message.
enum MessageState {
  /// `0` — new / complete (non-streaming bots always report this).
  fresh(0),

  /// `1` — generating (a streaming chunk is still arriving).
  generating(1),

  /// `2` — generation finished.
  finish(2);

  final int value;
  const MessageState(this.value);

  static MessageState fromInt(int? v) => MessageState.values.firstWhere(
        (e) => e.value == v,
        orElse: () => MessageState.fresh,
      );
}

/// Type discriminator for a [MessageItem] (official `MessageItemType`).
enum MessageItemType {
  text(1),
  image(2),
  voice(3),
  file(4),
  video(5),
  toolCallStart(11),
  toolCallResult(12),
  unknown(0);

  final int value;
  const MessageItemType(this.value);

  static MessageItemType fromInt(int? v) => MessageItemType.values.firstWhere(
        (e) => e.value == v,
        orElse: () => MessageItemType.unknown,
      );
}

/// proto: `UploadMediaType` — `getuploadurl.media_type`.
enum UploadMediaType {
  image(1),
  video(2),
  file(3),
  voice(4);

  final int value;
  const UploadMediaType(this.value);
}

/// Official `TypingStatus`: `1` = typing, `2` = cancel typing.
enum TypingStatus {
  typing(1),
  cancel(2);

  final int value;
  const TypingStatus(this.value);
}

// ─── Login / QR Code ───────────────────────────────────────────────────────

/// Response from `POST /ilink/bot/get_bot_qrcode`.
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

  /// The scanned bot is already bound to *this* client.
  ///
  /// The official plugin treats this as a **successful** outcome
  /// (`alreadyConnected: true`) — local credentials stay valid and no new
  /// credentials are issued. It never reads `bot_token` from this response.
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
/// automatically stored by [WeixinClawbot] via [AccountStore]. Mirrors the
/// official `WeixinAccountData` (`token` / `baseUrl` / `userId` / `savedAt`).
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
  /// Official name: `userId`. Populated at login from `ilink_user_id`.
  /// Use this as the default `toUserId` for proactive sends.
  final String? defaultTo;

  /// The most-recently-seen `context_token` for [defaultTo].
  /// Required for proactive push notifications; automatically updated by
  /// [WeixinClawbot.connect] as inbound messages arrive.
  final String? contextToken;

  /// When these credentials were stored (Unix ms). Used to order
  /// `local_token_list` newest-first, like the official account index.
  final int? savedAtMs;

  const ClawBotAccount({
    required this.id,
    required this.token,
    required this.baseUrl,
    required this.botId,
    this.defaultTo,
    this.contextToken,
    this.savedAtMs,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'token': token,
        'baseUrl': baseUrl,
        'botId': botId,
        if (defaultTo != null) 'defaultTo': defaultTo,
        if (contextToken != null) 'contextToken': contextToken,
        if (savedAtMs != null) 'savedAtMs': savedAtMs,
      };

  factory ClawBotAccount.fromJson(Map<String, dynamic> json) {
    return ClawBotAccount(
      id: json['id'] as String,
      token: json['token'] as String,
      baseUrl: json['baseUrl'] as String? ?? '',
      botId: json['botId'] as String,
      defaultTo: json['defaultTo'] as String?,
      contextToken: json['contextToken'] as String?,
      savedAtMs: (json['savedAtMs'] as num?)?.toInt(),
    );
  }

  ClawBotAccount copyWith({
    String? contextToken,
    String? defaultTo,
    int? savedAtMs,
  }) {
    return ClawBotAccount(
      id: id,
      token: token,
      baseUrl: baseUrl,
      botId: botId,
      defaultTo: defaultTo ?? this.defaultTo,
      contextToken: contextToken ?? this.contextToken,
      savedAtMs: savedAtMs ?? this.savedAtMs,
    );
  }
}

// ─── Messages ──────────────────────────────────────────────────────────────

/// Media descriptor shared by CDN-backed message items (image/file/video).
///
/// Mirrors the official `CDNMedia` structure.
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

  /// `0` = encrypt fileid only, `1` = pack thumbnail / mid-image info.
  final int? encryptType;

  const CdnMedia({
    this.encryptQueryParam,
    this.aesKey,
    this.fullUrl,
    this.encryptType,
  });

  factory CdnMedia.fromJson(Map<dynamic, dynamic> json) {
    return CdnMedia(
      encryptQueryParam: json['encrypt_query_param'] as String?,
      aesKey: json['aes_key'] as String?,
      fullUrl: json['full_url'] as String?,
      encryptType: (json['encrypt_type'] as num?)?.toInt(),
    );
  }

  /// Wire form, used when building outbound media items.
  Map<String, dynamic> toJson() => {
        if (encryptQueryParam != null) 'encrypt_query_param': encryptQueryParam,
        if (aesKey != null) 'aes_key': aesKey,
        if (encryptType != null) 'encrypt_type': encryptType,
        if (fullUrl != null) 'full_url': fullUrl,
      };
}

/// Payload of an image message item (`type == 2`).
class ImageItemData {
  /// 原图 CDN 引用 (`media`).
  final CdnMedia? media;

  /// 缩略图 CDN 引用 (`thumb_media`).
  final CdnMedia? thumbMedia;

  /// Top-level AES key in hex form (seen on inbound image items). When
  /// present it takes precedence over [media.aesKey].
  final String? aesKeyHex;

  final String? url;

  /// Ciphertext size in bytes (AES-ECB padded).
  final int? midSize;

  final int? thumbSize;
  final int? thumbHeight;
  final int? thumbWidth;
  final int? hdSize;

  const ImageItemData({
    this.media,
    this.thumbMedia,
    this.aesKeyHex,
    this.url,
    this.midSize,
    this.thumbSize,
    this.thumbHeight,
    this.thumbWidth,
    this.hdSize,
  });

  factory ImageItemData.fromJson(Map<dynamic, dynamic> json) {
    final rawMedia = json['media'];
    final rawThumb = json['thumb_media'];
    return ImageItemData(
      media: rawMedia is Map ? CdnMedia.fromJson(rawMedia) : null,
      thumbMedia: rawThumb is Map ? CdnMedia.fromJson(rawThumb) : null,
      aesKeyHex: json['aeskey'] as String?,
      url: json['url'] as String?,
      midSize: (json['mid_size'] as num?)?.toInt(),
      thumbSize: (json['thumb_size'] as num?)?.toInt(),
      thumbHeight: (json['thumb_height'] as num?)?.toInt(),
      thumbWidth: (json['thumb_width'] as num?)?.toInt(),
      hdSize: (json['hd_size'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
        if (media != null) 'media': media!.toJson(),
        if (thumbMedia != null) 'thumb_media': thumbMedia!.toJson(),
        if (aesKeyHex != null) 'aeskey': aesKeyHex,
        if (url != null) 'url': url,
        if (midSize != null) 'mid_size': midSize,
        if (thumbSize != null) 'thumb_size': thumbSize,
        if (thumbHeight != null) 'thumb_height': thumbHeight,
        if (thumbWidth != null) 'thumb_width': thumbWidth,
        if (hdSize != null) 'hd_size': hdSize,
      };

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
    return resolveMediaAesKeyBytes(media);
  }
}

/// Payload of a voice message item (`type == 3`).
class VoiceItemData {
  final CdnMedia? media;

  /// 语音编码类型：1=pcm 2=adpcm 3=feature 4=speex 5=amr 6=silk 7=mp3 8=ogg-speex
  final int? encodeType;
  final int? bitsPerSample;

  /// 采样率 (Hz)
  final int? sampleRate;

  /// 语音时长 (毫秒)
  final int? playtime;

  /// 语音转文字内容 (`text`).
  final String? text;

  const VoiceItemData({
    this.media,
    this.encodeType,
    this.bitsPerSample,
    this.sampleRate,
    this.playtime,
    this.text,
  });

  factory VoiceItemData.fromJson(Map<dynamic, dynamic> json) {
    final rawMedia = json['media'];
    return VoiceItemData(
      media: rawMedia is Map ? CdnMedia.fromJson(rawMedia) : null,
      encodeType: (json['encode_type'] as num?)?.toInt(),
      bitsPerSample: (json['bits_per_sample'] as num?)?.toInt(),
      sampleRate: (json['sample_rate'] as num?)?.toInt(),
      playtime: (json['playtime'] as num?)?.toInt(),
      text: json['text'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        if (media != null) 'media': media!.toJson(),
        if (encodeType != null) 'encode_type': encodeType,
        if (bitsPerSample != null) 'bits_per_sample': bitsPerSample,
        if (sampleRate != null) 'sample_rate': sampleRate,
        if (playtime != null) 'playtime': playtime,
        if (text != null) 'text': text,
      };
}

/// Payload of a file message item (`type == 4`).
class FileItemData {
  final CdnMedia? media;
  final String? fileName;
  final String? md5;

  /// Plaintext byte count, carried as a **decimal string** on the wire
  /// (official `file_item.len`).
  final String? len;

  const FileItemData({this.media, this.fileName, this.md5, this.len});

  factory FileItemData.fromJson(Map<dynamic, dynamic> json) {
    final rawMedia = json['media'];
    return FileItemData(
      media: rawMedia is Map ? CdnMedia.fromJson(rawMedia) : null,
      fileName: json['file_name'] as String?,
      md5: json['md5'] as String?,
      len: json['len']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        if (media != null) 'media': media!.toJson(),
        if (fileName != null) 'file_name': fileName,
        if (md5 != null) 'md5': md5,
        if (len != null) 'len': len,
      };
}

/// Payload of a video message item (`type == 5`).
class VideoItemData {
  final CdnMedia? media;
  final CdnMedia? thumbMedia;

  /// Ciphertext byte count set by the video sender.
  final int? videoSize;
  final int? playLength;
  final String? videoMd5;
  final int? thumbSize;
  final int? thumbHeight;
  final int? thumbWidth;

  const VideoItemData({
    this.media,
    this.thumbMedia,
    this.videoSize,
    this.playLength,
    this.videoMd5,
    this.thumbSize,
    this.thumbHeight,
    this.thumbWidth,
  });

  factory VideoItemData.fromJson(Map<dynamic, dynamic> json) {
    final rawMedia = json['media'];
    final rawThumb = json['thumb_media'];
    return VideoItemData(
      media: rawMedia is Map ? CdnMedia.fromJson(rawMedia) : null,
      thumbMedia: rawThumb is Map ? CdnMedia.fromJson(rawThumb) : null,
      videoSize: (json['video_size'] as num?)?.toInt(),
      playLength: (json['play_length'] as num?)?.toInt(),
      videoMd5: json['video_md5'] as String?,
      thumbSize: (json['thumb_size'] as num?)?.toInt(),
      thumbHeight: (json['thumb_height'] as num?)?.toInt(),
      thumbWidth: (json['thumb_width'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
        if (media != null) 'media': media!.toJson(),
        if (thumbMedia != null) 'thumb_media': thumbMedia!.toJson(),
        if (videoSize != null) 'video_size': videoSize,
        if (playLength != null) 'play_length': playLength,
        if (videoMd5 != null) 'video_md5': videoMd5,
        if (thumbSize != null) 'thumb_size': thumbSize,
        if (thumbHeight != null) 'thumb_height': thumbHeight,
        if (thumbWidth != null) 'thumb_width': thumbWidth,
      };
}

/// Payload of a tool-call start item (`type == 11`, official
/// `tool_call_start_item`).
class ToolCallStartItemData {
  final String? toolName;
  final String? toolCallId;

  const ToolCallStartItemData({this.toolName, this.toolCallId});

  factory ToolCallStartItemData.fromJson(Map<dynamic, dynamic> json) =>
      ToolCallStartItemData(
        toolName: json['tool_name'] as String?,
        toolCallId: json['tool_call_id'] as String?,
      );

  Map<String, dynamic> toJson() => {
        if (toolName != null) 'tool_name': toolName,
        if (toolCallId != null) 'tool_call_id': toolCallId,
      };
}

/// Payload of a tool-call result item (`type == 12`, official
/// `tool_call_result_item`).
class ToolCallResultItemData {
  final String? toolName;
  final String? toolCallId;
  final String? status;

  const ToolCallResultItemData({this.toolName, this.toolCallId, this.status});

  factory ToolCallResultItemData.fromJson(Map<dynamic, dynamic> json) =>
      ToolCallResultItemData(
        toolName: json['tool_name'] as String?,
        toolCallId: json['tool_call_id'] as String?,
        status: json['status'] as String?,
      );

  Map<String, dynamic> toJson() => {
        if (toolName != null) 'tool_name': toolName,
        if (toolCallId != null) 'tool_call_id': toolCallId,
        if (status != null) 'status': status,
      };
}

/// Official `PartialText` — metadata describing a selected substring of the
/// quoted message.
class PartialTextData {
  final String? start;
  final String? end;
  final int? startIndex;
  final int? endIndex;
  final String? quoteMd5;

  const PartialTextData({
    this.start,
    this.end,
    this.startIndex,
    this.endIndex,
    this.quoteMd5,
  });

  factory PartialTextData.fromJson(Map<dynamic, dynamic> json) =>
      PartialTextData(
        start: json['start'] as String?,
        end: json['end'] as String?,
        startIndex: (json['startindex'] as num?)?.toInt(),
        endIndex: (json['endindex'] as num?)?.toInt(),
        quoteMd5: json['quotemd5'] as String?,
      );

  Map<String, dynamic> toJson() => {
        if (start != null) 'start': start,
        if (end != null) 'end': end,
        if (startIndex != null) 'startindex': startIndex,
        if (endIndex != null) 'endindex': endIndex,
        if (quoteMd5 != null) 'quotemd5': quoteMd5,
      };
}

/// Official `RefMessage` — the quoted (`引用`) message reference.
class RefMessageData {
  /// Full quoted content, when the client sends it.
  final MessageItem? messageItem;

  /// 摘要
  final String? title;

  /// uint64 server message ID, carried as a string for lossless round-trip.
  final String? svrId;

  final PartialTextData? partialText;

  const RefMessageData({
    this.messageItem,
    this.title,
    this.svrId,
    this.partialText,
  });

  factory RefMessageData.fromJson(Map<dynamic, dynamic> json) {
    final rawItem = json['message_item'];
    final rawPartial = json['partial_text'];
    return RefMessageData(
      messageItem: rawItem is Map<String, dynamic>
          ? MessageItem.fromJson(rawItem)
          : null,
      title: json['title'] as String?,
      svrId: losslessId(json, 'svr_id'),
      partialText:
          rawPartial is Map ? PartialTextData.fromJson(rawPartial) : null,
    );
  }

  Map<String, dynamic> toJson() => {
        if (messageItem != null) 'message_item': messageItem!.toJson(),
        if (title != null) 'title': title,
        if (svrId != null) 'svr_id': svrId,
        if (partialText != null) 'partial_text': partialText!.toJson(),
      };
}

/// One segment inside a [WeixinMessage] (official `MessageItem`).
class MessageItem {
  final MessageItemType type;

  /// Common item fields (`create_time_ms` / `update_time_ms` /
  /// `is_completed` / `msg_id` / `ref_msg`).
  final int? createTimeMs;
  final int? updateTimeMs;
  final bool? isCompleted;

  /// uint64 item ID, carried as a string for lossless round-trip.
  final String? msgId;

  /// The quoted message, when this item replies to an earlier one.
  final RefMessageData? refMsg;

  /// Non-null when [type] == [MessageItemType.text].
  final String? text;

  /// Non-null when [type] == [MessageItemType.voice] (speech-to-text result).
  final String? voiceText;

  /// Non-null when [type] == [MessageItemType.image].
  final ImageItemData? image;

  /// Non-null when [type] == [MessageItemType.voice].
  final VoiceItemData? voice;

  /// Non-null when [type] == [MessageItemType.file].
  final FileItemData? file;

  /// Non-null when [type] == [MessageItemType.video].
  final VideoItemData? video;

  final ToolCallStartItemData? toolCallStart;
  final ToolCallResultItemData? toolCallResult;

  /// Raw JSON, kept for forward compatibility with unknown item shapes.
  final Map<String, dynamic>? raw;

  const MessageItem({
    required this.type,
    this.createTimeMs,
    this.updateTimeMs,
    this.isCompleted,
    this.msgId,
    this.refMsg,
    this.text,
    this.voiceText,
    this.image,
    this.voice,
    this.file,
    this.video,
    this.toolCallStart,
    this.toolCallResult,
    this.raw,
  });

  factory MessageItem.fromJson(Map<String, dynamic> json) {
    final type = MessageItemType.fromInt((json['type'] as num?)?.toInt());
    final rawImage = json['image_item'] as Map<String, dynamic>?;
    final rawVoice = json['voice_item'] as Map<String, dynamic>?;
    final rawFile = json['file_item'] as Map<String, dynamic>?;
    final rawVideo = json['video_item'] as Map<String, dynamic>?;
    final rawToolStart = json['tool_call_start_item'] as Map<String, dynamic>?;
    final rawToolResult =
        json['tool_call_result_item'] as Map<String, dynamic>?;
    final rawRef = json['ref_msg'] as Map<String, dynamic>?;

    return MessageItem(
      type: type,
      createTimeMs: (json['create_time_ms'] as num?)?.toInt(),
      updateTimeMs: (json['update_time_ms'] as num?)?.toInt(),
      isCompleted: json['is_completed'] as bool?,
      msgId: losslessId(json, 'msg_id'),
      refMsg: rawRef == null ? null : RefMessageData.fromJson(rawRef),
      text: (json['text_item'] as Map<String, dynamic>?)?['text'] as String?,
      voiceText: rawVoice?['text'] as String?,
      image: rawImage == null ? null : ImageItemData.fromJson(rawImage),
      voice: rawVoice == null ? null : VoiceItemData.fromJson(rawVoice),
      file: rawFile == null ? null : FileItemData.fromJson(rawFile),
      video: rawVideo == null ? null : VideoItemData.fromJson(rawVideo),
      toolCallStart: rawToolStart == null
          ? null
          : ToolCallStartItemData.fromJson(rawToolStart),
      toolCallResult: rawToolResult == null
          ? null
          : ToolCallResultItemData.fromJson(rawToolResult),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type.value,
        if (createTimeMs != null) 'create_time_ms': createTimeMs,
        if (updateTimeMs != null) 'update_time_ms': updateTimeMs,
        if (isCompleted != null) 'is_completed': isCompleted,
        if (msgId != null) 'msg_id': msgId,
        if (refMsg != null) 'ref_msg': refMsg!.toJson(),
        if (text != null) 'text_item': {'text': text},
        if (image != null) 'image_item': image!.toJson(),
        if (voice != null || voiceText != null)
          'voice_item': {
            ...?voice?.toJson(),
            if (voiceText != null) 'text': voiceText,
          },
        if (file != null) 'file_item': file!.toJson(),
        if (video != null) 'video_item': video!.toJson(),
        if (toolCallStart != null)
          'tool_call_start_item': toolCallStart!.toJson(),
        if (toolCallResult != null)
          'tool_call_result_item': toolCallResult!.toJson(),
      };

  /// Builds a text item (`type: 1`).
  factory MessageItem.text(String text) => MessageItem(
        type: MessageItemType.text,
        text: text,
      );

  /// Builds an image item (`type: 2`) from an uploaded CDN reference.
  ///
  /// Follows the official image sender: `aeskey` carries the raw 32-char hex
  /// key, `media.aes_key` the base64 of that hex string, and `mid_size` the
  /// ciphertext byte count.
  factory MessageItem.image({
    required String encryptQueryParam,
    required String aesKeyHex,
    int? midSize,
  }) =>
      MessageItem(
        type: MessageItemType.image,
        image: ImageItemData(
          media: CdnMedia(
            encryptQueryParam: encryptQueryParam,
            aesKey: base64AesKeyFromHex(aesKeyHex),
          ),
          aesKeyHex: aesKeyHex,
          midSize: midSize,
        ),
      );

  /// Builds a file item (`type: 4`) from an uploaded CDN reference.
  factory MessageItem.file({
    required String encryptQueryParam,
    required String aesKeyHex,
    required String fileName,
    required int rawSize,
    String? md5,
  }) =>
      MessageItem(
        type: MessageItemType.file,
        file: FileItemData(
          media: CdnMedia(
            encryptQueryParam: encryptQueryParam,
            aesKey: base64AesKeyFromHex(aesKeyHex),
          ),
          fileName: fileName,
          md5: md5,
          len: rawSize.toString(),
        ),
      );

  /// Builds a video item (`type: 5`) from an uploaded CDN reference.
  factory MessageItem.video({
    required String encryptQueryParam,
    required String aesKeyHex,
    int? videoSize,
    String? videoMd5,
  }) =>
      MessageItem(
        type: MessageItemType.video,
        video: VideoItemData(
          media: CdnMedia(
            encryptQueryParam: encryptQueryParam,
            aesKey: base64AesKeyFromHex(aesKeyHex),
          ),
          videoSize: videoSize,
          videoMd5: videoMd5,
        ),
      );
}

/// A WeChat iLink message (inbound or outbound) (official `WeixinMessage`).
class WeixinMessage {
  final int seq;

  /// uint64 on the wire. Kept as a **String** so Flutter Web (where JS
  /// numbers are 53-bit doubles) does not lose precision — mirrors the
  /// official lossless `parseWeixinApiJson` behaviour.
  final String? messageId;

  final String fromUserId;
  final String toUserId;
  final String clientId;

  /// Unix time in milliseconds.
  final int createTimeMs;

  /// `update_time_ms` / `delete_time_ms` (streaming updates / tombstones).
  final int? updateTimeMs;
  final int? deleteTimeMs;

  final String? sessionId;
  final String? groupId;

  /// Message origin code: `1` = sent by a real WeChat user, `2` = by the bot.
  /// Use [messageKind] / [isFromUser] instead of comparing directly.
  final int messageType;

  /// Streaming state code: `0` new, `1` generating, `2` finished.
  /// Use [state] for the enum form.
  final int messageState;

  /// Opaque token required to send a reply that triggers a WeChat notification.
  /// The [MessagePoller] caches this value per sender automatically; you do not
  /// need to manage it manually.
  final String? contextToken;

  /// Generation / run ID (`run_id`), when the sender supplies one.
  final String? runId;

  /// Ordered list of content segments. Most messages contain a single item.
  final List<MessageItem> items;

  const WeixinMessage({
    required this.seq,
    this.messageId,
    required this.fromUserId,
    required this.toUserId,
    required this.clientId,
    required this.createTimeMs,
    this.updateTimeMs,
    this.deleteTimeMs,
    this.sessionId,
    this.groupId,
    required this.messageType,
    required this.messageState,
    this.contextToken,
    this.runId,
    required this.items,
  });

  factory WeixinMessage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['item_list'] as List<dynamic>? ?? [];
    return WeixinMessage(
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      messageId: losslessId(json, 'message_id'),
      fromUserId: json['from_user_id'] as String? ?? '',
      toUserId: json['to_user_id'] as String? ?? '',
      clientId: json['client_id'] as String? ?? '',
      createTimeMs: (json['create_time_ms'] as num?)?.toInt() ?? 0,
      updateTimeMs: (json['update_time_ms'] as num?)?.toInt(),
      deleteTimeMs: (json['delete_time_ms'] as num?)?.toInt(),
      sessionId: json['session_id'] as String?,
      groupId: json['group_id'] as String?,
      messageType: (json['message_type'] as num?)?.toInt() ?? 0,
      messageState: (json['message_state'] as num?)?.toInt() ?? 0,
      contextToken: json['context_token'] as String?,
      runId: json['run_id'] as String?,
      items: rawItems
          .map((e) => MessageItem.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'seq': seq,
        if (messageId != null) 'message_id': messageId,
        'from_user_id': fromUserId,
        'to_user_id': toUserId,
        'client_id': clientId,
        'create_time_ms': createTimeMs,
        if (updateTimeMs != null) 'update_time_ms': updateTimeMs,
        if (deleteTimeMs != null) 'delete_time_ms': deleteTimeMs,
        if (sessionId != null) 'session_id': sessionId,
        if (groupId != null) 'group_id': groupId,
        'message_type': messageType,
        'message_state': messageState,
        if (contextToken != null) 'context_token': contextToken,
        if (runId != null) 'run_id': runId,
        'item_list': items.map((e) => e.toJson()).toList(),
      };

  /// [MessageType] form of [messageType].
  MessageType get messageKind => MessageType.fromInt(messageType);

  /// [MessageState] form of [messageState].
  MessageState get state => MessageState.fromInt(messageState);

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
  bool get isFromUser => messageKind == MessageType.user;

  /// First image segment in [items], or `null` for non-image messages.
  ImageItemData? get imageItem {
    for (final item in items) {
      if (item.image != null) return item.image;
    }
    return null;
  }

  /// First file segment in [items], or `null`.
  FileItemData? get fileItem =>
      items.where((i) => i.file != null).map((i) => i.file!).firstOrNull;

  /// First video segment in [items], or `null`.
  VideoItemData? get videoItem =>
      items.where((i) => i.video != null).map((i) => i.video!).firstOrNull;

  /// First voice segment in [items], or `null`.
  VoiceItemData? get voiceItem =>
      items.where((i) => i.voice != null).map((i) => i.voice!).firstOrNull;

  /// The quoted message reference of the first item carrying `ref_msg`.
  RefMessageData? get refMessage =>
      items.where((i) => i.refMsg != null).map((i) => i.refMsg!).firstOrNull;
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
      ret: (json['ret'] as num?)?.toInt() ?? 0,
      errCode: (json['errcode'] as num?)?.toInt() ?? 0,
      errMsg: json['errmsg'] as String? ?? '',
      messages: rawMsgs
          .map((e) => WeixinMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
      getUpdatesBuf: json['get_updates_buf'] as String? ?? '',
      longPollingTimeoutMs:
          (json['longpolling_timeout_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

// ─── Config / typing / lifecycle responses ─────────────────────────────────

/// Response from `POST /ilink/bot/getconfig` (official `GetConfigResp`).
class GetConfigResponse {
  final int ret;
  final String errMsg;

  /// Base64-encoded typing ticket for `sendTyping`.
  final String? typingTicket;

  const GetConfigResponse({
    required this.ret,
    required this.errMsg,
    this.typingTicket,
  });

  bool get isOk => ret == 0;

  factory GetConfigResponse.fromJson(Map<String, dynamic> json) =>
      GetConfigResponse(
        ret: (json['ret'] as num?)?.toInt() ?? 0,
        errMsg: json['errmsg'] as String? ?? '',
        typingTicket: json['typing_ticket'] as String?,
      );
}

/// Response shared by `msg/notifystart`, `msg/notifystop` and `sendtyping`.
class NotifyResponse {
  final int ret;
  final String errMsg;

  const NotifyResponse({required this.ret, required this.errMsg});

  bool get isOk => ret == 0;

  factory NotifyResponse.fromJson(Map<String, dynamic> json) => NotifyResponse(
        ret: (json['ret'] as num?)?.toInt() ?? 0,
        errMsg: json['errmsg'] as String? ?? '',
      );
}

/// Request for `POST /ilink/bot/getuploadurl` (official `GetUploadUrlReq`).
///
/// Thumbnail fields are modelled for protocol completeness; the official
/// plugin always sets [noNeedThumb] `true` and uploads only the original file.
class GetUploadUrlRequest {
  /// Client-generated file key.
  final String fileKey;

  /// See [UploadMediaType].
  final UploadMediaType mediaType;

  final String toUserId;

  /// 原文件明文大小
  final int rawSize;

  /// 原文件明文 MD5
  final String rawFileMd5;

  /// 原文件密文大小（AES-128-ECB + PKCS#7 后）
  final int fileSize;

  final int? thumbRawSize;
  final String? thumbRawFileMd5;
  final int? thumbFileSize;

  /// `true` = no thumbnail upload needed.
  final bool noNeedThumb;

  /// AES key as a 32-char hexadecimal string.
  final String aesKeyHex;

  const GetUploadUrlRequest({
    required this.fileKey,
    required this.mediaType,
    required this.toUserId,
    required this.rawSize,
    required this.rawFileMd5,
    required this.fileSize,
    required this.aesKeyHex,
    this.thumbRawSize,
    this.thumbRawFileMd5,
    this.thumbFileSize,
    this.noNeedThumb = true,
  });

  Map<String, dynamic> toJson() => {
        'filekey': fileKey,
        'media_type': mediaType.value,
        'to_user_id': toUserId,
        'rawsize': rawSize,
        'rawfilemd5': rawFileMd5,
        'filesize': fileSize,
        if (thumbRawSize != null) 'thumb_rawsize': thumbRawSize,
        if (thumbRawFileMd5 != null) 'thumb_rawfilemd5': thumbRawFileMd5,
        if (thumbFileSize != null) 'thumb_filesize': thumbFileSize,
        'no_need_thumb': noNeedThumb,
        'aeskey': aesKeyHex,
      };
}

/// Response from `POST /ilink/bot/getuploadurl` (official `GetUploadUrlResp`).
class GetUploadUrlResponse {
  /// 原图上传加密参数
  final String? uploadParam;

  /// 缩略图上传加密参数（官方当前不消费）
  final String? thumbUploadParam;

  /// 完整上传 URL（优先使用，无需客户端拼接）
  final String? uploadFullUrl;

  const GetUploadUrlResponse({
    this.uploadParam,
    this.thumbUploadParam,
    this.uploadFullUrl,
  });

  factory GetUploadUrlResponse.fromJson(Map<String, dynamic> json) =>
      GetUploadUrlResponse(
        uploadParam: json['upload_param'] as String?,
        thumbUploadParam: json['thumb_upload_param'] as String?,
        uploadFullUrl: json['upload_full_url'] as String?,
      );

  /// Whether the caller has enough information to reach the CDN for upload.
  bool get hasUploadTarget =>
      (uploadFullUrl?.isNotEmpty ?? false) ||
      (uploadParam?.isNotEmpty ?? false);
}

// ─── Send result ───────────────────────────────────────────────────────────

/// Result of a send-message call.
class SendResult {
  final bool ok;
  final String to;
  final String clientId;

  /// Server-assigned uint64 message ID (official `SendMessageResp.message_id`),
  /// carried as a string for lossless round-trip.
  final String? messageId;
  final String? error;

  const SendResult({
    required this.ok,
    required this.to,
    required this.clientId,
    this.messageId,
    this.error,
  });

  @override
  String toString() =>
      ok ? 'SendResult(ok, to=$to)' : 'SendResult(error=$error)';
}

// ─── Wire helpers ──────────────────────────────────────────────────────────

/// Fields whose wire type is uint64 and therefore must not be routed through
/// a JS double on Flutter Web. Mirrors the official `LOSSLESS_ID_FIELDS`.
const Set<String> losslessIdFields = {'message_id', 'msg_id', 'svr_id'};

/// Reads a uint64 identifier from a decoded JSON map as a lossless string.
///
/// [parseWeixinApiJson] pre-quotes these fields, so a well-formed response
/// always yields a [String]; the numeric branches keep the helper usable for
/// hand-built maps (tests, locally synthesised messages).
String? losslessId(Map<dynamic, dynamic> json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is String) return v;
  if (v is num) return v.toInt().toString();
  return v.toString();
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

/// Encodes a 32-char hex AES key as base64 **of the hex string**, which is
/// what all official image/video/file senders put into `media.aes_key`.
String base64AesKeyFromHex(String aesKeyHex) =>
    base64Encode(utf8.encode(aesKeyHex));

/// Decodes a `media.aes_key` (base64 of either 16 raw bytes or of a 32-char
/// hex string) into the raw 16-byte key, or `null` when unusable.
Uint8List? decodeMediaAesKey(String base64Key) {
  try {
    final decoded = base64Decode(base64Key);
    if (decoded.length == 16) return Uint8List.fromList(decoded);
    if (decoded.length == 32) {
      final ascii = String.fromCharCodes(decoded);
      if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(ascii)) {
        return hexToBytes(ascii);
      }
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// Resolves a decryptable AES key from a generic [CdnMedia] reference
/// (voice / file / video items have no top-level hex key).
Uint8List? resolveMediaAesKeyBytes(CdnMedia? media) {
  final raw = media?.aesKey;
  if (raw == null || raw.isEmpty) return null;
  return decodeMediaAesKey(raw);
}
