/// High-level facade for WeChat ClawBot integration.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'account_store.dart';
import 'cdn_media.dart';
import 'client.dart';
import 'message_poller.dart';
import 'models.dart';
import 'qr_login.dart';

/// Entry point for the weixin_clawbot package.
///
/// One instance typically lives for the duration of the app. Re-use the same
/// instance to share the underlying HTTP client and account cache.
class WeixinClawbot {
  final AccountStore _store;
  final http.Client? _httpClient;

  /// When set, ALL API requests are routed through this base URL instead of
  /// the default `https://ilinkai.weixin.qq.com`.
  ///
  /// Use this on **Flutter Web** to work around browser CORS restrictions.
  /// Run the bundled proxy server (`dart run bin/proxy_server.dart` inside the
  /// example project) which forwards requests to the real iLink endpoint, then
  /// pass `proxyBaseUrl: 'http://localhost:3001'` here.
  ///
  /// When set, CDN media downloads are also routed through the proxy at
  /// `<proxyBaseUrl>/cdn` (the proxy forwards that prefix to the WeChat CDN);
  /// on native platforms the CDN is contacted directly.
  final String? proxyBaseUrl;

  /// Base URL of the WeChat CDN for inbound media. Usually left `null` to use
  /// [defaultCdnBaseUrl] (`https://novac2c.cdn.weixin.qq.com/c2c`).
  final String? cdnBaseUrl;

  /// Active pollers keyed by account ID.
  final _pollers = <String, MessagePoller>{};

  /// Media downloader for inbound CDN-backed items (images/files/videos).
  late final CdnMediaDownloader media = CdnMediaDownloader(
    cdnBaseUrl: _resolvedCdnBaseUrl,
    httpClient: _httpClient,
  );

  WeixinClawbot({
    AccountStore? store,
    http.Client? httpClient,
    this.proxyBaseUrl,
    this.cdnBaseUrl,
  })  : _store = store ?? AccountStore.instance,
        _httpClient = httpClient;

  /// CDN base URL actually used: through the web proxy when one is set,
  /// otherwise directly (or the custom [cdnBaseUrl]).
  String get _resolvedCdnBaseUrl {
    if (cdnBaseUrl != null && cdnBaseUrl!.isNotEmpty) return cdnBaseUrl!;
    if (proxyBaseUrl != null && proxyBaseUrl!.isNotEmpty) {
      return '${proxyBaseUrl!.replaceAll(RegExp(r'/+$'), '')}/cdn';
    }
    return defaultCdnBaseUrl;
  }

  // ── Account management ───────────────────────────────────────────────────

  /// Returns the first persisted account, or `null` if none is stored.
  Future<ClawBotAccount?> loadAccount() => _store.loadFirst();

  /// Returns all persisted accounts.
  Future<List<ClawBotAccount>> loadAllAccounts() => _store.loadAll();

  /// Removes a persisted account and stops any active poller for it.
  Future<void> logout({String? accountId}) async {
    if (accountId != null) {
      await _store.remove(accountId);
      _pollers.remove(accountId)?.stop();
    } else {
      final all = await _store.loadAll();
      for (final a in all) {
        _pollers.remove(a.id)?.stop();
      }
      await _store.clear();
    }
  }

  // ── QR Login ─────────────────────────────────────────────────────────────

  /// Handles `scaned_but_redirect` IDC redirects. On Flutter Web the new host
  /// is reached through the local proxy's `/redirect/<host>` prefix; natively
  /// it is contacted directly. Hosts outside the iLink domain are ignored.
  String? _resolveRedirectBaseUrl(String host) {
    if (host != 'ilinkai.weixin.qq.com' &&
        !host.endsWith('.ilinkai.weixin.qq.com')) {
      return null;
    }
    if (proxyBaseUrl != null && proxyBaseUrl!.isNotEmpty) {
      return '${proxyBaseUrl!.replaceAll(RegExp(r'/+$'), '')}/redirect/$host';
    }
    return 'https://$host';
  }

