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

/// Drives the QR-code WeChat login handshake.
///
/// Call [startLogin] to receive a [Stream] of [QrLoginEvent]s. Show the QR
/// code from [QrReadyEvent.qrContent] using `qr_flutter`'s `QrImageView`
/// widget, then wait for a [QrConfirmedEvent] or [QrExpiredEvent].
class QrLoginFlow {
  final ILinkClient _client;

  /// How often to poll the QR status endpoint.
  final Duration pollInterval;

  /// Total time to wait before giving up.
  final Duration loginTimeout;

  QrLoginFlow({
    required ILinkClient client,
    this.pollInterval = const Duration(seconds: 2),
    this.loginTimeout = const Duration(minutes: 8),
  }) : _client = client;

  /// Starts the login handshake and returns a stream of events.
  ///
  /// The stream closes after a [QrConfirmedEvent], [QrExpiredEvent], or
  /// [QrErrorEvent].
  Stream<QrLoginEvent> startLogin() {
    final controller = StreamController<QrLoginEvent>();
    _runLogin(controller).then((_) {
      if (!controller.isClosed) controller.close();
    });
    return controller.stream;
  }

  Future<void> _runLogin(StreamController<QrLoginEvent> sink) async {
    try {
      // Step 1 – fetch QR code
      final qrResp = await _client.fetchLoginQrCode();
      if (qrResp.qrCodeImgContent.isEmpty) {
        sink.addError(
          const ILinkApiException('Empty qrcode_img_content from server'),
        );
        return;
      }

      sink.add(QrReadyEvent(qrResp.qrCodeImgContent));

      // Step 2 – poll until confirmed / expired / timeout
      final deadline = DateTime.now().add(loginTimeout);

      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(pollInterval);

        final status = await _client.pollQrStatus(qrResp.qrCode);

        switch (status.status) {
          case QrLoginStatus.wait:
            // Still waiting – continue polling.
            break;

          case QrLoginStatus.scanned:
            sink.add(QrScannedEvent());

          case QrLoginStatus.confirmed:
            final token = status.botToken ?? '';
            final botId = status.ilinkBotId ?? '';
            if (token.isEmpty || botId.isEmpty) {
              sink.addError(const ILinkApiException(
                'Login confirmed but bot_token or ilink_bot_id is missing',
              ));
              return;
            }
            final account = ClawBotAccount(
              id: botId,
              token: token,
              baseUrl: status.baseUrl?.isNotEmpty == true
                  ? status.baseUrl!
                  : _client.baseUrl,
              botId: botId,
              defaultTo: status.ilinkUserId,
            );
            sink.add(QrConfirmedEvent(account));
            return;

          case QrLoginStatus.expired:
            sink.add(QrExpiredEvent());
            return;

          case QrLoginStatus.unknown:
            // Ignore and keep polling.
            break;
        }
      }

      // Timed out
      sink.add(QrExpiredEvent());
    } catch (e, st) {
      sink.add(QrErrorEvent(e, st));
    }
  }
}
