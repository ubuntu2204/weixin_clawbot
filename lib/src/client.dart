/// Low-level HTTP client for the WeChat iLink Bot API.
///
/// Endpoint-for-endpoint parity with the official openclaw-weixin plugin
/// (`src/api/api.ts`, `src/auth/login-qr.ts`, `src/cdn/upload.ts`):
///
/// | Operation    | Method + path                        | Default timeout |
/// | ------------ | ------------------------------------ | --------------- |
/// | QR code      | `POST /ilink/bot/get_bot_qrcode`     | 15 s            |
/// | QR status    | `GET  /ilink/bot/get_qrcode_status`  | 35 s            |
/// | getUpdates   | `POST /ilink/bot/getupdates`         | 35 s            |
/// | sendMessage  | `POST /ilink/bot/sendmessage`        | 15 s            |
/// | getUploadUrl | `POST /ilink/bot/getuploadurl`       | 15 s            |
/// | getConfig    | `POST /ilink/bot/getconfig`          | 10 s            |
/// | sendTyping   | `POST /ilink/bot/sendtyping`         | 10 s            |
/// | notifyStart  | `POST /ilink/bot/msg/notifystart`    | 10 s            |
/// | notifyStop   | `POST /ilink/bot/msg/notifystop`     | 10 s            |
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'bot_agent.dart';
import 'models.dart';
import 'session_guard.dart';

/// Fixed iLink API base used for all QR-code requests (official
/// `FIXED_BASE_URL`): QR fetch/refresh always targets this host, while status
/// polling may move to an IDC redirect host.
const String defaultIlinkBaseUrl = 'https://ilinkai.weixin.qq.com';

/// Channel version reported in `base_info.channel_version` and encoded into
/// the `iLink-App-ClientVersion` header.
const String defaultChannelVersion = '1.0.2';

/// `iLink-App-Id` header value used by the official openclaw-weixin plugin
/// (it reads it from the `ilink_appid` field of its own package.json).
const String defaultILinkAppId = 'bot';

/// Long-poll timeout for `getupdates` (official `DEFAULT_LONG_POLL_TIMEOUT_MS`).
const Duration defaultLongPollTimeout = Duration(seconds: 35);

/// Timeout for regular API calls (official `DEFAULT_API_TIMEOUT_MS`).
const Duration defaultApiTimeout = Duration(seconds: 15);

/// Timeout for lightweight calls — getConfig / sendTyping / notify*
/// (official `DEFAULT_CONFIG_TIMEOUT_MS`).
const Duration defaultLightTimeout = Duration(seconds: 10);

/// Client-side timeout for the `get_qrcode_status` long poll (official
/// `QR_LONG_POLL_TIMEOUT_MS`).
const Duration defaultQrPollTimeout = Duration(seconds: 35);

/// Exception thrown when the iLink API returns a non-OK HTTP status or a
/// payload with a non-zero `ret` / `errcode` field.
class ILinkApiException implements Exception {
  final String message;
  final int? statusCode;

  /// Business return code (`ret`) when the failure came from a parsed payload.
  final int? ret;

  /// `errcode` when the server supplied one instead of / alongside `ret`.
  final int? errCode;

  const ILinkApiException(
    this.message, {
    this.statusCode,
    this.ret,
    this.errCode,
  });

  @override
  String toString() => 'ILinkApiException: $message';
}

/// Wire-format helper mirroring the official `parseWeixinApiJson`.
///
/// `message_id`, `msg_id` and `svr_id` are uint64 on the wire. Dart Web
/// decodes JSON numbers into JS doubles, which silently rounds any value
/// above 2^53 — so these fields are quoted into strings *before* decoding,
/// exactly like the official plugin. Returns the decoded map.
Map<String, dynamic> parseWeixinApiJson(String rawText) {
  return jsonDecode(quoteLosslessIdFields(rawText)) as Map<String, dynamic>;
}

