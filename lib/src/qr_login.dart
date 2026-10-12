/// QR-code–based WeChat login flow.
library;

import 'dart:async';

import 'client.dart';
import 'models.dart';

/// Number of QR codes the official plugin is willing to obtain before it stops
/// the whole login flow (official `MAX_QR_REFRESH_COUNT`). The first code
/// counts, so exactly two *refreshes* happen after it.
const int maxQrRefreshCount = 3;

/// Total time the official plugin waits for a scan (official
/// `waitForWeixinLogin` default `timeoutMs` of 480 000 ms).
const Duration defaultLoginTimeout = Duration(minutes: 8);

/// Events emitted during the QR login flow.
///
/// Terminal events — after which the stream closes — are
/// [QrConfirmedEvent], [QrAlreadyConnectedEvent], [QrTooManyQrResetsEvent],
/// [QrLoginTimeoutEvent] and [QrErrorEvent]. Everything else is informational
/// and the flow keeps running.
sealed class QrLoginEvent {}

/// The QR code is ready. Display [qrContent] as a QR image so the user can
/// scan it with WeChat.
///
/// Emitted again after every auto-refresh ([QrExpiredEvent] /
/// [QrVerifyCodeBlockedEvent] followed by [QrRefreshedEvent]).
final class QrReadyEvent extends QrLoginEvent {
  /// Text content to encode into a QR image (e.g. pass to `QrImageView`).
  final String qrContent;

  /// 1-based QR generation counter: `1` for the first code, `2` after the
  /// first refresh, and so on.
  final int generation;

  QrReadyEvent(this.qrContent, {this.generation = 1});
}

/// The user has scanned the QR code on their phone but has not yet tapped
/// "Confirm" in WeChat. Emitted once per QR code.
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
/// (`verify_code_blocked`).
///
/// Non-terminal, unlike older releases: the official plugin clears the pending
/// code and refreshes the QR code, so a [QrRefreshedEvent] and a new
/// [QrReadyEvent] follow — unless the refresh budget is exhausted
/// ([QrTooManyQrResetsEvent]).
final class QrVerifyCodeBlockedEvent extends QrLoginEvent {
  QrVerifyCodeBlockedEvent();
}

/// The QR code expired before the user scanned it.
///
/// Non-terminal, unlike older releases: the flow refreshes the code
/// automatically until the refresh budget runs out, which surfaces as
/// [QrTooManyQrResetsEvent].
final class QrExpiredEvent extends QrLoginEvent {
  QrExpiredEvent();
}

/// A fresh QR code is being fetched after an expiry or a blocked pairing code
/// (official `⏳ 正在刷新二维码...(n/3)`).
final class QrRefreshedEvent extends QrLoginEvent {
  /// 1-based generation number of the code being fetched.
  final int attempt;

  /// Generation number at which the flow gives up ([maxQrRefreshCount]).
  final int maxAttempts;

  QrRefreshedEvent(this.attempt, this.maxAttempts);
}

/// The QR code expired / was blocked too often; the login flow stopped
/// (official "二维码多次失效，连接流程已停止。").
final class QrTooManyQrResetsEvent extends QrLoginEvent {
  /// User-facing reason, mirroring the official CLI wording.
  final String reason;

  QrTooManyQrResetsEvent({this.reason = '二维码多次失效，连接流程已停止。请稍后再试。'});
}

/// Nobody scanned and no terminal status arrived before [QrLoginFlow.loginTimeout]
/// elapsed (official "登录超时，请重试。").
final class QrLoginTimeoutEvent extends QrLoginEvent {
  QrLoginTimeoutEvent();
}

/// The scanned bot is already bound to **this** client (`binded_redirect`).
///
/// The official plugin treats this as a *successful* outcome
/// (`alreadyConnected: true` — "✅ 已连接过此 OpenClaw，无需重复连接。"): local
/// credentials stay valid, nothing is persisted and no new credentials are
/// issued. It never reads `bot_token` from a `binded_redirect` response.
///
/// **Re-binding (换绑)**: the protocol has no re-bind endpoint. A WeChat user
/// moves to a new bot by scanning that other bot; the resulting
/// [QrConfirmedEvent] makes [AccountStore] drop the previously stored accounts
/// of the same WeChat user, mirroring the official
/// `clearStaleAccountsForUserId`.
final class QrAlreadyConnectedEvent extends QrLoginEvent {
  /// The scanning WeChat user's iLink user ID, when the server echoed it.
  final String? wechatUserId;

  QrAlreadyConnectedEvent({this.wechatUserId});
}

/// Login succeeded. The [account] object holds the bot credentials.
final class QrConfirmedEvent extends QrLoginEvent {
  final ClawBotAccount account;

