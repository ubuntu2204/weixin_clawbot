/// QR-code–based WeChat login flow.
library;

import 'dart:async';

import 'client.dart';
import 'models.dart';

/// Events emitted during the QR login flow.
sealed class QrLoginEvent {}

/// The QR code is ready. Display [qrContent] as a QR image so the user can
/// scan it with WeChat.
final class QrReadyEvent extends QrLoginEvent {
  /// Text content to encode into a QR image (e.g. pass to `QrImageView`).
  final String qrContent;

  QrReadyEvent(this.qrContent);
}

/// The user has scanned the QR code on their phone but has not yet tapped
/// "Confirm" in WeChat.
final class QrScannedEvent extends QrLoginEvent {
  QrScannedEvent();
}

/// The server asks for the pairing number shown on the phone
/// (`need_verifycode`). Call [QrLoginFlow.submitVerifyCode] with the number
/// the user sees in WeChat to continue the login.
final class QrVerifyCodeRequiredEvent extends QrLoginEvent {
  /// `true` when the previously submitted code did not match.
  final bool isRetry;

  QrVerifyCodeRequiredEvent({this.isRetry = false});
}

/// The verify code was submitted incorrectly too many times
/// (`verify_code_blocked`). The stream closes after this event; the user
/// should restart the login after a pause.
final class QrVerifyCodeBlockedEvent extends QrLoginEvent {
  QrVerifyCodeBlockedEvent();
}

/// The scanned bot is already bound to one of the locally-known accounts
/// (`binded_redirect`).
///
/// Depending on the server response the event may carry the existing binding
/// information so callers can implement account hand-over (re-binding the
/// same WeChat user to a different local account):
/// - [existingAccount] is non-null when the server echoed the bound bot's
///   credentials — the caller can use them directly (equivalent to login).
/// - [existingWechatUserid] is the bound WeChat's iLink user ID, useful to
///   locate the previous binding in your own user store and migrate it.
final class QrAlreadyBoundEvent extends QrLoginEvent {
  final ClawBotAccount? existingAccount;
  final String? existingWechatUserid;

  QrAlreadyBoundEvent({this.existingAccount, this.existingWechatUserid});
}

/// Login succeeded. The [account] object holds the bot credentials.
final class QrConfirmedEvent extends QrLoginEvent {
  final ClawBotAccount account;

  QrConfirmedEvent(this.account);
}

/// The QR code expired before the user scanned it.
final class QrExpiredEvent extends QrLoginEvent {
  QrExpiredEvent();
}

/// An unexpected error occurred during the login flow.
final class QrErrorEvent extends QrLoginEvent {
  final Object error;
  final StackTrace stackTrace;

  QrErrorEvent(this.error, this.stackTrace);
}

/// Drives the QR-code WeChat login handshake, mirroring the official
/// openclaw-weixin `waitForWeixinLogin` state machine:
///
/// - `wait` / `scaned` — keep polling.
/// - `scaned_but_redirect` — switch the polling host to `redirect_host` (IDC).
/// - `need_verifycode` — pause and wait for [submitVerifyCode], then send the
///   code back as `&verify_code=` on the next poll.
/// - `verify_code_blocked` — terminal outcome.
/// - `binded_redirect` — the WeChat user is already bound. See [allowRebind].
/// - `confirmed` — emit credentials and finish.
class QrLoginFlow {
  ILinkClient _client;

  /// How long to wait between status polls (the poll itself long-polls on the
  /// server side, so this only applies between completed requests).
  final Duration pollInterval;

  /// Total time to wait before giving up.
  final Duration loginTimeout;

  /// Bot tokens already stored locally, passed to `get_bot_qrcode` as
  /// `local_token_list` so the server can answer `binded_redirect`.
  final List<String> localTokenList;