/// Quotes every uint64 identifier field listed in [losslessIdFields] so the
/// JSON decoder keeps it as a string. Only real object keys are rewritten;
/// text inside JSON string values is never touched.
String quoteLosslessIdFields(String rawText) {
  final out = StringBuffer();
  var index = 0;

  bool isWs(int i) => i < rawText.length && _whitespace.contains(rawText[i]);
  bool isDigit(int i) =>
      i < rawText.length &&
      rawText.codeUnitAt(i) >= 0x30 &&
      rawText.codeUnitAt(i) <= 0x39;

  while (index < rawText.length) {
    final ch = rawText[index];
    if (ch != '"') {
      out.write(ch);
      index++;
      continue;
    }

    // Scan one complete JSON string token, honouring backslash escapes.
    final stringStart = index;
    index++;
    var escaped = false;
    while (index < rawText.length) {
      final c = rawText[index];
      index++;
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        break;
      }
    }
    final stringToken = rawText.substring(stringStart, index);
    out.write(stringToken);

    var cursor = index;
    while (isWs(cursor)) {
      cursor++;
    }
    if (cursor >= rawText.length || rawText[cursor] != ':') continue;

    Object? key;
    try {
      key = jsonDecode(stringToken);
    } on FormatException {
      continue;
    }
    if (key is! String || !losslessIdFields.contains(key)) continue;

    // Emit the whitespace run plus the colon, then quote the integer literal.
    out.write(rawText.substring(index, cursor + 1));
    cursor++;
    while (isWs(cursor)) {
      out.write(rawText[cursor]);
      cursor++;
    }
    final numberStart = cursor;
    if (cursor < rawText.length && rawText[cursor] == '-') {
      cursor++;
    }
    while (isDigit(cursor)) {
      cursor++;
    }
    final loneMinus = numberStart < rawText.length &&
        rawText[numberStart] == '-' &&
        cursor == numberStart + 1;
    if (cursor > numberStart && !loneMinus) {
      out.write('"${rawText.substring(numberStart, cursor)}"');
      index = cursor;
    } else {
      // Not a usable number (string value, `null`, …) — leave it untouched.
      index = numberStart;
    }
  }

  return out.toString();
}

const Set<String> _whitespace = {' ', '\t', '\n', '\r', '\f', '\v'};

/// HTTP client that wraps the WeChat iLink Bot REST API.
///
/// Construct one instance per bot account. Obtain an instance through
/// [WeixinClawbot] rather than directly.
class ILinkClient {
  final String baseUrl;

  /// Bearer token for the bot. Empty string before login.
  final String token;

  /// Value sent as `base_info.channel_version` and encoded into
  /// `iLink-App-ClientVersion`.
  final String channelVersion;

  /// Sanitized `base_info.bot_agent` (observability only, never auth).
  final String botAgent;

  /// `iLink-App-Id` header value.
  final String ilinkAppId;

  /// Optional `SKRouteTag` routing header used by some deployments.
  final String? skRouteTag;

  /// Prefix of the generated `client_id` (official uses
  /// `generateId("openclaw-weixin")`).
  final String clientIdPrefix;

  final http.Client _http;

  ILinkClient({
    String? baseUrl,
    required this.token,
    http.Client? httpClient,
    String? channelVersion,
    String? botAgent,
    String? ilinkAppId,
    this.skRouteTag,
    String? clientIdPrefix,
  })  : baseUrl =
            (baseUrl ?? defaultIlinkBaseUrl).replaceAll(RegExp(r'/+$'), ''),
        channelVersion = channelVersion ?? defaultChannelVersion,
        botAgent = sanitizeBotAgent(botAgent),
        ilinkAppId = ilinkAppId ?? defaultILinkAppId,
        clientIdPrefix = clientIdPrefix ?? 'weixin-clawbot',
        _http = httpClient ?? http.Client();

  // ── QR Login ─────────────────────────────────────────────────────────────

  /// Fetches a QR code for bot registration (WeChat scan-to-bind).
  ///
  /// `bot_type=3` is the standard ClawBot type. Sent as a POST carrying the
  /// list of locally-known bot tokens (`local_token_list`), which lets the
  /// server answer `binded_redirect` when the scanned bot is already bound to
  /// one of them — the official plugin caps that list at the **ten most
  /// recent** tokens; see [AccountStore.botTokenList].
  ///
  /// Like the official client this request omits `Authorization` and
  /// `base_info`, and always targets the fixed API host.
  Future<QrCodeResponse> fetchLoginQrCode({
    List<String> localTokenList = const [],
  }) async {
    final body = jsonEncode({'local_token_list': localTokenList});
    final uri = Uri.parse('$baseUrl/ilink/bot/get_bot_qrcode?bot_type=3');
    final resp = await _http
        .post(uri, headers: _buildHeaders(body, withAuth: false), body: body)
        .timeout(defaultApiTimeout);
    _assertHttpOk(resp, 'get_bot_qrcode');
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return QrCodeResponse.fromJson(json);
  }

