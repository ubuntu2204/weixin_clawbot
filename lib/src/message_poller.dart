/// Continuous long-poll loop that turns incoming iLink messages into a Stream.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'client.dart';
import 'models.dart';

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

  StreamController<WeixinMessage>? _controller;
  bool _running = false;

  /// Cursor returned by the last successful getupdates call.
  String _buf = '';

  MessagePoller({
    required ILinkClient client,
    required ClawBotAccount account,
    this.errorRetryDelay = const Duration(seconds: 5),
  })  : _client = client,
        _account = account;

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
    Duration pollTimeout = const Duration(seconds: 35);

    while (_running) {
      try {
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
          debugPrint(
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
      } on ILinkApiException catch (e) {
        debugPrint('weixin_clawbot: API error – $e');
        await _backOff();
      } catch (e) {
        debugPrint('weixin_clawbot: unexpected error – $e');
        await _backOff();
      }
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
  /// available.
  Future<SendResult> replyText({
    required String toUserId,
    required String text,
    String? contextToken,
  }) {
    final token = contextToken ?? _contextTokens[toUserId];
    return _client.sendText(
      toUserId: toUserId,
      text: text,
      botId: _account.botId,
      contextToken: token,
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
}
