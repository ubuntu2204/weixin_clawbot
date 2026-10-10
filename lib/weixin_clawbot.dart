/// WeChat ClawBot package (pure Dart).
///
/// Provides QR-code–based WeChat binding, message receiving via long-poll,
/// and message sending through the WeChat iLink Bot API.
///
/// Runs on **Dart servers, Flutter mobile/desktop and Flutter Web** — the
/// core protocol layer has no Flutter dependency.
///
/// ## Quick start
///
/// ```dart
/// import 'package:weixin_clawbot/weixin_clawbot.dart';
///
/// // 1. Create the facade (use an existing account if stored)
/// final clawbot = WeixinClawbot();
///
/// // 2. Check for a stored account
/// final account = await clawbot.loadAccount();
///
/// if (account == null) {
///   // 3a. First run – run the QR login flow
///   await for (final event in clawbot.startQrLogin()) {
///     if (event is QrReadyEvent) showQr(event.qrContent);
///     if (event is QrConfirmedEvent) clawbot.connect(event.account);
///   }
/// } else {
///   // 3b. Already logged in – start receiving messages
///   clawbot.connect(account).listen((msg) {
///     print(msg.textContent);
///   });
/// }
/// ```
///
/// Ready-made Flutter login widgets (`QrLoginWidget`, `showQrLoginDialog`)
/// are provided by the companion package **`weixin_clawbot_flutter`**.
library weixin_clawbot;

export 'src/account_storage.dart';
export 'src/account_store.dart' show AccountStore;
export 'src/cdn_media.dart';
export 'src/client.dart' show ILinkClient, ILinkApiException;
export 'src/message_poller.dart' show MessagePoller, MessageSubscription;
export 'src/models.dart';
export 'src/qr_login.dart';
export 'src/weixin_clawbot.dart';