  /// Polls the login status for the given [qrCode] identifier.
  ///
  /// The server long-polls internally (up to ~35s per request) and responds
  /// as soon as the status changes. Pass [verifyCode] (the pairing number
  /// shown on the phone) when the previous response asked for one via
  /// [QrLoginStatus.needVerifyCode].
  ///
  /// Official behaviour: only the application headers are sent (no
  /// `Authorization`, no `AuthorizationType`, no `X-WECHAT-UIN`), and *any*
  /// network / gateway error is converted into `wait` so polling continues.
  Future<QrStatusResponse> pollQrStatus(
    String qrCode, {
    String? verifyCode,
    Duration timeout = defaultQrPollTimeout,
  }) async {
    var endpoint =
        '/ilink/bot/get_qrcode_status?qrcode=${Uri.encodeComponent(qrCode)}';
    if (verifyCode != null && verifyCode.isNotEmpty) {
      endpoint += '&verify_code=${Uri.encodeComponent(verifyCode)}';
    }
    final uri = Uri.parse('$baseUrl$endpoint');
    final http.Response resp;
    try {
      resp =
          await _http.get(uri, headers: _buildCommonHeaders()).timeout(timeout);
      _assertHttpOk(resp, 'get_qrcode_status');
    } on TimeoutException {
      // Client-side long-poll expiry → keep waiting (official returns `wait`).
      return const QrStatusResponse(status: QrLoginStatus.wait);
    } on ILinkApiException {
      return const QrStatusResponse(status: QrLoginStatus.wait);
    } catch (_) {
      // Gateway timeouts (e.g. Cloudflare 524) and other transport errors are
      // retried rather than surfaced, exactly like the official poller.
      return const QrStatusResponse(status: QrLoginStatus.wait);
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return QrStatusResponse.fromJson(json);
  }

  /// Returns a client pointed at [baseUrl], sharing the underlying HTTP
  /// connection pool. Used to follow `scaned_but_redirect` IDC redirects.
  ILinkClient rebase(String baseUrl) => ILinkClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: _http,
        channelVersion: channelVersion,
        botAgent: botAgent,
        ilinkAppId: ilinkAppId,
        skRouteTag: skRouteTag,
        clientIdPrefix: clientIdPrefix,
      );

  /// Returns a client sharing this client's pool and configuration but using
  /// [token] (used once QR login yields the bot credentials).
  ILinkClient withToken(String token) => ILinkClient(
        baseUrl: baseUrl,
        token: token,
        httpClient: _http,
        channelVersion: channelVersion,
        botAgent: botAgent,
        ilinkAppId: ilinkAppId,
        skRouteTag: skRouteTag,
        clientIdPrefix: clientIdPrefix,
      );

  // ── Receive messages ─────────────────────────────────────────────────────

  /// One HTTP long-poll round to retrieve pending messages.
  ///
  /// Pass the [getUpdatesBuf] cursor from the previous response (empty string
  /// on the first call). The server honours the given [timeout]; responses
  /// arrive sooner when there is a pending message.
  ///
  /// Official behaviour: a client-side timeout (or cancellation) yields an
  /// **empty `ret: 0` result that keeps the cursor**, so the poll loop simply
  /// retries. Non-zero `ret` / `errcode` are surfaced to the caller
  /// ([GetUpdatesResponse.isOk]) — [staleTokenErrcode] there means the account
  /// must be paused for an hour (see [SessionGuard]).
  Future<GetUpdatesResponse> getUpdates({
    required String getUpdatesBuf,
    Duration timeout = defaultLongPollTimeout,
  }) async {
    final body = jsonEncode({
      'get_updates_buf': getUpdatesBuf,
      'base_info': _buildBaseInfo(),
    });

    final http.Response resp;
    try {
      // A slack over the server-side hold time keeps a response that arrives
      // right at the boundary from being lost; small timeouts get a
      // proportionally small slack so they stay testable.
      resp = await _postRaw(
        '/ilink/bot/getupdates',
        body,
        timeout: timeout + longPollSlack(timeout),
      );
    } on TimeoutException {
      return GetUpdatesResponse(
        ret: 0,
        errCode: 0,
        errMsg: '',
        messages: const [],
        getUpdatesBuf: getUpdatesBuf,
        longPollingTimeoutMs: 0,
      );
    }
    _assertHttpOk(resp, 'getupdates');
    final json = parseWeixinApiJson(resp.body);
    return GetUpdatesResponse.fromJson(json);
  }

