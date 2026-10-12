import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weixin_clawbot/weixin_clawbot.dart';

void main() {
  group('QrStatusResponse status parsing', () {
    test('parses official extended statuses', () {
      final cases = {
        'wait': QrLoginStatus.wait,
        'scaned': QrLoginStatus.scanned,
        'confirmed': QrLoginStatus.confirmed,
        'expired': QrLoginStatus.expired,
        'scaned_but_redirect': QrLoginStatus.scanedButRedirect,
        'need_verifycode': QrLoginStatus.needVerifyCode,
        'verify_code_blocked': QrLoginStatus.verifyCodeBlocked,
        'binded_redirect': QrLoginStatus.bindedRedirect,
        'whatever': QrLoginStatus.unknown,
      };
      cases.forEach((raw, expected) {
        final resp = QrStatusResponse.fromJson({'status': raw});
        expect(resp.status, expected, reason: raw);
        expect(resp.rawStatus, raw);
      });
    });

    test('parses redirect_host for IDC redirect', () {
      final resp = QrStatusResponse.fromJson({
        'status': 'scaned_but_redirect',
        'redirect_host': 'gz.ilinkai.weixin.qq.com',
      });
      expect(resp.status, QrLoginStatus.scanedButRedirect);
      expect(resp.redirectHost, 'gz.ilinkai.weixin.qq.com');
    });
  });

  group('QrLoginFlow (official waitForWeixinLogin parity)', () {
    // Captured by the mock: every get_qrcode_status URL, in order.
    late List<Uri> pollUrls;
    // Captured by the mock: raw body of every get_bot_qrcode request.
    late List<String> qrcodeBodies;

    MockClient mockClient({
      required List<Map<String, dynamic>> statusResponses,
      int statusStatusCode = 200,
    }) {
      var pollCount = 0;
      pollUrls = <Uri>[];
      qrcodeBodies = <String>[];

      return MockClient((req) async {
        if (req.url.path.endsWith('get_bot_qrcode')) {
          expect(req.method.toUpperCase(), 'POST',
              reason: 'official plugin uses POST');
          qrcodeBodies.add(req.body);
          return http.Response(
            jsonEncode({
              'qrcode': 'QRC123',
              'qrcode_img_content': 'https://qr/${qrcodeBodies.length}',
            }),
            200,
          );
        }
        if (req.url.path.endsWith('get_qrcode_status')) {
          pollUrls.add(req.url);
          final idx = pollCount < statusResponses.length
              ? pollCount++
              : statusResponses.length - 1;
          if (statusStatusCode != 200) {
            return http.Response('gateway timeout', statusStatusCode);
          }
          return http.Response(jsonEncode(statusResponses[idx]), 200);
        }
        return http.Response('unexpected ${req.url}', 404);
      });
    }

    QrLoginFlow makeFlow(http.Client client) => QrLoginFlow(
          client: ILinkClient(token: '', httpClient: client),
          pollInterval: const Duration(milliseconds: 10),
          localTokenList: const ['tok-old'],
        );

    Future<List<QrLoginEvent>> collect(
      QrLoginFlow flow, {
      void Function(QrLoginEvent)? onEvent,
    }) async {
      final events = <QrLoginEvent>[];
      final done = Completer<void>();
      flow.startLogin().listen(
            (e) {
              events.add(e);
              onEvent?.call(e);
            },
            onDone: done.complete,
            onError: (Object e) {
              events.add(QrErrorEvent(e, StackTrace.empty));
              done.complete();
            },
            cancelOnError: true,
          );
      await done.future.timeout(const Duration(seconds: 5));
      return events;
    }

    test(
        'full happy path with pairing code: wait→scaned→need_verifycode→confirmed',
        () async {
      final client = mockClient(statusResponses: [
        {'status': 'wait'},
        {'status': 'scaned'},
        {'status': 'need_verifycode'},
        {'status': 'wait'},
        {
          'status': 'confirmed',
          'bot_token': 'T',
          'ilink_bot_id': 'B@x',
          'ilink_user_id': 'WX@x',
          'baseurl': 'https://gz.ilinkai.weixin.qq.com',
        },
      ]);

      final flow = makeFlow(client);
      final events = await collect(
        flow,
        onEvent: (e) {
          if (e is QrVerifyCodeRequiredEvent) flow.submitVerifyCode('1234');
        },
      );

      expect(events.whereType<QrReadyEvent>().single.qrContent, 'https://qr/1');
      expect(events.whereType<QrScannedEvent>(), hasLength(1));
      expect(events.whereType<QrVerifyCodeRequiredEvent>(), hasLength(1));
      final confirmed = events.whereType<QrConfirmedEvent>().single;
      expect(confirmed.account.token, 'T');
      expect(confirmed.account.botId, 'B@x');
      expect(confirmed.account.id, 'B@x');
      expect(confirmed.account.defaultTo, 'WX@x');
      // The server-assigned baseurl is stored, like saveWeixinAccount().
      expect(confirmed.account.baseUrl, 'https://gz.ilinkai.weixin.qq.com');
      expect(confirmed.account.savedAtMs, isNotNull);

      // The poll carrying the submitted code must include verify_code.
      final withVerifyCode = pollUrls
          .map((u) => u.queryParameters['verify_code'])
          .whereType<String>();
      expect(withVerifyCode, contains('1234'));
    });

    test('always sends the local token list (official getLocalBotTokenList)',
        () async {
      final client = mockClient(statusResponses: [
        {'status': 'confirmed', 'bot_token': 'T', 'ilink_bot_id': 'B@x'},
      ]);

      await collect(makeFlow(client));

      final body = jsonDecode(qrcodeBodies.single) as Map<String, dynamic>;
      expect(body['local_token_list'], equals(['tok-old']));
    });

    test('follows scaned_but_redirect to the new host', () async {
      final client = mockClient(statusResponses: [
        {
          'status': 'scaned_but_redirect',
          'redirect_host': 'gz.ilinkai.weixin.qq.com',
        },
        {'status': 'confirmed', 'bot_token': 'T', 'ilink_bot_id': 'B@x'},
      ]);

      final events = await collect(makeFlow(client));

      expect(events.whereType<QrConfirmedEvent>(), isNotEmpty);
      expect(
        pollUrls.last.host,
        'gz.ilinkai.weixin.qq.com',
        reason: 'polling must continue on the redirected host',
      );
      // QR fetches keep targeting the fixed host even after the redirect
      // (official refreshQRCode always uses FIXED_BASE_URL).
      expect(qrcodeBodies, hasLength(1));
    });

    test('binded_redirect is a terminal SUCCESS, not an error', () async {
      final client = mockClient(statusResponses: [
        {'status': 'binded_redirect', 'ilink_user_id': 'WX@x'},
      ]);

      final events = await collect(makeFlow(client));

      final connected = events.whereType<QrAlreadyConnectedEvent>().single;
      expect(connected.wechatUserId, 'WX@x');
      expect(events.whereType<QrConfirmedEvent>(), isEmpty);
      // Official never reads bot_token from a binded_redirect response.
      final echoing = mockClient(statusResponses: [
        {
          'status': 'binded_redirect',
          'bot_token': 'T-ECHO',
          'ilink_bot_id': 'B@x',
        },
      ]);
      final echoed = await collect(makeFlow(echoing));
      expect(echoed.whereType<QrConfirmedEvent>(), isEmpty);
      expect(echoed.whereType<QrAlreadyConnectedEvent>(), hasLength(1));
    });

    test('expired refreshes the QR code automatically (non-terminal)',
        () async {
      final client = mockClient(statusResponses: [
        {'status': 'expired'},
        {'status': 'confirmed', 'bot_token': 'T', 'ilink_bot_id': 'B@x'},
      ]);

      final events = await collect(makeFlow(client));

      expect(events.whereType<QrExpiredEvent>(), hasLength(1));
      final refreshed = events.whereType<QrRefreshedEvent>().single;
      expect(refreshed.attempt, 2);
      expect(refreshed.maxAttempts, maxQrRefreshCount);
      // A second, freshly rendered code was announced.
      expect(events.whereType<QrReadyEvent>(), hasLength(2));
      expect(events.whereType<QrReadyEvent>().last.generation, 2);
      expect(events.whereType<QrConfirmedEvent>(), hasLength(1));
      expect(qrcodeBodies, hasLength(2));
    });

    test('stops after the official refresh budget (3 codes max)', () async {
      final client = mockClient(statusResponses: [
        {'status': 'expired'},
        {'status': 'expired'},
        {'status': 'expired'},
        {'status': 'expired'},
      ]);

      final events = await collect(makeFlow(client));

      // Codes 2 and 3 are refreshed; on the third expiry the budget is gone.
      expect(events.whereType<QrReadyEvent>(), hasLength(3));
      expect(events.whereType<QrRefreshedEvent>().map((e) => e.attempt),
          equals([2, 3]));
      final stopped = events.whereType<QrTooManyQrResetsEvent>().single;
      expect(stopped.reason, contains('二维码多次失效'));
      expect(events.whereType<QrConfirmedEvent>(), isEmpty);
    });

    test('verify_code_blocked refreshes instead of terminating', () async {
      final client = mockClient(statusResponses: [
        {'status': 'need_verifycode'},
        {'status': 'verify_code_blocked'},
        {'status': 'confirmed', 'bot_token': 'T', 'ilink_bot_id': 'B@x'},
      ]);

      final flow = makeFlow(client);
      final events = await collect(
        flow,
        onEvent: (e) {
          if (e is QrVerifyCodeRequiredEvent) flow.submitVerifyCode('0000');
        },
      );

      expect(events.whereType<QrVerifyCodeBlockedEvent>(), hasLength(1));
      expect(events.whereType<QrRefreshedEvent>(), hasLength(1));
      expect(events.whereType<QrConfirmedEvent>(), hasLength(1));
    });

    test('isRetry is set when server asks for the code again', () async {
      final client = mockClient(statusResponses: [
        {'status': 'need_verifycode'},
        {'status': 'need_verifycode'},
      ]);

      final flow = makeFlow(client);
      final events = <QrLoginEvent>[];
      final done = Completer<void>();
      final sub = flow.startLogin().listen(
        (e) {
          events.add(e);
          if (e is QrVerifyCodeRequiredEvent) flow.submitVerifyCode('9999');
          if (events.whereType<QrVerifyCodeRequiredEvent>().length == 2) {
            done.complete();
          }
        },
        onDone: done.complete,
      );
      await done.future.timeout(const Duration(seconds: 5));
      await sub.cancel();

      final asks = events.whereType<QrVerifyCodeRequiredEvent>().toList();
      expect(asks, hasLength(2));
      expect(asks.first.isRetry, isFalse);
      expect(asks.last.isRetry, isTrue);
    });

    test('scaned is announced only once per QR code', () async {
      final client = mockClient(statusResponses: [
        {'status': 'scaned'},
        {'status': 'scaned'},
        {'status': 'scaned'},
        {'status': 'confirmed', 'bot_token': 'T', 'ilink_bot_id': 'B@x'},
      ]);

      final events = await collect(makeFlow(client));

      expect(events.whereType<QrScannedEvent>(), hasLength(1));
    });

    test('confirmed without ilink_bot_id is an error', () async {
      final client = mockClient(statusResponses: [
        {'status': 'confirmed', 'bot_token': 'T'},
      ]);

      final events = await collect(makeFlow(client));

      expect(events.whereType<QrConfirmedEvent>(), isEmpty);
      final error = events.whereType<QrErrorEvent>().single;
      expect('${error.error}', contains('ilink_bot_id'));
    });

    test('HTTP failures while polling are treated as wait and retried',
        () async {
      // A 524-style gateway error must not abort the login (official converts
      // every poll error into `wait`).
      var served = false;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('get_bot_qrcode')) {
          return http.Response(
            jsonEncode(
                {'qrcode': 'QRC123', 'qrcode_img_content': 'https://qr'}),
            200,
          );
        }
        if (!served) {
          served = true;
          return http.Response('Cloudflare 524', 524);
        }
        return http.Response(
          jsonEncode({
            'status': 'confirmed',
            'bot_token': 'T',
            'ilink_bot_id': 'B@x',
          }),
          200,
        );
      });

      final events = await collect(makeFlow(client));

      expect(events.whereType<QrConfirmedEvent>(), hasLength(1));
      expect(events.whereType<QrErrorEvent>(), isEmpty);
    });

    test('loginTimeout ends the flow with QrLoginTimeoutEvent', () async {
      final client = mockClient(statusResponses: [
        {'status': 'wait'},
      ]);

      final flow = QrLoginFlow(
        client: ILinkClient(token: '', httpClient: client),
        pollInterval: const Duration(milliseconds: 10),
        loginTimeout: const Duration(milliseconds: 120),
      );
      final events = await collect(flow);

      expect(events.whereType<QrLoginTimeoutEvent>(), hasLength(1));
    });
  });
}
