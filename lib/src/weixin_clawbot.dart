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
import 'session_guard.dart';

/// Entry point for the weixin_clawbot package.
///
/// One instance typically lives for the duration of the app. Re-use the same
/// instance to share the underlying HTTP client and account cache.
///
/// ## Lifecycle, mirroring the official plugin
///
/// | Official (`src/channel.ts`)                        | Here                          |
/// | -------------------------------------------------- | ----------------------------- |
/// | `gateway.startAccount` → `notifyStart`             | [connect]                     |
/// | `gateway.stopAccount` → `notifyStop`               | [disconnect] / [unbind]       |
/// | `auth.login` → `saveWeixinAccount` and            | [startQrLoginSession] (auto)  |
/// | `clearStaleAccountsForUserId` (re-bind)           |                              |
///
/// Note that the iLink protocol exposes **no server-side unbind endpoint**;
/// [unbind] therefore performs the official logout: `notifyStop` plus removal
/// of the locally stored credentials.
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
  /// When set, CDN media (download **and** upload) are also routed through the
  /// proxy at `<proxyBaseUrl>/cdn`; on native platforms the CDN is contacted
  /// directly.
  final String? proxyBaseUrl;

  /// Base URL of the WeChat CDN for inbound media. Usually left `null` to use
  /// [defaultCdnBaseUrl] (`https://novac2c.cdn.weixin.qq.com/c2c`).
  final String? cdnBaseUrl;

  /// `base_info.bot_agent` — a UA-style, observability-only identifier sent
  /// with every authenticated request. Sanitized per the official grammar;
  /// invalid declarations fall back to `OpenClaw`.
  final String? botAgent;

  /// Optional `SKRouteTag` routing header used by some deployments.
  final String? skRouteTag;

  /// `base_info.channel_version` / `iLink-App-ClientVersion` source version.
  final String channelVersion;

  /// Per-account session cooldown state (-14 handling).
  final SessionGuard sessionGuard;

  /// Active pollers keyed by account ID.
  final _pollers = <String, MessagePoller>{};

  /// Media uploaders keyed by account ID (each owns its account's client).
  final _uploaders = <String, CdnMediaUploader>{};

  /// Media downloader for inbound CDN-backed items (images/files/videos).
  ///
  /// On Flutter Web both the self-built CDN URL (`<proxy>/cdn`) and the
  /// server-provided `full_url` (`<proxy>/cdnfull/<host>/...`) are routed
  /// through the local CORS proxy.
  late final CdnMediaDownloader media = CdnMediaDownloader(
    cdnBaseUrl: _resolvedCdnBaseUrl,
    httpClient: _httpClient,
    fullUrlRewriter: _hasProxy ? _rewriteFullUrlThroughProxy : null,
  );

  WeixinClawbot({
    AccountStore? store,
    http.Client? httpClient,
    this.proxyBaseUrl,
    this.cdnBaseUrl,
    this.botAgent,
    this.skRouteTag,
    this.channelVersion = defaultChannelVersion,
    SessionGuard? sessionGuard,
  })  : _store = store ?? AccountStore.instance,
        _httpClient = httpClient,
        sessionGuard = sessionGuard ?? SessionGuard.shared;

  /// The account store backing this instance.
  AccountStore get store => _store;

  /// CDN base URL actually used: through the web proxy when one is set,
  /// otherwise directly (or the custom [cdnBaseUrl]).
  String get _resolvedCdnBaseUrl {
    if (cdnBaseUrl != null && cdnBaseUrl!.isNotEmpty) return cdnBaseUrl!;
    if (_hasProxy) {
      return '${proxyBaseUrl!.replaceAll(RegExp(r'/+$'), '')}/cdn';
    }
    return defaultCdnBaseUrl;
  }

  bool get _hasProxy => proxyBaseUrl != null && proxyBaseUrl!.isNotEmpty;

  /// Maps a server-provided absolute `full_url` onto the local proxy's
  /// `/cdnfull/<host>/<path>?<query>` route so Flutter Web avoids the
  /// browser's CORS / mixed-content blocks on the CDN host.
  String _rewriteFullUrlThroughProxy(String rawUrl) {
    final u = Uri.parse(rawUrl);
    final base = proxyBaseUrl!.replaceAll(RegExp(r'/+$'), '');
    final query = u.hasQuery ? '?${u.query}' : '';
    return '$base/cdnfull/${u.host}${u.path}$query';
  }

  // ── Account management ───────────────────────────────────────────────────

  /// Returns the first persisted account, or `null` if none is stored.
  Future<ClawBotAccount?> loadAccount() => _store.loadFirst();

  /// Returns all persisted accounts.
  Future<List<ClawBotAccount>> loadAllAccounts() => _store.loadAll();

  /// Un-binds an account: the official logout.
  ///
  /// The iLink protocol has **no unbind endpoint** (the official plugin only
  /// deletes local credentials — `clearWeixinAccount` +
  /// `unregisterWeixinAccountId`). This method therefore:
  ///
  /// 1. stops the long-poll loop,
  /// 2. sends `POST /ilink/bot/msg/notifystop` so the backend stops投递 (the
  ///    closest server-side signal available; failures are ignored, exactly
  ///    like the official `stopAccount`),
  /// 3. deletes the locally stored credentials and context token,
  /// 4. clears any -14 session cooldown for the account.
  ///
  /// The WeChat-side authorization itself is managed in WeChat ("已连接的设备/
  /// 服务" settings); no API here can revoke it.
  ///
  /// Pass no [accountId] to un-bind **every** stored account.
  /// Returns the account IDs that were removed.
  Future<List<String>> unbind({String? accountId}) async {
    final targets = <ClawBotAccount>[];
    if (accountId != null) {
      final stored = await _store.load(accountId);
      if (stored != null) targets.add(stored);
    } else {
      targets.addAll(await _store.loadAll());
    }

    final removed = <String>[];
    for (final account in targets) {
      _pollers.remove(account.id)?.stop();
      await _notifyStopQuietly(account);
      if (account.contextToken?.isNotEmpty == true) {
        await _store.clearContextToken(account.id);
      }
      await _store.remove(account.id);
      sessionGuard.resume(account.id);
      removed.add(account.id);
    }
    if (accountId == null && targets.isEmpty) {
      // Nothing stored — still honour the "clear everything" contract.
      await _store.clear();
    }
    return removed;
  }

  /// Legacy name for [unbind]; kept as a thin alias.
  @Deprecated(
      'Use unbind() — it also sends notifyStop like the official logout')
  Future<void> logout({String? accountId}) => unbind(accountId: accountId);

  // ── QR Login ─────────────────────────────────────────────────────────────

  /// Handles `scaned_but_redirect` IDC redirects. On Flutter Web the new host
  /// is reached through the local proxy's `/redirect/<host>` prefix; natively
  /// it is contacted directly. Hosts outside the iLink domain are ignored.
  String? _resolveRedirectBaseUrl(String host) {
    if (host != 'ilinkai.weixin.qq.com' &&
        !host.endsWith('.ilinkai.weixin.qq.com')) {
      return null;
    }
    if (_hasProxy) {
      return '${proxyBaseUrl!.replaceAll(RegExp(r'/+$'), '')}/redirect/$host';
    }
    return 'https://$host';
  }

  /// Starts the QR-code WeChat binding flow and returns a [QrLoginSession].
  ///
  /// Prefer this over [startQrLogin] when the UI needs to react to
  /// [QrVerifyCodeRequiredEvent] (the pairing number shown on the phone)
  /// via [QrLoginSession.submitVerifyCode].
  ///
  /// Behaviour matches the official `openclaw channels login`:
  /// - `get_bot_qrcode` carries the ten most recent local bot tokens, so the
  ///   server can answer `binded_redirect` when the scanned bot is already
  ///   bound to this client ([QrAlreadyConnectedEvent] — a success, not an
  ///   error);
  /// - QR codes refresh automatically up to [maxQrRefreshCount] times;
  /// - on [QrConfirmedEvent] the credentials are persisted **and** every other
  ///   stored account of the same WeChat user is pruned — this is how a WeChat
  ///   user re-binds (换绑) to a new bot, mirroring the official
  ///   `clearStaleAccountsForUserId`.
  Future<QrLoginSession> startQrLoginSession({
    String? baseUrl,
    Duration pollInterval = const Duration(seconds: 1),
    Duration loginTimeout = defaultLoginTimeout,
    int maxRefreshCount = maxQrRefreshCount,
  }) async {
    final client = _makeClient(baseUrl: baseUrl, token: '');
    // Locally-known bot tokens (max 10, newest first) so the server can
    // answer `binded_redirect` — identical to `getLocalBotTokenList()`.
    final localTokenList = await _store.botTokenList();
    final flow = QrLoginFlow(
      client: client,
      pollInterval: pollInterval,
      loginTimeout: loginTimeout,
      localTokenList: localTokenList,
      redirectBaseUrlResolver: _resolveRedirectBaseUrl,
      maxRefreshCount: maxRefreshCount,
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
              // 换绑: a WeChat user is tracked once per client. Drop the older
              // accounts bound to the same WeChat user.
              final removed = await _store.removeStaleForWechatUser(
                keepAccountId: event.account.id,
                wechatUserId: event.account.defaultTo,
              );
              for (final id in removed) {
                _pollers.remove(id)?.stop();
                sessionGuard.resume(id);
              }
              // A fresh token invalidates any earlier -14 cooldown.
              sessionGuard.resume(event.account.id);
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
  /// On [QrConfirmedEvent] the account is persisted (and older accounts of the
  /// same WeChat user are pruned), so it can be used with [connect].
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
    Duration loginTimeout = defaultLoginTimeout,
    int maxRefreshCount = maxQrRefreshCount,
  }) async* {
    final session = await startQrLoginSession(
      baseUrl: baseUrl,
      pollInterval: pollInterval,
      loginTimeout: loginTimeout,
      maxRefreshCount: maxRefreshCount,
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
  /// - `POST /ilink/bot/msg/notifystart` is sent once when the poller starts,
  ///   like the official `startAccount`. Failures are logged and never block
  ///   the connection.
  /// - Incoming `context_token` values are automatically persisted to
  ///   [AccountStore] so they survive app restarts.
  /// - The first sender's user ID is stored as [MessagePoller.defaultPeer].
  Stream<WeixinMessage> connect(ClawBotAccount account) {
    if (_pollers.containsKey(account.id)) {
      // Poller already running – return the existing broadcast stream.
      return _pollers[account.id]!.start();
    }
    final client = _makeClient(baseUrl: account.baseUrl, token: account.token);
    final poller = MessagePoller(
      client: client,
      account: account,
      sessionGuard: sessionGuard,
    );
    _pollers[account.id] = poller;

    // Official startAccount: notify the backend, ignore failures.
    unawaited(_notifyStartQuietly(account));

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

  /// Stops the poller for [accountId] and notifies the backend
  /// (`notifyStop`), mirroring the official `stopAccount`.
  ///
  /// Credentials stay stored — the account can be [connect]ed again later. Use
  /// [unbind] to also delete them.
  Future<void> disconnect(String accountId, {bool notify = true}) async {
    _pollers.remove(accountId)?.stop();
    final uploader = _uploaders.remove(accountId);
    uploader?.dispose();
    if (!notify) return;
    final account = await _store.load(accountId);
    if (account != null) await _notifyStopQuietly(account);
  }

  /// `true` while [accountId] is inside the one-hour cooldown triggered by a
  /// stale bot token (errcode `-14`).
  bool isSessionPaused(String accountId) => sessionGuard.isPaused(accountId);

  /// Remaining cooldown for [accountId] after a `-14` (zero when active).
  Duration sessionPauseRemaining(String accountId) =>
      sessionGuard.remaining(accountId);

  /// Shows or hides the WeChat "typing…" indicator for [userId] on
  /// [accountId]'s conversation. No-op when the account is not connected.
  Future<bool> setTyping(
    String userId, {
    String? accountId,
    TypingStatus status = TypingStatus.typing,
  }) async {
    final poller = _resolvePoller(accountId);
    if (poller == null) return false;
    return poller.setTyping(userId, status: status);
  }

  /// Convenience wrapper around [setTyping] with [TypingStatus.typing].
  Future<bool> showTyping(String userId, {String? accountId}) =>
      setTyping(userId, accountId: accountId, status: TypingStatus.typing);

  /// Convenience wrapper around [setTyping] with [TypingStatus.cancel].
  Future<bool> cancelTyping(String userId, {String? accountId}) =>
      setTyping(userId, accountId: accountId, status: TypingStatus.cancel);

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
    String? runId,
  }) async {
    final poller = _resolvePoller(accountId);

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

    return poller.replyText(toUserId: to, text: text, runId: runId);
  }

  /// Sends an image ([UploadMediaType.image]) to [toUserId].
  ///
  /// Uploads [bytes] to the WeChat CDN (AES-128-ECB + PKCS#7, `no_need_thumb`)
  /// and then sends a single `image_item` message — the same two-step flow the
  /// official plugin uses. Captions are sent as a **separate** text message,
  /// because the official sender emits one request per item.
  Future<SendResult> sendImage({
    required Uint8List bytes,
    String? toUserId,
    String? accountId,
    String? caption,
  }) =>
      _sendMedia(
        bytes: bytes,
        mediaType: UploadMediaType.image,
        toUserId: toUserId,
        accountId: accountId,
        caption: caption,
        buildItem: (uploaded) => MessageItem.image(
          encryptQueryParam: uploaded.downloadEncryptQueryParam,
          aesKeyHex: uploaded.aesKeyHex,
          midSize: uploaded.ciphertextSize,
        ),
      );

  /// Sends a video ([UploadMediaType.video]) to [toUserId].
  Future<SendResult> sendVideo({
    required Uint8List bytes,
    String? toUserId,
    String? accountId,
    String? caption,
  }) =>
      _sendMedia(
        bytes: bytes,
        mediaType: UploadMediaType.video,
        toUserId: toUserId,
        accountId: accountId,
        caption: caption,
        buildItem: (uploaded) => MessageItem.video(
          encryptQueryParam: uploaded.downloadEncryptQueryParam,
          aesKeyHex: uploaded.aesKeyHex,
          videoSize: uploaded.ciphertextSize,
          videoMd5: uploaded.rawMd5,
        ),
      );

  /// Sends a file attachment ([UploadMediaType.file]) to [toUserId].
  ///
  /// [fileName] is required so the recipient can display the attachment.
  Future<SendResult> sendFile({
    required Uint8List bytes,
    required String fileName,
    String? toUserId,
    String? accountId,
    String? caption,
  }) =>
      _sendMedia(
        bytes: bytes,
        mediaType: UploadMediaType.file,
        toUserId: toUserId,
        accountId: accountId,
        caption: caption,
        buildItem: (uploaded) => MessageItem.file(
          encryptQueryParam: uploaded.downloadEncryptQueryParam,
          aesKeyHex: uploaded.aesKeyHex,
          fileName: fileName,
          rawSize: uploaded.rawSize,
          md5: uploaded.rawMd5,
        ),
      );

  Future<SendResult> _sendMedia({
    required Uint8List bytes,
    required UploadMediaType mediaType,
    required MessageItem Function(UploadedMedia) buildItem,
    String? toUserId,
    String? accountId,
    String? caption,
  }) async {
    final poller = _resolvePoller(accountId);
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

    final account = poller.account;
    if (sessionGuard.isPaused(account.id)) {
      final minutes =
          (sessionGuard.remaining(account.id).inMilliseconds / 60000).ceil();
      return SendResult(
        ok: false,
        to: to,
        clientId: '',
        error:
            'Session paused for $minutes min (stale bot token, re-login needed)',
      );
    }

    try {
      final uploaded = await _uploaderFor(account)
          .upload(bytes: bytes, mediaType: mediaType, toUserId: to);
      final item = buildItem(uploaded);
      // Official behaviour: caption and media are separate requests, each with
      // its own client_id; the media goes last.
      if (caption != null && caption.isNotEmpty) {
        await poller
            .replyItems(toUserId: to, items: [MessageItem.text(caption)]);
      }
      return await poller.replyItems(toUserId: to, items: [item]);
    } on CdnUploadException catch (e) {
      return SendResult(ok: false, to: to, clientId: '', error: e.message);
    } on ILinkApiException catch (e) {
      return SendResult(ok: false, to: to, clientId: '', error: e.message);
    } catch (e) {
      return SendResult(ok: false, to: to, clientId: '', error: '$e');
    }
  }

  /// CDN uploader bound to [account]'s API client (created on first use).
  CdnMediaUploader _uploaderFor(ClawBotAccount account) {
    final existing = _uploaders[account.id];
    if (existing != null) return existing;
    final client = _makeClient(baseUrl: account.baseUrl, token: account.token);
    final uploader = CdnMediaUploader(
      client: client,
      cdnBaseUrl: _resolvedCdnBaseUrl,
      httpClient: _httpClient,
      uploadUrlRewriter: _hasProxy ? _rewriteFullUrlThroughProxy : null,
    );
    _uploaders[account.id] = uploader;
    return uploader;
  }

  MessagePoller? _resolvePoller(String? accountId) =>
      accountId != null ? _pollers[accountId] : _pollers.values.firstOrNull;

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

  /// Downloads and decrypts a voice / file / video item's CDN payload.
  ///
  /// These item types carry their key only inside `media.aes_key` (base64);
  /// when it is absent the payload is returned as-is, mirroring the official
  /// media downloader, which skips decryption for keyless items.
  Future<Uint8List> downloadVoice(VoiceItemData voice) =>
      _downloadWithMediaKey(voice.media);

  /// Downloads and decrypts a file attachment payload.
  Future<Uint8List> downloadFile(FileItemData file) =>
      _downloadWithMediaKey(file.media);

  /// Downloads and decrypts a video payload.
  Future<Uint8List> downloadVideo(VideoItemData video) =>
      _downloadWithMediaKey(video.media);

  Future<Uint8List> _downloadWithMediaKey(CdnMedia? cdnMedia) =>
      media.downloadMedia(
        cdnMedia ?? const CdnMedia(),
        aesKeyBytes: resolveMediaAesKeyBytes(cdnMedia),
      );

  // ── Helpers ───────────────────────────────────────────────────────────────

  ILinkClient _makeClient({required String? baseUrl, required String token}) {
    return ILinkClient(
      baseUrl: proxyBaseUrl ?? baseUrl,
      token: token,
      httpClient: _httpClient,
      channelVersion: channelVersion,
      botAgent: botAgent,
      skRouteTag: skRouteTag,
    );
  }

  /// Official `startAccount`: failures are logged as warnings and never block
  /// the channel from starting.
  Future<void> _notifyStartQuietly(ClawBotAccount account) async {
    try {
      final client =
          _makeClient(baseUrl: account.baseUrl, token: account.token);
      final resp = await client.notifyStart();
      if (!resp.isOk) {
        _log('notifyStart ret=${resp.ret} ${resp.errMsg}');
      }
    } catch (e) {
      _log('notifyStart failed during startup (ignored): $e');
    }
  }

  /// Official `stopAccount`: skipped without a token, failures ignored.
  Future<void> _notifyStopQuietly(ClawBotAccount account) async {
    if (account.token.trim().isEmpty) return;
    try {
      final client =
          _makeClient(baseUrl: account.baseUrl, token: account.token);
      final resp = await client.notifyStop();
      if (!resp.isOk) {
        _log('notifyStop ret=${resp.ret} ${resp.errMsg}');
      }
    } catch (e) {
      _log('notifyStop failed during shutdown (ignored): $e');
    }
  }

  static void _log(String message) {
    // Pure-Dart console output (no Flutter dependency in the core).
    // ignore: avoid_print
    print('weixin_clawbot: $message');
  }

  /// Stops all pollers and releases resources.
  ///
  /// Sends `notifyStop` for every connected account, like the official gateway
  /// shutdown, and waits briefly for those calls to land.
  Future<void> dispose() async {
    final accounts = [for (final p in _pollers.values) p.account];
    for (final poller in _pollers.values) {
      poller.stop();
    }
    _pollers.clear();
    for (final account in accounts) {
      await _notifyStopQuietly(account);
    }
    for (final uploader in _uploaders.values) {
      uploader.dispose();
    }
    _uploaders.clear();
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