  /// Builds the polling base URL for an IDC redirect host. Return `null` to
  /// ignore the redirect. Callers typically map `host → https://host`, or a
  /// proxy-prefixed URL on Flutter Web.
  final String? Function(String redirectHost)? redirectBaseUrlResolver;

  /// Enables **re-binding** (account hand-over) for an already-bound WeChat
  /// user. When `true`:
  ///
  /// 1. `get_bot_qrcode` is sent **without** `local_token_list`, so the server
  ///    issues a *new* bot for the scanning WeChat user instead of answering
  ///    `binded_redirect` — one scan completes the re-bind.
  /// 2. If the server still answers `binded_redirect` and echoes the existing
  ///    bot credentials, they are emitted as [QrConfirmedEvent] (taking over
  ///    the existing binding).
  /// 3. Otherwise a [QrAlreadyBoundEvent] is emitted once and a fresh QR code
  ///    (without the token list) is fetched automatically so the user can
  ///    scan a second time to create the new binding.
  final bool allowRebind;

  Completer<String>? _verifyCodeCompleter;
  String? _pendingVerifyCode;

  QrLoginFlow({
    required ILinkClient client,
    this.pollInterval = const Duration(seconds: 1),
    this.loginTimeout = const Duration(minutes: 8),
    this.localTokenList = const [],
    this.redirectBaseUrlResolver,
    this.allowRebind = false,
  }) : _client = client;