  /// Starts the QR-code WeChat binding flow and returns a [QrLoginSession].
  ///
  /// Prefer this over [startQrLogin] when the UI needs to react to
  /// [QrVerifyCodeRequiredEvent] (the pairing number shown on the phone)
  /// via [QrLoginSession.submitVerifyCode].
  Future<QrLoginSession> startQrLoginSession({
    String? baseUrl,
    Duration pollInterval = const Duration(seconds: 1),
    Duration loginTimeout = const Duration(minutes: 8),
  }) async {
    final client = _makeClient(baseUrl: baseUrl, token: '');
    // Pass locally-known bot tokens so the server can answer `binded_redirect`
    // when the scanned bot is already bound (mirrors the official plugin).
    final accounts = await _store.loadAll();
    final flow = QrLoginFlow(
      client: client,
      pollInterval: pollInterval,
      loginTimeout: loginTimeout,
      localTokenList: [
        for (final a in accounts)
          if (a.token.isNotEmpty) a.token,
      ],
      redirectBaseUrlResolver: _resolveRedirectBaseUrl,
    );

    final controller = StreamController<QrLoginEvent>.broadcast();

    flow.startLogin().listen(
          (event) async {
            // Emit the event FIRST so listeners (e.g. QrLoginWidget) receive
            // QrConfirmedEvent synchronously before the broadcast controller
            // is closed by onDone (which fires while the store save is awaited).
            if (!controller.isClosed) controller.add(event);
            if (event is QrConfirmedEvent) {
              await _store.save(event.account);
            }
          },
          onError: controller.addError,
          onDone: () {
            if (!controller.isClosed) controller.close();
          },
        );

    return QrLoginSession._(controller.stream, flow, client);
  }

  /// Returns a stream of [QrLoginEvent]s for the QR-code WeChat binding flow.
  ///
  /// Listen to the stream and display [QrReadyEvent.qrContent] as a QR image.
  /// On [QrConfirmedEvent] the account is automatically persisted and can be
  /// used with [connect].
  ///
  /// If the server asks for a pairing number ([QrVerifyCodeRequiredEvent]),
  /// use [startQrLoginSession] instead so the code can be submitted back.
  ///
  /// Example:
  /// ```dart
  /// clawbot.startQrLogin().listen((event) {
  ///   if (event is QrReadyEvent) showQr(event.qrContent);
  ///   if (event is QrConfirmedEvent) clawbot.connect(event.account);
  /// });
  /// ```
  Stream<QrLoginEvent> startQrLogin({
    String? baseUrl,
    Duration pollInterval = const Duration(seconds: 1),
    Duration loginTimeout = const Duration(minutes: 8),
  }) async* {
    final session = await startQrLoginSession(
      baseUrl: baseUrl,
      pollInterval: pollInterval,
      loginTimeout: loginTimeout,
    );
    yield* session.events;
  }

  // ── Messaging ────────────────────────────────────────────────────────────

  /// Connects to the iLink server for [account] and starts receiving messages.
  ///
  /// Returns a broadcast [Stream] of [WeixinMessage]. The long-poll loop runs
  /// in the background until [disconnect] or [dispose] is called.
  ///
  /// Calling this method multiple times with the same account ID is safe: the
  /// same [MessagePoller] instance (and therefore the same broadcast stream) is
  /// reused, so multiple widgets can each call [connect] independently.
  ///
  /// Side effects:
  /// - Incoming `context_token` values are automatically persisted to
  ///   [AccountStore] so they survive app restarts.
  /// - The first sender's user ID is stored as [MessagePoller.defaultPeer].
  Stream<WeixinMessage> connect(ClawBotAccount account) {
    if (_pollers.containsKey(account.id)) {
      // Poller already running – return the existing broadcast stream.
      return _pollers[account.id]!.start();
    }
    final client = _makeClient(baseUrl: account.baseUrl, token: account.token);
    final poller = MessagePoller(client: client, account: account);
    _pollers[account.id] = poller;

    // Attach an internal listener that persists context tokens as they arrive.
    // poller.start() is idempotent: the second call below returns the same
    // broadcast stream without starting a second poll loop.
    poller.start().listen((msg) {
      if (msg.contextToken?.isNotEmpty == true) {
        _store.updateContextToken(
          accountId: account.id,
          userId: msg.fromUserId,
          contextToken: msg.contextToken!,
        );
      }
    });

    // Return the broadcast stream to the caller. Both listeners receive every
    // message because MessagePoller uses a broadcast StreamController.
    return poller.start();
  }