  QrConfirmedEvent(this.account);
}

/// An unexpected error occurred during the login flow. Terminal.
final class QrErrorEvent extends QrLoginEvent {
  final Object error;
  final StackTrace stackTrace;

  QrErrorEvent(this.error, this.stackTrace);
}

/// Drives the QR-code WeChat login handshake, mirroring the official
/// openclaw-weixin `waitForWeixinLogin` state machine
/// (`src/auth/login-qr.ts`):
///
/// - `wait` / `scaned` — keep polling (`scaned` is announced once per code).
/// - `scaned_but_redirect` — switch the **polling** host to `redirect_host`
///   (IDC). QR fetches keep targeting the fixed API host, like the official
///   `FIXED_BASE_URL` used by `fetchQRCode` / `refreshQRCode`.
/// - `need_verifycode` — pause and wait for [submitVerifyCode], then send the
///   code back as `&verify_code=` on the next poll.
/// - `expired` / `verify_code_blocked` — refresh the QR code automatically
///   while the shared generation budget lasts, then stop.
/// - `binded_redirect` — already connected: terminal, but a success.
/// - `confirmed` — emit credentials and finish.
///
/// Transport / gateway errors while polling are converted into `wait` by
/// [ILinkClient.pollQrStatus] and never abort the flow — only the overall
/// [loginTimeout] or an exhausted refresh budget does.
class QrLoginFlow {
  /// Client pinned to the fixed API host, used for every `get_bot_qrcode`.
  final ILinkClient _qrClient;

  /// Client used for status polling; switches host on IDC redirect.
  ILinkClient _pollClient;

  /// How long to wait between status polls (the poll itself long-polls on the
  /// server side, so this only applies between completed requests).
  final Duration pollInterval;

  /// Total time to wait before giving up (official 480 s default).
  final Duration loginTimeout;

  /// Bot tokens already stored locally, passed to `get_bot_qrcode` as
  /// `local_token_list`. The official plugin sends at most the ten most
  /// recent tokens, newest first — build it with
  /// [AccountStore.botTokenList].
  final List<String> localTokenList;

  /// Builds the polling base URL for an IDC redirect host. Return `null` to
  /// ignore the redirect. Callers typically map `host → https://host`, or a
  /// proxy-prefixed URL on Flutter Web.
  final String? Function(String redirectHost)? redirectBaseUrlResolver;

  /// Maximum number of QR codes (first one included) before the flow stops.
  final int maxRefreshCount;

  Completer<String>? _verifyCodeCompleter;
  String? _pendingVerifyCode;

  /// How many QR codes have been fetched so far (official `qrRefreshCount`).
  int _qrGeneration = 0;

  QrLoginFlow({
    required ILinkClient client,
    this.pollInterval = const Duration(seconds: 1),
    this.loginTimeout = defaultLoginTimeout,
    this.localTokenList = const [],
    this.redirectBaseUrlResolver,
    this.maxRefreshCount = maxQrRefreshCount,
  })  : _qrClient = client,
        _pollClient = client;

