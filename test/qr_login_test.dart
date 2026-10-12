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

  group('QrLoginFlow', () {
    // Captured by the mock: every get_qrcode_status URL, in order.
    late List<Uri> pollUrls;
    // Captured by the mock: raw body of every get_bot_qrcode request.
    late List<String> qrcodeBodies;

    MockClient mockClient({
      required List<Map<String, dynamic>> statusResponses,
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
            jsonEncode({'qrcode': 'QRC123', 'qrcode_img_content': 'https://qr'}),
            200,
          );
        }
        if (req.url.path.endsWith('get_qrcode_status')) {
          pollUrls.add(req.url);
          final idx = pollCount < statusResponses.length
              ? pollCount++
              : statusResponses.length - 1;
          return http.Response(jsonEncode(statusResponses[idx]), 200);
        }
        return http.Response('unexpected ${req.url}', 404);
      });
    }

    QrLoginFlow makeFlow(http.Client client, {bool allowRebind = false}) =>
        QrLoginFlow(
          client: ILinkClient(token: '', httpClient: client),
          pollInterval: const Duration(milliseconds: 10),
          localTokenList: const ['tok-old'],
          allowRebind: allowRebind,
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

    test('full happy path with pairing code: wait→scaned→need_verifycode→confirmed',
        () async {
      final client = mockClient(statusResponses: [
        {'status': 'wait'},
        {'status': 'scaned'},
        {'status': 'need_verifycode'},
        {'status': 'wait'},
        {'status': 'confirmed', 'bot_token': 'T', 'ilink_bot_id': 'B@x'},
      ]);

      final flow = makeFlow(client);
      final events = await collect(
        flow,
        onEvent: (e) {
          if (e is QrVerifyCodeRequiredEvent) flow.submitVerifyCode('1234');
        },
      );

      expect(
        events.whereType<QrReadyEvent>().single.qrContent,
        'https://qr',
      );
      expect(events.whereType<QrScannedEvent>(), isNotEmpty);
      expect(events.whereType<QrVerifyCodeRequiredEvent>(), isNotEmpty);
      final confirmed = events.whereType<QrConfirmedEvent>().single;
      expect(confirmed.account.token, 'T');
      expect(confirmed.account.botId, 'B@x');

      // The poll carrying the submitted code must include verify_code.
      final withVerifyCode =
          pollUrls.map((u) => u.queryParameters['verify_code']).whereType<String>();
      expect(withVerifyCode, contains('1234'));
    });

    test('follows scaned_but_redirect to the new host', () async {
      final client = mockClient(statusResponses: [
        {
          'status': 'scaned_but_redirect',
          'redirect_host': 'gz.ilinkai.weixin.qq.com',
        },
        {'status': 'confirmed', 'bot_token': 'T', 'ilink_bot_id': 'B@x'},
      ]);

      final flow = makeFlow(client);
      final events = await collect(flow);

      expect(events.whereType<QrConfirmedEvent>(), isNotEmpty);
      expect(
        pollUrls.last.host,
        'gz.ilinkai.weixin.qq.com',
        reason: 'polling must continue on the redirected host',
      );
    });

    test('verify_code_blocked terminates the flow', () async {
      final client = mockClient(statusResponses: [
        {'status': 'need_verifycode'},
        {'status': 'verify_code_blocked'},
      ]);

      final flow = makeFlow(client);
      final events = await collect(
        flow,
        onEvent: (e) {
          if (e is QrVerifyCodeRequiredEvent) flow.submitVerifyCode('0000');
        },
      );

      expect(events.whereType<QrVerifyCodeBlockedEvent>(), isNotEmpty);
      expect(events.whereType<QrConfirmedEvent>(), isEmpty);
    });

    test('binded_redirect terminates the flow as already bound', () async {
      final client = mockClient(statusResponses: [
        {'status': 'binded_redirect', 'ilink_user_id': 'WX@x'},
      ]);

      final flow = makeFlow(client);
      final events = await collect(flow);

      final bound = events.whereType<QrAlreadyBoundEvent>().single;
      expect(bound.existingWechatUserid, 'WX@x');
      expect(events.whereType<QrConfirmedEvent>(), isEmpty);
    });

    test('binded_redirect with echoed credentials logs in directly', () async {
      final client = mockClient(statusResponses: [
        {
          'status': 'binded_redirect',
          'bot_token': 'T-EXISTING',
          'ilink_bot_id': 'B@x',
          'ilink_user_id': 'WX@x',
        },
      ]);

      final flow = makeFlow(client);
      final events = await collect(flow);

      final confirmed = events.whereType<QrConfirmedEvent>().single;
      expect(confirmed.account.token, 'T-EXISTING');
      expect(confirmed.account.botId, 'B@x');
      expect(confirmed.account.defaultTo, 'WX@x');
      expect(events.whereType<QrAlreadyBoundEvent>(), isEmpty);
    });

    test(
        'allowRebind restarts with a fresh QR code (empty local_token_list) '
        'after binded_redirect and completes on the second scan', () async {
      final client = mockClient(statusResponses: [
        {'status': 'binded_redirect', 'ilink_user_id': 'WX@x'},
        {'status': 'confirmed', 'bot_token': 'T-NEW', 'ilink_bot_id': 'B2@x'},
      ]);

      final flow = makeFlow(client, allowRebind: true);
      final events = await collect(flow);

      final bound = events.whereType<QrAlreadyBoundEvent>().single;
      expect(bound.existingWechatUserid, 'WX@x');
      expect(events.whereType<QrReadyEvent>(), hasLength(2));
      final confirmed = events.whereType<QrConfirmedEvent>().single;
      expect(confirmed.account.token, 'T-NEW');

      // Both QR requests must omit the local token list so the server
      // issues a NEW bot (account hand-over) instead of binded_redirect.
      expect(qrcodeBodies, hasLength(2));
      for (final body in qrcodeBodies) {
        expect(
          (jsonDecode(body) as Map<String, dynamic>)['local_token_list'],
          isEmpty,
        );
      }
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
  });
}
