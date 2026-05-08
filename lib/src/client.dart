/// Low-level HTTP client for the WeChat iLink Bot API.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

const _defaultBaseUrl = 'https://ilinkai.weixin.qq.com';
const _channelVersion = '1.0.2';

/// Exception thrown when the iLink API returns a non-OK HTTP status or a
/// payload with a non-zero `ret` / `errcode` field.
class ILinkApiException implements Exception {
  final String message;
  final int? statusCode;

  const ILinkApiException(this.message, {this.statusCode});

  @override
  String toString() => 'ILinkApiException: $message';
}

/// HTTP client that wraps the WeChat iLink Bot REST API.
///
/// Construct one instance per bot account. Obtain an instance through
/// [WeixinClawbot] rather than directly.
class ILinkClient {
  final String baseUrl;

  /// Bearer token for the bot. Empty string before login.
  final String token;

  final http.Client _http;

  ILinkClient({
    String? baseUrl,
    required this.token,
    http.Client? httpClient,
  })  : baseUrl = (baseUrl ?? _defaultBaseUrl).replaceAll(RegExp(r'/+$'), ''),
        _http = httpClient ?? http.Client();

  // ── QR Login ─────────────────────────────────────────────────────────────

  /// Fetches a QR code for bot registration (WeChat scan-to-bind).
  ///
  /// `bot_type=3` is the standard ClawBot type.
  Future<QrCodeResponse> fetchLoginQrCode() async {
    final uri = Uri.parse('$baseUrl/ilink/bot/get_bot_qrcode?bot_type=3');
    final resp = await _http.get(uri);
    _assertHttpOk(resp, 'get_bot_qrcode');
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return QrCodeResponse.fromJson(json);
  }

  /// Polls the login status for the given [qrCode] identifier.
  ///
  /// The server uses long-polling internally; typical wait is a few seconds.
  Future<QrStatusResponse> pollQrStatus(String qrCode) async {
    final encoded = Uri.encodeComponent(qrCode);
    final uri =
        Uri.parse('$baseUrl/ilink/bot/get_qrcode_status?qrcode=$encoded');
    final resp = await _http.get(
      uri,
      headers: {'iLink-App-ClientVersion': '1'},
    );
    _assertHttpOk(resp, 'get_qrcode_status');
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return QrStatusResponse.fromJson(json);
  }

  // ── Receive messages ─────────────────────────────────────────────────────

  /// One HTTP long-poll round to retrieve pending messages.
  ///
  /// Pass the [getUpdatesBuf] cursor from the previous response (empty string
  /// on the first call). The server honours the given [timeout]; responses
  /// arrive sooner when there is a pending message.
  Future<GetUpdatesResponse> getUpdates({
    required String getUpdatesBuf,
    Duration timeout = const Duration(seconds: 35),
  }) async {
    final body = jsonEncode({
      'get_updates_buf': getUpdatesBuf,
      'base_info': {'channel_version': _channelVersion},
    });

    final resp = await _post(
      '/ilink/bot/getupdates',
      body,
      timeout: timeout + const Duration(seconds: 5),
    );
    _assertHttpOk(resp, 'getupdates');
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return GetUpdatesResponse.fromJson(json);
  }

  // ── Send messages ─────────────────────────────────────────────────────────

  /// Sends a plain-text message to [toUserId].
  ///
  /// [contextToken] is required for proactive (server-initiated) push. Without
  /// it the message is delivered but may not trigger a WeChat notification.
  Future<SendResult> sendText({
    required String toUserId,
    required String text,
    String? botId,
    String? contextToken,
  }) async {
    final clientId = _generateClientId();
    final body = jsonEncode({
      'msg': {
        'from_user_id': botId ?? '',
        'to_user_id': toUserId,
        'client_id': clientId,
        'message_type': 2, // BOT
        'message_state': 2, // FINISH
        if (contextToken != null) 'context_token': contextToken,
        'item_list': [
          {
            'type': 1,
            'text_item': {'text': text},
          }
        ],
      },
      'base_info': {'channel_version': _channelVersion},
    });

    final resp = await _post(
      '/ilink/bot/sendmessage',
      body,
      timeout: const Duration(seconds: 15),
    );
    _assertHttpOk(resp, 'sendmessage');

    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final ret = json['ret'] as int? ?? 0;
    if (ret != 0) {
      final hint = _knownErrors[ret] ?? '';
      return SendResult(
        ok: false,
        to: toUserId,
        clientId: clientId,
        error: 'ret=$ret${hint.isNotEmpty ? ' ($hint)' : ''}',
      );
    }
    return SendResult(ok: true, to: toUserId, clientId: clientId);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<http.Response> _post(
    String path,
    String body, {
    required Duration timeout,
  }) {
    final uri = Uri.parse('$baseUrl$path');
    return _http
        .post(
          uri,
          headers: _buildHeaders(body),
          body: body,
        )
        .timeout(timeout);
  }

  Map<String, String> _buildHeaders(String body) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'AuthorizationType': 'ilink_bot_token',
      'Content-Length': utf8.encode(body).length.toString(),
      'X-WECHAT-UIN': _randomWechatUin(),
    };
    if (token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  static void _assertHttpOk(http.Response resp, String endpoint) {
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ILinkApiException(
        '$endpoint HTTP ${resp.statusCode}: ${resp.body.substring(0, min(200, resp.body.length))}',
        statusCode: resp.statusCode,
      );
    }
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

  static String _generateClientId() =>
      'flutter-${DateTime.now().microsecondsSinceEpoch}';

  static const _knownErrors = <int, String>{
    -2: 'rate limited, try again later',
    -14: 'session expired, re-login via openclaw',
  };

  /// Releases underlying HTTP connection pool.
  void dispose() => _http.close();
}