  /// Supplies the pairing number shown on the phone after a
  /// [QrVerifyCodeRequiredEvent].
  void submitVerifyCode(String code) {
    final completer = _verifyCodeCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(code.trim());
    }
  }

  /// Starts the login handshake and returns a stream of events.
  Stream<QrLoginEvent> startLogin() {
    final controller = StreamController<QrLoginEvent>();
    _runLogin(controller).whenComplete(() {
      if (!controller.isClosed) controller.close();
    });
    return controller.stream;
  }

  Future<void> _runLogin(StreamController<QrLoginEvent> sink) async {
    // `scaned` is announced once per QR code (official `scannedPrinted`).
    var scannedEmitted = false;
    var verifyCodeIsRetry = false;

    try {
      final first = await _fetchQr(sink);
      if (first == null) return; // the failure was already reported
      QrCodeResponse qrResp = first;

      final deadline = DateTime.now().add(loginTimeout);

      while (DateTime.now().isBefore(deadline)) {
        final QrStatusResponse status;
        try {
          status = await _pollClient.pollQrStatus(
            qrResp.qrCode,
            verifyCode: _pendingVerifyCode,
          );
        } on TimeoutException {
          // Server-side long poll elapsed; restart immediately.
          continue;
        }

        switch (status.status) {
          case QrLoginStatus.wait:
            break;

          case QrLoginStatus.scanned:
            // A code was submitted and the server accepted it: drop it so the
            // next poll does not resend a spent value.
            _pendingVerifyCode = null;
            if (!scannedEmitted) {
              scannedEmitted = true;
              sink.add(QrScannedEvent());
            }

          case QrLoginStatus.scanedButRedirect:
            // IDC redirect: continue polling on the new host. The resolver
            // returns null to ignore hosts it does not allow.
            final host = status.redirectHost;
            if (host != null && host.isNotEmpty) {
              final resolved = redirectBaseUrlResolver != null
                  ? redirectBaseUrlResolver!(host)
                  : 'https://$host';
              if (resolved != null) {
                _pollClient = _pollClient.rebase(resolved);
              }
            }

          case QrLoginStatus.needVerifyCode:
            // The phone shows a pairing number; pause polling until the user
            // submits it. Passing the code on the next poll resumes the flow.
            _pendingVerifyCode =
                await _requestVerifyCode(sink, verifyCodeIsRetry);
            verifyCodeIsRetry = true;
            continue; // resume polling without the usual interval wait

          case QrLoginStatus.verifyCodeBlocked:
            sink.add(QrVerifyCodeBlockedEvent());
            _pendingVerifyCode = null;
            final refreshed = await _refreshQr(
              sink,
              reason: '多次输入错误，连接流程已停止。请稍后再试。',
            );
            if (refreshed == null) return;
            qrResp = refreshed;
            scannedEmitted = false;
            continue;

          case QrLoginStatus.bindedRedirect:
            // Already connected to this client: no new credentials are issued
            // and the stored ones stay valid. Terminal, and successful.
            sink.add(QrAlreadyConnectedEvent(
              wechatUserId: status.ilinkUserId,
            ));
            return;

          case QrLoginStatus.confirmed:
            final account = _accountFromStatus(status);
            if (account == null) {
              sink.add(QrErrorEvent(
                const ILinkApiException(
                  'Login confirmed but bot_token or ilink_bot_id is missing',
                ),
                StackTrace.current,
              ));
              return;
            }
            sink.add(QrConfirmedEvent(account));
            return;

          case QrLoginStatus.expired:
            sink.add(QrExpiredEvent());
            final refreshed = await _refreshQr(
              sink,
              reason: '二维码多次失效，连接流程已停止。请稍后再试。',
            );
            if (refreshed == null) return;
            qrResp = refreshed;
            scannedEmitted = false;
            continue;

          case QrLoginStatus.unknown:
            // Ignore and keep polling.
            break;
        }

        await Future<void>.delayed(pollInterval);
      }

      sink.add(QrLoginTimeoutEvent());
    } catch (e, st) {
      sink.add(QrErrorEvent(e, st));
    }
  }

  /// Fetches a QR code from the fixed API host and emits [QrReadyEvent].
  ///
  /// Returns `null` (after pushing [QrErrorEvent]) when the server gave no
  /// usable content.
  Future<QrCodeResponse?> _fetchQr(StreamController<QrLoginEvent> sink) async {
    _qrGeneration += 1;
    final resp = await _qrClient.fetchLoginQrCode(
      localTokenList: localTokenList,
    );
    if (resp.qrCodeImgContent.isEmpty) {
      sink.add(QrErrorEvent(
        const ILinkApiException('Empty qrcode_img_content from server'),
        StackTrace.current,
      ));
      return null;
    }
    sink.add(QrReadyEvent(resp.qrCodeImgContent, generation: _qrGeneration));
    return resp;
  }

  /// Refreshes the QR code within the shared refresh budget.
  ///
  /// Returns the new response, or `null` when the flow must stop — a terminal
  /// event ([QrTooManyQrResetsEvent] / [QrErrorEvent]) has then been pushed.
  Future<QrCodeResponse?> _refreshQr(
    StreamController<QrLoginEvent> sink, {
    required String reason,
  }) async {
    if (_qrGeneration >= maxRefreshCount) {
      sink.add(QrTooManyQrResetsEvent(reason: reason));
      return null;
    }
    sink.add(QrRefreshedEvent(_qrGeneration + 1, maxRefreshCount));
    return _fetchQr(sink);
  }

  /// Builds a [ClawBotAccount] from a `confirmed` poll response, or `null`
  /// when the response does not carry complete credentials.
  ClawBotAccount? _accountFromStatus(QrStatusResponse status) {
    final token = status.botToken ?? '';
    final botId = status.ilinkBotId ?? '';
    if (token.isEmpty || botId.isEmpty) return null;
    return ClawBotAccount(
      id: botId,
      token: token,
      // The official client stores the server-provided `baseurl` and falls
      // back to the default host when it is absent.
      baseUrl: status.baseUrl?.isNotEmpty == true
          ? status.baseUrl!
          : _qrClient.baseUrl,
      botId: botId,
      defaultTo: status.ilinkUserId,
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
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