  // ── Send messages ─────────────────────────────────────────────────────────

  /// Sends [msg] downstream and returns the parsed response.
  ///
  /// Mirrors the official `sendMessage`: `base_info` is merged into the
  /// request body, and a non-zero `ret` **throws** [ILinkApiException].
  Future<SendMessageResponse> sendMessage(WeixinMessage msg) async {
    // Official SendMessageReq wraps the message in a `msg` field.
    final body = jsonEncode({
      'msg': msg.toJson(),
      'base_info': _buildBaseInfo(),
    });
    final resp =
        await _post('/ilink/bot/sendmessage', body, timeout: defaultApiTimeout);
    _assertHttpOk(resp, 'sendmessage');
    final json = parseWeixinApiJson(resp.body);
    final parsed = SendMessageResponse.fromJson(json);
    // Official: `if (resp.ret && resp.ret !== 0) throw …`.
    if (parsed.ret != null && parsed.ret != 0) {
      final hint = _knownErrors[parsed.ret] ?? '';
      throw ILinkApiException(
        'sendmessage ret=${parsed.ret} errmsg=${parsed.errmsg}'
        '${hint.isNotEmpty ? ' ($hint)' : ''}',
        ret: parsed.ret,
      );
    }
    return parsed;
  }

  /// Builds an outbound bot message envelope.
  ///
  /// `from_user_id` is intentionally empty — the official senders always send
  /// `from_user_id: ""` and let the server attribute the message to the bot.
  WeixinMessage buildOutbound({
    required String toUserId,
    required List<MessageItem> items,
    String? contextToken,
    String? runId,
    String? clientId,
  }) =>
      WeixinMessage(
        seq: 0,
        fromUserId: '',
        toUserId: toUserId,
        clientId: clientId ?? generateClientId(),
        createTimeMs: DateTime.now().millisecondsSinceEpoch,
        messageType: MessageType.bot.value,
        messageState: MessageState.finish.value,
        contextToken: contextToken,
        runId: runId,
        items: items,
      );

  /// Sends a plain-text message to [toUserId].
  ///
  /// [contextToken] is required for proactive (server-initiated) push. Without
  /// it the message is delivered but may not trigger a WeChat notification —
  /// the official sender logs a warning and sends anyway, and so do we.
  ///
  /// Never throws for business errors: a non-zero `ret` is reported through
  /// [SendResult.error] (check [SendResult.ok]). Transport failures surface
  /// the same way.
  Future<SendResult> sendText({
    required String toUserId,
    required String text,
    String? contextToken,
    String? runId,
  }) =>
      sendItems(
        toUserId: toUserId,
        items: [MessageItem.text(text)],
        contextToken: contextToken,
        runId: runId,
      );

  /// Sends one or more [items] as a single message.
  ///
  /// The official plugin sends each media item as its own request (media
  /// captions and media are separate messages, each with its own
  /// `client_id`); use [sendItemsSequentially] for that shape.
  Future<SendResult> sendItems({
    required String toUserId,
    required List<MessageItem> items,
    String? contextToken,
    String? runId,
  }) async {
    final msg = buildOutbound(
      toUserId: toUserId,
      items: items,
      contextToken: contextToken,
      runId: runId,
    );
    try {
      final resp = await sendMessage(msg);
      return SendResult(
        ok: true,
        to: toUserId,
        clientId: msg.clientId,
        messageId: resp.messageId,
      );
    } on ILinkApiException catch (e) {
      return SendResult(
          ok: false, to: toUserId, clientId: msg.clientId, error: e.message);
    } catch (e) {
      return SendResult(
          ok: false, to: toUserId, clientId: msg.clientId, error: '$e');
    }
  }