  /// Supplies the pairing number shown on the phone after a
  /// [QrVerifyCodeRequiredEvent].
  void submitVerifyCode(String code) {
    final completer = _verifyCodeCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(code.trim());
    }
  }

  /// Starts the login handshake and returns a stream of events.
  ///
  /// The stream closes after a [QrConfirmedEvent], [QrExpiredEvent],
  /// [QrVerifyCodeBlockedEvent], [QrAlreadyBoundEvent], or [QrErrorEvent].
  Stream<QrLoginEvent> startLogin() {
    final controller = StreamController<QrLoginEvent>();
    _runLogin(controller).then((_) {
      if (!controller.isClosed) controller.close();
    });
    return controller.stream;
  }

  Future<void> _runLogin(StreamController<QrLoginEvent> sink) async {
    try {
      // Step 1 – fetch QR code. In re-bind mode the local token list is
      // omitted so the server creates a NEW bot for the scanning WeChat user
      // (one scan completes the hand-over) instead of answering
      // `binded_redirect`.
      var qrResp = await _client.fetchLoginQrCode(
        localTokenList: allowRebind ? const [] : localTokenList,
      );
      if (qrResp.qrCodeImgContent.isEmpty) {
        sink.addError(
          const ILinkApiException('Empty qrcode_img_content from server'),
        );
        return;
      }

      sink.add(QrReadyEvent(qrResp.qrCodeImgContent));

      // Step 2 – poll until confirmed / expired / terminal state / timeout
      var deadline = DateTime.now().add(loginTimeout);
      var consecutiveErrors = 0;
      var verifyCodeIsRetry = false;
      var rebindAttempted = false;

      while (DateTime.now().isBefore(deadline)) {
        QrStatusResponse status;
        try {
          status = await _client.pollQrStatus(
            qrResp.qrCode,
            verifyCode: _pendingVerifyCode,
          );
          _pendingVerifyCode = null;
          consecutiveErrors = 0;
        } on TimeoutException {
          // Server-side long poll elapsed; restart immediately.
          continue;
        } on ILinkApiException catch (e) {
          // Transient gateway errors should not kill the login. Give up only
          // after several consecutive failures.
          if (++consecutiveErrors >= 3) {
            sink.addError(e);
            return;
          }
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }

        switch (status.status) {
          case QrLoginStatus.wait:
            break;

          case QrLoginStatus.scanned:
            sink.add(QrScannedEvent());

          case QrLoginStatus.scanedButRedirect:
            // IDC redirect: continue polling on the new host. The resolver
            // returns null to ignore hosts it does not allow.
            final host = status.redirectHost;
            if (host != null && host.isNotEmpty) {
              final resolved = redirectBaseUrlResolver != null
                  ? redirectBaseUrlResolver!(host)
                  : 'https://$host';
              if (resolved != null) {
                _client = _client.rebase(resolved);
              }
            }

          case QrLoginStatus.needVerifyCode:
            // The phone shows a pairing number; pause polling until the user
            // submits it. Passing the code on the next poll resumes the flow.
            _pendingVerifyCode = await _requestVerifyCode(sink, verifyCodeIsRetry);
            verifyCodeIsRetry = true;
            continue;

          case QrLoginStatus.verifyCodeBlocked:
            sink.add(QrVerifyCodeBlockedEvent());
            return;

          case QrLoginStatus.bindedRedirect:
            // The WeChat user is already bound to a bot.
            final existing = _accountFromStatus(status);
            if (existing != null) {
              // The server echoed the existing bot credentials: taking over
              // the existing binding is equivalent to a successful login.
              sink.add(QrConfirmedEvent(existing));
              return;
            }
            if (allowRebind && !rebindAttempted) {
              // No credentials echoed and re-bind is allowed: surface the
              // already-bound notice (with the WeChat user id when available)
              // and automatically fetch a fresh QR code WITHOUT the local
              // token list, asking the server for a new bot. The user scans
              // a second time to complete the hand-over.
              rebindAttempted = true;
              sink.add(QrAlreadyBoundEvent(
                existingWechatUserid: status.ilinkUserId,
              ));
              qrResp = await _client.fetchLoginQrCode(localTokenList: const []);
              if (qrResp.qrCodeImgContent.isEmpty) {
                sink.addError(const ILinkApiException(
                  'Empty qrcode_img_content from server (re-bind retry)',
                ));
                return;
              }
              sink.add(QrReadyEvent(qrResp.qrCodeImgContent));
              deadline = DateTime.now().add(loginTimeout);
              consecutiveErrors = 0;
              await Future<void>.delayed(pollInterval);
              continue;
            }
            sink.add(QrAlreadyBoundEvent(
              existingWechatUserid: status.ilinkUserId,
            ));
            return;

          case QrLoginStatus.confirmed:
            final account = _accountFromStatus(status);
            if (account == null) {
              sink.addError(const ILinkApiException(
                'Login confirmed but bot_token or ilink_bot_id is missing',
              ));
              return;
            }
            sink.add(QrConfirmedEvent(account));
            return;

          case QrLoginStatus.expired:
            sink.add(QrExpiredEvent());
            return;

          case QrLoginStatus.unknown:
            // Ignore and keep polling.
            break;
        }

        await Future<void>.delayed(pollInterval);
      }

      // Timed out
      sink.add(QrExpiredEvent());
    } catch (e, st) {
      sink.add(QrErrorEvent(e, st));
    }
  }

  /// Builds a [ClawBotAccount] from a poll response, or `null` when the
  /// response does not carry complete credentials.
  ClawBotAccount? _accountFromStatus(QrStatusResponse status) {
    final token = status.botToken ?? '';
    final botId = status.ilinkBotId ?? '';
    if (token.isEmpty || botId.isEmpty) return null;
    return ClawBotAccount(
      id: botId,
      token: token,
      baseUrl: status.baseUrl?.isNotEmpty == true
          ? status.baseUrl!
          : _client.baseUrl,
      botId: botId,
      defaultTo: status.ilinkUserId,
    );
  }

  Future<String> _requestVerifyCode(
    StreamController<QrLoginEvent> sink,
    bool isRetry,
  ) {
    final completer = Completer<String>();
    _verifyCodeCompleter = completer;
    if (!sink.isClosed) sink.add(QrVerifyCodeRequiredEvent(isRetry: isRetry));

    // Give the user a generous but bounded window to type the number.
    return completer.future.timeout(const Duration(minutes: 5));
  }
}
