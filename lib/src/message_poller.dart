/// Continuous long-poll loop that turns incoming iLink messages into a Stream.
library;

import 'dart:async';

import 'client.dart';
import 'models.dart';
import 'session_guard.dart';

/// Pure-Dart replacement for Flutter's `debugPrint` (plain console output).
void _log(String message) {
  // ignore: avoid_print
  print(message);
}

/// Controls the lifecycle of an active long-poll message subscription.
///
/// Obtain via [MessagePoller.start].
class MessageSubscription {
  final StreamSubscription<WeixinMessage> _inner;
  final MessagePoller _poller;

  MessageSubscription._(this._inner, this._poller);

  /// Pauses the message delivery.
  void pause() => _inner.pause();

  /// Resumes a paused subscription.
  void resume() => _inner.resume();

  /// Stops the long-poll loop and closes the stream.
  Future<void> cancel() async {
    _poller.stop();
    await _inner.cancel();
  }
}

/// Drives the `getupdates` long-poll loop for one bot account.
///
/// ```dart
/// final poller = MessagePoller(client: client, account: account);
/// final sub = poller.start().listen((msg) {
///   print('${msg.fromUserId}: ${msg.textContent}');
/// });
/// ```
class MessagePoller {
  final ILinkClient _client;
  final ClawBotAccount _account;

  /// Back-off delay on transient errors.
  final Duration errorRetryDelay;

  /// Per-account cooldown state for the `staleTokenErrcode` (-14) case.
  /// Defaults to the package-wide [SessionGuard.shared].
  final SessionGuard _sessionGuard;

  StreamController<WeixinMessage>? _controller;
  bool _running = false;

  /// Cursor returned by the last successful getupdates call.
  String _buf = '';

  /// Cached `typing_ticket` per user, refreshed on demand (official
  /// `api/config-cache.ts`).
  final _typingTickets = <String, String>{};

  MessagePoller({
    required ILinkClient client,
    required ClawBotAccount account,
    this.errorRetryDelay = const Duration(seconds: 5),
    SessionGuard? sessionGuard,
  })  : _client = client,
        _account = account,
        _sessionGuard = sessionGuard ?? SessionGuard.shared;

  /// Returns the latest known context token for [userId].
  ///
  /// This is updated automatically as messages arrive with new tokens.
  String? contextTokenFor(String userId) => _contextTokens[userId];
  final _contextTokens = <String, String>{};

  /// Default recipient – set automatically from the first inbound message.
  String? get defaultPeer => _defaultPeer;
  String? _defaultPeer;

  /// Starts the long-poll loop.
  ///
  /// The returned stream emits every [WeixinMessage] received from the server.
  /// The stream is broadcast; multiple listeners are allowed.
  ///
  /// A `staleTokenErrcode` (-14) response pauses the account for
  /// [sessionPauseDuration] (one hour) — exactly like the official
  /// `session-guard` — and the loop stops with a [SessionPausedException]
  /// stream error instead of retrying with a dead token.
  Stream<WeixinMessage> start() {
    if (_running) {
      return _controller!.stream;
    }
    _running = true;
    _controller = StreamController<WeixinMessage>.broadcast(
      onCancel: stop,
    );
    _pollLoop();
    return _controller!.stream;
  }

  /// The account this poller belongs to.
  ClawBotAccount get account => _account;

  /// `true` while the account is inside its -14 cooldown window.
  bool get isSessionPaused => _sessionGuard.isPaused(_account.id);

  /// Remaining -14 cooldown for this account ([Duration.zero] when active).
  Duration get sessionPauseRemaining => _sessionGuard.remaining(_account.id);

  /// Stops the long-poll loop.
  void stop() {
    _running = false;
    _controller?.close();
    _controller = null;
  }

  Future<void> _pollLoop() async {
    // Start with a conservative 35-second server-side timeout.
    // The server may instruct us to use a different value via
    // GetUpdatesResponse.longPollingTimeoutMs; we honour that on every round.
    Duration pollTimeout = defaultLongPollTimeout;

    while (_running) {
      try {
        // Official `assertSessionActive()` runs before every request.
        _sessionGuard.assertActive(_account.id);

        final resp = await _client.getUpdates(
          getUpdatesBuf: _buf,
          timeout: pollTimeout,
        );

        if (!_running) break;

        // Adopt server-recommended long-poll timeout for subsequent rounds.
        if (resp.longPollingTimeoutMs > 0) {
          pollTimeout = Duration(milliseconds: resp.longPollingTimeoutMs);
        }

        if (!resp.isOk) {
          if (resp.ret == staleTokenErrcode ||
              resp.errCode == staleTokenErrcode) {
            // Stale bot token: stop polling and cool the account down for an
            // hour. The user must scan again to obtain fresh credentials.
            _log(
              'weixin_clawbot: stale bot token (errcode $staleTokenErrcode) for '
              'account ${_account.id}; session paused for '
              '${sessionPauseDuration.inMinutes} minutes',
            );
            _sessionGuard.pause(_account.id);
            _running = false;
            _emitError(SessionPausedException(
              _account.id,
              sessionPauseDuration.inMinutes,
            ));
            return;
          }
          _log(
            'weixin_clawbot: getupdates error ret=${resp.ret} '
            'errcode=${resp.errCode} ${resp.errMsg}',
          );
          await _backOff();
          continue;
        }

        // Advance the cursor so the next call only returns new messages.
        if (resp.getUpdatesBuf.isNotEmpty && resp.getUpdatesBuf != _buf) {
          _buf = resp.getUpdatesBuf;
        }

        for (final msg in resp.messages) {
          _handleInbound(msg);
        }
      } on SessionPausedException catch (e) {
        _running = false;
        _emitError(e);
        return;
      } on ILinkApiException catch (e) {
        _log('weixin_clawbot: API error – $e');
        await _backOff();
      } catch (e) {
        _log('weixin_clawbot: unexpected error – $e');
        await _backOff();
      }
    }
  }