  /// Sends each entry of [items] as an independent message, reusing one
  /// `context_token` — the shape used for "media + caption" replies.
  Future<List<SendResult>> sendItemsSequentially({
    required String toUserId,
    required List<MessageItem> items,
    String? contextToken,
    String? runId,
  }) async {
    final results = <SendResult>[];
    for (final item in items) {
      results.add(await sendItems(
        toUserId: toUserId,
        items: [item],
        contextToken: contextToken,
        runId: runId,
      ));
    }
    return results;
  }

  // ── Config / typing ───────────────────────────────────────────────────────

  /// Fetches bot configuration for [ilinkUserId], including the
  /// `typing_ticket` required by [sendTyping].
  Future<GetConfigResponse> getConfig({
    required String ilinkUserId,
    String? contextToken,
  }) async {
    final body = jsonEncode({
      'ilink_user_id': ilinkUserId,
      'context_token': contextToken,
      'base_info': _buildBaseInfo(),
    });
    final resp =
        await _post('/ilink/bot/getconfig', body, timeout: defaultLightTimeout);
    _assertHttpOk(resp, 'getconfig');
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return GetConfigResponse.fromJson(json);
  }

  /// Sets or cancels the "typing…" indicator in the WeChat conversation.
  ///
  /// Requires a fresh ticket from [getConfig]. The official wrapper ignores the
  /// response body, so [NotifyResponse] is best-effort here: `ret` is parsed
  /// when present but a non-zero value does not throw.
  Future<NotifyResponse> sendTyping({
    required String ilinkUserId,
    required String typingTicket,
    TypingStatus status = TypingStatus.typing,
  }) async {
    final body = jsonEncode({
      'ilink_user_id': ilinkUserId,
      'typing_ticket': typingTicket,
      'status': status.value,
      'base_info': _buildBaseInfo(),
    });
    final resp = await _post('/ilink/bot/sendtyping', body,
        timeout: defaultLightTimeout);
    _assertHttpOk(resp, 'sendtyping');
    if (resp.body.isEmpty) return const NotifyResponse(ret: 0, errMsg: '');
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return NotifyResponse.fromJson(json);
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Notifies the backend that this channel client started (official
  /// `startAccount`). Non-zero `ret` is logged as a warning by the official
  /// plugin and never blocks startup.
  Future<NotifyResponse> notifyStart() =>
      _notify('/ilink/bot/msg/notifystart', 'notifystart');

  /// Notifies the backend that this channel client stopped (official
  /// `stopAccount`) — the counterpart of [notifyStart], and the only
  /// server-side signal available when un-binding a bot.
  Future<NotifyResponse> notifyStop() =>
      _notify('/ilink/bot/msg/notifystop', 'notifystop');

  Future<NotifyResponse> _notify(String path, String label) async {
    final body = jsonEncode({'base_info': _buildBaseInfo()});
    final resp = await _post(path, body, timeout: defaultLightTimeout);
    _assertHttpOk(resp, label);
    if (resp.body.isEmpty) return const NotifyResponse(ret: 0, errMsg: '');
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return NotifyResponse.fromJson(json);
  }

  // ── Outbound media ────────────────────────────────────────────────────────

  /// Requests CDN upload parameters (official `getUploadUrl`).
  ///
  /// The caller then encrypts the payload with AES-128-ECB and POSTs it to
  /// [uploadTargetFrom] — see `CdnMediaUploader`.
  Future<GetUploadUrlResponse> getUploadUrl(GetUploadUrlRequest req) async {
    final body = jsonEncode({
      ...req.toJson(),
      'base_info': _buildBaseInfo(),
    });
    final resp = await _post('/ilink/bot/getuploadurl', body,
        timeout: defaultApiTimeout);
    _assertHttpOk(resp, 'getuploadurl');
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return GetUploadUrlResponse.fromJson(json);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Extra time the client waits beyond the requested long-poll [timeout], so
  /// a response arriving right at the boundary is not discarded. Large
  /// timeouts get a fixed 5 s slack; small ones scale with the timeout so
  /// short timeouts remain observable in tests.
  static Duration longPollSlack(Duration timeout) =>
      timeout >= const Duration(seconds: 5)
          ? const Duration(seconds: 5)
          : timeout;

  Future<http.Response> _post(
    String path,
    String body, {
    required Duration timeout,
  }) =>
      _postRaw(path, body, timeout: timeout);

  Future<http.Response> _postRaw(
    String path,
    String body, {
    required Duration timeout,
  }) {
    final uri = Uri.parse('$baseUrl$path');
    return _http
        .post(uri, headers: _buildHeaders(body), body: body)
        .timeout(timeout);
  }

  /// `base_info` attached to every authenticated bot request. The official
  /// `buildBaseInfo()` always supplies **both** fields.
  Map<String, String> _buildBaseInfo() => {
        'channel_version': channelVersion,
        'bot_agent': botAgent,
      };

  /// Generates a random `client_id`, official-style (`<prefix>-<uuid>`).
  String generateClientId() => '$clientIdPrefix-${const Uuid().v4()}';

  Map<String, String> _buildCommonHeaders() {
    final headers = <String, String>{
      'iLink-App-Id': ilinkAppId,
      'iLink-App-ClientVersion': _buildClientVersionHeader(channelVersion),
    };
    final tag = skRouteTag;
    if (tag != null && tag.trim().isNotEmpty) {
      headers['SKRouteTag'] = tag.trim();
    }
    return headers;
  }

  Map<String, String> _buildHeaders(String body, {bool withAuth = true}) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'AuthorizationType': 'ilink_bot_token',
      'X-WECHAT-UIN': _randomWechatUin(),
      ..._buildCommonHeaders(),
    };
    if (withAuth && token.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${token.trim()}';
    }
    return headers;
  }

  static void _assertHttpOk(http.Response resp, String endpoint) {
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final body = resp.body;
      throw ILinkApiException(
        '$endpoint HTTP ${resp.statusCode}: ${body.substring(0, min(200, body.length))}',
        statusCode: resp.statusCode,
      );
    }
  }

