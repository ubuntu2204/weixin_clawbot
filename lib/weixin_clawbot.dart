/// WeChat ClawBot package (pure Dart).
///
/// Provides QR-code–based WeChat binding, message receiving via long-poll,
/// and message sending through the WeChat iLink Bot API.
///
/// Runs on **Dart servers, Flutter mobile/desktop and Flutter Web** — the
/// core protocol layer has no Flutter dependency.
///
/// The API surface follows the official OpenClaw Weixin channel plugin
/// (Tencent/openclaw-weixin): every documented endpoint is implemented —
/// `get_bot_qrcode`, `get_qrcode_status`, `getupdates`, `sendmessage`,
/// `getconfig`, `sendtyping`, `msg/notifystart`, `msg/notifystop` and
/// `getuploadurl` (plus the CDN upload/download transports).
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
/// ## Binding, re-binding and un-binding
///
/// - **绑定**: [WeixinClawbot.startQrLogin] — the QR handshake.
/// - **换绑 (re-bind)**: no extra API exists. Scan with a *different* bot; on
///   [QrConfirmedEvent] the facade persists the new account and prunes stored
///   accounts of the same WeChat user, exactly like the official
///   `clearStaleAccountsForUserId`.
/// - **解绑 (un-bind)**: [WeixinClawbot.unbind] — `notifyStop` plus removal of
///   local credentials (the protocol has no server-side unbind endpoint).
/// - [QrAlreadyConnectedEvent] (`binded_redirect`) is a **success**, matching
///   the official `alreadyConnected` outcome.
///
/// Ready-made Flutter login widgets (`QrLoginWidget`, `showQrLoginDialog`)
/// are shown in the bundled example app (`example/lib/qr_login_widget.dart`).
library weixin_clawbot;

export 'src/account_storage.dart';
export 'src/account_store.dart' show AccountStore;
export 'src/bot_agent.dart'
    show sanitizeBotAgent, defaultBotAgent, botAgentMaxLen;
export 'src/cdn_media.dart';
export 'src/client.dart'
    show
        ILinkClient,
        ILinkApiException,
        SendMessageResponse,
        parseWeixinApiJson,
        quoteLosslessIdFields,
        defaultIlinkBaseUrl,
        defaultChannelVersion,
        defaultILinkAppId,
        defaultLongPollTimeout,
        defaultApiTimeout,
        defaultLightTimeout,
        defaultQrPollTimeout;
export 'src/message_poller.dart' show MessagePoller, MessageSubscription;
export 'src/models.dart';
export 'src/qr_login.dart';
export 'src/session_guard.dart';
export 'src/weixin_clawbot.dart';