  void _emitError(Object error) {
    final controller = _controller;
    if (controller != null && !controller.isClosed) {
      controller.addError(error, StackTrace.current);
    }
  }

  void _handleInbound(WeixinMessage msg) {
    if (msg.fromUserId.isEmpty) return;

    // Cache context token keyed by sender ID so it can be used when replying.
    // WeixinClawbot also persists the latest token to AccountStore for
    // cold-start proactive sends.
    if (msg.contextToken?.isNotEmpty == true) {
      _contextTokens[msg.fromUserId] = msg.contextToken!;
    }

    // Record the first active peer as the default send target.
    _defaultPeer ??= msg.fromUserId;

    if (!(_controller?.isClosed ?? true)) {
      _controller!.add(msg);
    }
  }

  Future<void> _backOff() async {
    if (_running) await Future<void>.delayed(errorRetryDelay);
  }

  // ── Reply helpers ─────────────────────────────────────────────────────────

  /// Replies to [toUserId] with plain text.
  ///
  /// Automatically supplies the cached [contextToken] for [toUserId] when
  /// available. `from_user_id` is left empty, like the official senders.
  Future<SendResult> replyText({
    required String toUserId,
    required String text,
    String? contextToken,
    String? runId,
  }) {
    final token = contextToken ?? _contextTokens[toUserId];
    return _client.sendText(
      toUserId: toUserId,
      text: text,
      contextToken: token,
      runId: runId,
    );
  }

  /// Sends arbitrary [items] to [toUserId], using the cached context token.
  Future<SendResult> replyItems({
    required String toUserId,
    required List<MessageItem> items,
    String? contextToken,
    String? runId,
  }) {
    final token = contextToken ?? _contextTokens[toUserId];
    return _client.sendItems(
      toUserId: toUserId,
      items: items,
      contextToken: token,
      runId: runId,
    );
  }

  /// Sends a proactive text message to the default bound peer.
  ///
  /// The default peer is resolved in this order:
  ///  1. [MessagePoller.defaultPeer] – set automatically from the first
  ///     inbound message received since [start] was called.
  ///  2. [ClawBotAccount.defaultTo] – the WeChat user ID captured at QR
  ///     login time, available even on cold start.
  ///
  /// A valid `context_token` is required for the WeChat notification to
  /// appear on the recipient's phone. The token is captured automatically
  /// from inbound messages and persisted to [AccountStore] by [WeixinClawbot].
  /// If no token is cached yet (e.g. the user has never messaged the bot),
  /// the message may still be delivered without a push notification.
  Future<SendResult> sendToDefault(String text) {
    final peer = _defaultPeer ?? _account.defaultTo;
    if (peer == null || peer.isEmpty) {
      return Future.value(
        const SendResult(
          ok: false,
          to: '',
          clientId: '',
          error: 'No default peer – wait for an inbound message first',
        ),
      );
    }
    return replyText(toUserId: peer, text: text);
  }

  // ── Typing indicator (`getconfig` + `sendtyping`) ────────────────────────

  /// Returns a cached `typing_ticket` for [userId], fetching one through
  /// `getconfig` when none is held yet.
  ///
  /// Returns `null` when the server supplied no ticket (the official cache
  /// then keeps using defaults and simply skips the indicator).
  Future<String?> typingTicketFor(String userId,
      {bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = _typingTickets[userId];
      if (cached != null && cached.isNotEmpty) return cached;
    }
    try {
      final cfg = await _client.getConfig(
        ilinkUserId: userId,
        contextToken: _contextTokens[userId],
      );
      // Official: configuration is accepted only when `ret === 0`.
      if (!cfg.isOk) {
        _log('weixin_clawbot: getconfig ret=${cfg.ret} ${cfg.errMsg}');
        return null;
      }
      final ticket = cfg.typingTicket;
      if (ticket == null || ticket.isEmpty) return null;
      _typingTickets[userId] = ticket;
      return ticket;
    } on ILinkApiException catch (e) {
      _log('weixin_clawbot: getconfig failed – $e');
      return null;
    }
  }

  /// Shows (`TypingStatus.typing`) or cancels (`TypingStatus.cancel`) the
  /// "typing…" indicator for [userId].
  ///
  /// Best-effort, like the official wrapper which ignores the response body:
  /// returns `false` when no ticket could be obtained or the call failed.
  Future<bool> setTyping(
    String userId, {
    TypingStatus status = TypingStatus.typing,
  }) async {
    final ticket = await typingTicketFor(userId);
    if (ticket == null) return false;
    try {
      await _client.sendTyping(
        ilinkUserId: userId,
        typingTicket: ticket,
        status: status,
      );
      return true;
    } on ILinkApiException catch (e) {
      // A rejected ticket is the usual cause; drop it so the next call
      // re-fetches a fresh one.
      _typingTickets.remove(userId);
      _log('weixin_clawbot: sendtyping failed – $e');
      return false;
    }
  }

  /// Convenience wrapper around `setTyping(userId, status: typing)`.
  Future<bool> showTyping(String userId) =>
      setTyping(userId, status: TypingStatus.typing);

  /// Convenience wrapper around `setTyping(userId, status: cancel)`.
  Future<bool> cancelTyping(String userId) =>
      setTyping(userId, status: TypingStatus.cancel);
}