  /// `iLink-App-ClientVersion` header: uint32 encoded as 0x00MMNNPP
  /// (major<<16 | minor<<8 | patch, e.g. "1.0.2" → 65538).
  static String _buildClientVersionHeader(String version) {
    final parts = version.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final major = parts.isNotEmpty ? parts[0] : 0;
    final minor = parts.length > 1 ? parts[1] : 0;
    final patch = parts.length > 2 ? parts[2] : 0;
    return (((major & 0xff) << 16) | ((minor & 0xff) << 8) | (patch & 0xff))
        .toString();
  }

  /// Generates a random WeChat UIN: random uint32 → decimal string → base64.
  static String _randomWechatUin() {
    final rng = Random.secure();
    final bytes = Uint8List(4)
      ..[0] = rng.nextInt(256)
      ..[1] = rng.nextInt(256)
      ..[2] = rng.nextInt(256)
      ..[3] = rng.nextInt(256);
    final number =
        (bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]) >>>
            0; // unsigned
    return base64.encode(utf8.encode(number.toString()));
  }

  static const _knownErrors = <int, String>{
    -2: 'rate limited, try again later',
    staleTokenErrcode:
        'stale bot token, session paused for one hour — re-login',
  };

  /// Releases the underlying HTTP connection pool when this client owns it.
  void dispose() => _http.close();
}

/// Response from `POST /ilink/bot/sendmessage` (official `SendMessageResp`).
class SendMessageResponse {
  /// Server-assigned uint64 message ID, kept as a lossless string.
  final String? messageId;
  final int? ret;
  final String errmsg;

  const SendMessageResponse({this.messageId, this.ret, this.errmsg = ''});

  factory SendMessageResponse.fromJson(Map<String, dynamic> json) =>
      SendMessageResponse(
        messageId: losslessId(json, 'message_id'),
        ret: (json['ret'] as num?)?.toInt(),
        errmsg: json['errmsg'] as String? ?? '',
      );
}
