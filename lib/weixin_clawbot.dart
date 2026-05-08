/// WeChat ClawBot Flutter package.
///
/// Provides QR-code–based WeChat binding, message receiving via long-poll,
/// and message sending through the WeChat iLink Bot API.
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
///   // 3a. First run – show the QR login widget
///   showDialog(
///     context: context,
///     builder: (_) => QrLoginDialog(
///       clawbot: clawbot,
///       onLoggedIn: (account) { /* start listening */ },
///     ),
///   );
/// } else {
///   // 3b. Already logged in – start receiving messages
///   clawbot.connect(account).listen((msg) {
///     print(msg.textContent);
///   });
/// }
/// ```
library weixin_clawbot;

export 'src/account_store.dart' show AccountStore;
export 'src/client.dart' show ILinkClient, ILinkApiException;
export 'src/message_poller.dart' show MessagePoller, MessageSubscription;
export 'src/models.dart';
export 'src/qr_login.dart';
export 'src/widgets/qr_login_widget.dart';
export 'src/weixin_clawbot.dart';