  /// Returns the [MessagePoller] for [accountId], or `null` if not connected.
  MessagePoller? pollerFor(String accountId) => _pollers[accountId];

  /// Stops the poller for [accountId].
  void disconnect(String accountId) {
    _pollers.remove(accountId)?.stop();
  }

  /// Sends a plain-text message.
  ///
  /// [text] is the message body.
  ///
  /// [toUserId] is the iLink user ID of the recipient. If omitted, the poller's
  /// [MessagePoller.defaultPeer] (set automatically from the first inbound
  /// message) is used as a fallback. For proactive sends before any inbound
  /// message has arrived, pass `account.defaultTo` which is populated at
  /// QR login time.
  ///
  /// [accountId] selects which connected account to send from. Defaults to
  /// the first active account when omitted.
  ///
  /// Always returns a [SendResult]; never throws. Check [SendResult.ok] and
  /// [SendResult.error] for failure details.
  Future<SendResult> sendText({
    required String text,
    String? toUserId,
    String? accountId,
  }) async {
    final poller =
        accountId != null ? _pollers[accountId] : _pollers.values.firstOrNull;

    if (poller == null) {
      return const SendResult(
        ok: false,
        to: '',
        clientId: '',
        error: 'No active connection – call connect() first',
      );
    }

    final to = toUserId ?? poller.defaultPeer;
    if (to == null || to.isEmpty) {
      return const SendResult(
        ok: false,
        to: '',
        clientId: '',
        error: 'No recipient – provide toUserId or wait for an inbound message',
      );
    }

    return poller.replyText(toUserId: to, text: text);
  }

  // ── Inbound media ────────────────────────────────────────────────────────

  /// Downloads and decrypts an inbound image message item.
  ///
  /// Returns the raw picture bytes ready for `Image.memory`. Throws
  /// [ILinkApiException] on network/HTTP errors and `FormatException` when
  /// decryption fails.
  Future<Uint8List> downloadImage(ImageItemData image) =>
      media.downloadImage(image);

  /// Downloads and decrypts a raw CDN media reference (file/video items).
  ///
  /// [aesKeyBytes] may be `null` for unencrypted payloads.
  Future<Uint8List> downloadMedia(CdnMedia media, {Uint8List? aesKeyBytes}) =>
      this.media.downloadMedia(media, aesKeyBytes: aesKeyBytes);

  // ── Helpers ───────────────────────────────────────────────────────────────

  ILinkClient _makeClient({required String? baseUrl, required String token}) {
    return ILinkClient(
      baseUrl: proxyBaseUrl ?? baseUrl,
      token: token,
      httpClient: _httpClient,
    );
  }

  /// Stops all pollers and releases resources.
  void dispose() {
    for (final poller in _pollers.values) {
      poller.stop();
    }
    _pollers.clear();
    media.dispose();
    _httpClient?.close();
  }
}

/// Handle to an in-flight QR login: the [events] stream plus the ability to
/// submit the pairing number when the server asks for one.
class QrLoginSession {
  final Stream<QrLoginEvent> events;
  final QrLoginFlow _flow;
  final ILinkClient _client;

  QrLoginSession._(this.events, this._flow, this._client);

  /// Submits the pairing number displayed on the phone in response to a
  /// [QrVerifyCodeRequiredEvent]. No-op when the flow is not waiting for one.
  void submitVerifyCode(String code) => _flow.submitVerifyCode(code);

  /// Releases the underlying HTTP client (the flow has finished).
  void dispose() => _client.dispose();
}
