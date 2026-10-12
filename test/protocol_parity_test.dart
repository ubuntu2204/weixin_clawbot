/// Protocol-parity tests for the endpoints and wire details that mirror the
/// official openclaw-weixin plugin (`src/api/api.ts`, `src/api/types.ts`,
/// `src/auth/accounts.ts`, `src/cdn/upload.ts`, `src/api/session-guard.ts`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:weixin_clawbot/weixin_clawbot.dart';

/// In-memory [AccountStorage] so store behaviour is testable everywhere.
class MemoryAccountStorage implements AccountStorage {
  List<String> entries = [];

  @override
  Future<List<String>> read() async => entries;

  @override
  Future<void> write(List<String> entries) async =>
      Future.sync(() => this.entries = List.of(entries));
}

ClawBotAccount account(String id, String token, String? user, int savedAt) =>
    ClawBotAccount(
      id: id,
      token: token,
      baseUrl: 'https://ilinkai.weixin.qq.com',
      botId: id,
      defaultTo: user,
      savedAtMs: savedAt,
    );

void main() {
  group('sanitizeBotAgent (official api.ts)', () {
    test('passes valid UA-style tokens through unchanged', () {
      for (final raw in const [
        'MyBot/1.2.0',
        'MyBot/1.2.0 (region=cn;env=prod)',
        'MyBot/1.2.0 LangChain/0.3.5',
        'MyBot/1.2.0-rc.1+build.5',
      ]) {
        expect(sanitizeBotAgent(raw), raw, reason: raw);
      }
    });

    test('falls back to OpenClaw when empty or unparseable', () {
      expect(sanitizeBotAgent(null), defaultBotAgent);
      expect(sanitizeBotAgent(''), defaultBotAgent);
      expect(sanitizeBotAgent('   '), defaultBotAgent);
      expect(sanitizeBotAgent('not-a-token'), defaultBotAgent);
      expect(sanitizeBotAgent('中文/1.0'), defaultBotAgent);
    });

    test('drops invalid tokens but keeps the valid ones', () {
      expect(sanitizeBotAgent('MyBot/1.0.0 broken token/'), 'MyBot/1.0.0');
    });

    test('drops a comment containing forbidden parentheses', () {
      // A comment may not contain ( or ) → the product is kept bare.
      expect(sanitizeBotAgent('MyBot/1.0.0 (a(b)'), 'MyBot/1.0.0');
    });

    test('truncates to 256 bytes by dropping trailing tokens', () {
      final many = List.generate(60, (i) => 'Bot$i/1.0').join(' ');
      final out = sanitizeBotAgent(many);
      expect(utf8.encode(out).length, lessThanOrEqualTo(botAgentMaxLen));
      expect(out, startsWith('Bot0/1.0'));
      expect(out.split(' ').length, lessThan(60));
    });
  });

  group('uint64 lossless parsing (official parseWeixinApiJson)', () {
    test('quotes message_id before decoding', () {
      // 9007199254740993 is 2^53 + 1: not representable as a JS double.
      const raw = '{"message_id": 9007199254740993, "seq": 7}';
      final quoted = quoteLosslessIdFields(raw);
      expect(quoted, contains('"message_id": "9007199254740993"'));
      final parsed = parseWeixinApiJson(raw);
      expect(parsed['message_id'], '9007199254740993');
      expect(parsed['seq'], 7);
    });

    test('never rewrites text that merely looks like a key', () {
      const raw = '{"note": "message_id: 12345", "ret": 0}';
      expect(parseWeixinApiJson(raw)['note'], 'message_id: 12345');
    });

    test('leaves null and string values untouched', () {
      for (final raw in const [
        '{"message_id":null}',
        '{"message_id":"already-a-string"}',
      ]) {
        expect(jsonEncode(parseWeixinApiJson(raw)), raw, reason: raw);
      }
    });

    test('quotes negative ids too (official scanner behaviour)', () {
      // The official scanner quotes any integer literal, including negatives,
      // because the field is declared uint64/string on the wire.
      expect(
        jsonEncode(parseWeixinApiJson('{"message_id":-1}')),
        '{"message_id":"-1"}',
      );
    });

    test('getupdates keeps msg ids as lossless strings', () async {
      final client = MockClient((req) async {
        return http.Response(
          '{"ret":0,"msgs":[{"seq":1,"message_id":9007199254740993,'
          '"from_user_id":"u@x","to_user_id":"b@x","client_id":"c",'
          '"create_time_ms":1,"message_type":1,"message_state":2,'
          '"item_list":[{"type":1,"msg_id":18014398509481985,'
          '"text_item":{"text":"hi"}}]}],"get_updates_buf":"next"}',
          200,
        );
      });
      final ilink = ILinkClient(token: 'T', httpClient: client);
      addTearDown(ilink.dispose);

      final resp = await ilink.getUpdates(getUpdatesBuf: '');
      final msg = resp.messages.single;
      expect(msg.messageId, '9007199254740993');
      expect(msg.items.single.msgId, '18014398509481985');
      expect(resp.getUpdatesBuf, 'next');
    });
  });

  group('request envelope (headers, base_info, paths)', () {
    late List<http.Request> captured;
    late ILinkClient ilink;

    setUp(() {
      captured = [];
      ilink = ILinkClient(
        token: 'BOT-TOKEN',
        botAgent: 'MyBot/1.2.0',
        skRouteTag: '42',
        httpClient: MockClient((req) async {
          captured.add(req);
          return http.Response('{"ret":0}', 200);
        }),
      );
    });
    tearDown(() => ilink.dispose());

    test('bot requests carry the official headers', () async {
      await ilink.sendText(toUserId: 'u@x', text: 'hi');
      final h = captured.single.headers;
      expect(h['authorization'], 'Bearer BOT-TOKEN');
      expect(h['authorizationtype'], 'ilink_bot_token');
      expect(h['ilink-app-id'], defaultILinkAppId);
      expect(h['ilink-app-clientversion'], '65538'); // 1.0.2 → 0x00010002
      expect(h['skroutetag'], '42');
      expect(h['x-wechat-uin'], isNotNull);
      expect(h['content-type'], contains('application/json'));
    });

    test('QR status polling sends only the app headers', () async {
      await ilink.pollQrStatus('QRC');
      final h = captured.single.headers;
      expect(h['ilink-app-id'], defaultILinkAppId);
      expect(h['ilink-app-clientversion'], '65538');
      expect(h['authorization'], isNull);
      expect(h['authorizationtype'], isNull);
      expect(h['x-wechat-uin'], isNull);
    });

    test('base_info always contains channel_version and bot_agent', () async {
      await ilink.getUpdates(getUpdatesBuf: 'buf');
      final body = jsonDecode(captured.single.body) as Map<String, dynamic>;
      expect(body['base_info'], {
        'channel_version': defaultChannelVersion,
        'bot_agent': 'MyBot/1.2.0',
      });
    });

    test('bot_agent falls back to OpenClaw when not declared', () async {
      final local = <http.Request>[];
      final plain = ILinkClient(
        token: 'T',
        httpClient: MockClient((req) async {
          local.add(req);
          return http.Response('{"ret":0}', 200);
        }),
      );
      addTearDown(plain.dispose);

      await plain.notifyStart();
      final body = jsonDecode(local.single.body) as Map<String, dynamic>;
      expect(body['base_info']['bot_agent'], defaultBotAgent);
    });

    test('get_bot_qrcode omits Authorization and base_info', () async {
      await ilink.fetchLoginQrCode(localTokenList: const ['t1']);
      final req = captured.single;
      expect(req.url.path, '/ilink/bot/get_bot_qrcode');
      expect(req.url.queryParameters['bot_type'], '3');
      expect(req.headers['authorization'], isNull);
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body, {
        'local_token_list': ['t1']
      });
    });

    test('every official endpoint path is used verbatim', () async {
      await ilink.notifyStart();
      await ilink.notifyStop();
      await ilink.getConfig(ilinkUserId: 'u@x');
      await ilink.sendTyping(ilinkUserId: 'u@x', typingTicket: 'ticket');
      await ilink.getUploadUrl(const GetUploadUrlRequest(
        fileKey: 'k',
        mediaType: UploadMediaType.image,
        toUserId: 'u@x',
        rawSize: 1,
        rawFileMd5: 'm',
        fileSize: 16,
        aesKeyHex: '0123456789abcdef0123456789abcdef',
      ));
      await ilink.getUpdates(getUpdatesBuf: '');

      expect(
        captured.map((r) => r.url.path),
        [
          '/ilink/bot/msg/notifystart',
          '/ilink/bot/msg/notifystop',
          '/ilink/bot/getconfig',
          '/ilink/bot/sendtyping',
          '/ilink/bot/getuploadurl',
          '/ilink/bot/getupdates',
        ],
      );
    });

    test('sendmessage envelope matches the official text builder', () async {
      await ilink.sendText(
        toUserId: 'u@x',
        text: 'Hello',
        contextToken: 'ctx',
        runId: 'run-1',
      );
      final body = jsonDecode(captured.single.body) as Map<String, dynamic>;
      final msg = body['msg'] as Map<String, dynamic>;
      // Official senders always send an empty from_user_id.
      expect(msg['from_user_id'], '');
      expect(msg['to_user_id'], 'u@x');
      expect(msg['message_type'], MessageType.bot.value);
      expect(msg['message_state'], MessageState.finish.value);
      expect(msg['context_token'], 'ctx');
      expect(msg['run_id'], 'run-1');
      expect(msg['client_id'], startsWith('weixin-clawbot-'));
      expect(msg['item_list'], [
        {
          'type': 1,
          'text_item': {'text': 'Hello'}
        }
      ]);
    });

    test('getConfig / sendTyping payloads use the official field names',
        () async {
      await ilink.getConfig(ilinkUserId: 'u@x', contextToken: 'ctx');
      final cfg = jsonDecode(captured[0].body) as Map<String, dynamic>;
      expect(cfg['ilink_user_id'], 'u@x');
      expect(cfg['context_token'], 'ctx');

      await ilink.sendTyping(
        ilinkUserId: 'u@x',
        typingTicket: 'tk',
        status: TypingStatus.cancel,
      );
      final typing = jsonDecode(captured[1].body) as Map<String, dynamic>;
      expect(typing['ilink_user_id'], 'u@x');
      expect(typing['typing_ticket'], 'tk');
      expect(typing['status'], 2);
    });

    test('sendMessage throws on non-zero ret; wrappers report it', () async {
      final limited = ILinkClient(
        token: 'T',
        httpClient: MockClient((_) async =>
            http.Response('{"ret":-2,"errmsg":"rate limited"}', 200)),
      );
      addTearDown(limited.dispose);

      await expectLater(
        limited.sendMessage(limited.buildOutbound(
          toUserId: 'u@x',
          items: [MessageItem.text('x')],
        )),
        throwsA(isA<ILinkApiException>()),
      );

      final result = await limited.sendText(toUserId: 'u@x', text: 'x');
      expect(result.ok, isFalse);
      expect(result.error, contains('ret=-2'));
    });

    test('getUpdates timeout yields an empty result keeping the cursor',
        () async {
      final slow = ILinkClient(
        token: 'T',
        httpClient: MockClient((req) async {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          return http.Response('{"ret":0}', 200);
        }),
      );
      addTearDown(slow.dispose);

      final resp = await slow.getUpdates(
        getUpdatesBuf: 'cursor-keep',
        timeout: const Duration(milliseconds: 10),
      );
      expect(resp.isOk, isTrue);
      expect(resp.messages, isEmpty);
      expect(resp.getUpdatesBuf, 'cursor-keep');
    });

    test('typing ticket comes from getconfig ret==0 only', () async {
      final poller = _pollerWith((req) async {
        if (req.url.path.endsWith('getconfig')) {
          return http.Response('{"ret":0,"typing_ticket":"TK1"}', 200);
        }
        return http.Response('{"ret":0}', 200);
      });
      expect(await poller.typingTicketFor('u@x'), 'TK1');

      final failing = _pollerWith((req) async {
        if (req.url.path.endsWith('getconfig')) {
          return http.Response('{"ret":-5,"errmsg":"nope"}', 200);
        }
        return http.Response('{"ret":0}', 200);
      });
      expect(await failing.typingTicketFor('u@x'), isNull);
      expect(await failing.showTyping('u@x'), isFalse);
    });
  });

  group('CDN upload (official cdn/upload.ts + cdn-upload.ts)', () {
    test('uploads encrypted bytes and returns the CDN download param',
        () async {
      http.Request? uploadReq;
      Map<String, dynamic>? uploadUrlBody;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('getuploadurl')) {
          uploadUrlBody = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(jsonEncode({'upload_param': 'up-param'}), 200);
        }
        uploadReq = req;
        return http.Response('', 200,
            headers: {'x-encrypted-param': 'download-param'});
      });
      final ilink = ILinkClient(token: 'T', httpClient: client);
      final uploader = CdnMediaUploader(client: ilink, httpClient: client);
      addTearDown(() {
        ilink.dispose();
        uploader.dispose();
      });

      final plain = Uint8List.fromList(List.generate(50, (i) => i));
      final out = await uploader.upload(
        bytes: plain,
        mediaType: UploadMediaType.image,
        toUserId: 'u@x',
      );

      expect(out.downloadEncryptQueryParam, 'download-param');
      expect(out.rawSize, 50);
      expect(out.ciphertextSize, aesEcbPaddedSize(50)); // 50 + 16 - 2 = 64
      expect(out.aesKeyHex, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(out.fileKey, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(out.rawMd5, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(out.aesKeyBase64, base64AesKeyFromHex(out.aesKeyHex));

      // Upload transport: POST to the built CDN URL, octet-stream ciphertext.
      expect(uploadReq!.method, 'POST');
      expect(
        uploadReq!.url.toString(),
        'https://novac2c.cdn.weixin.qq.com/c2c/upload'
        '?encrypted_query_param=up-param&filekey=${out.fileKey}',
      );
      expect(uploadReq!.headers['content-type'], 'application/octet-stream');
      expect(uploadReq!.bodyBytes.length, 64);
      // The bytes round-trip through the downloader's decrypt path.
      expect(
        aesEcbDecrypt(Uint8List.fromList(uploadReq!.bodyBytes),
            hexToBytes(out.aesKeyHex)),
        equals(plain),
      );

      // getuploadurl request uses the official field names.
      expect(uploadUrlBody!['media_type'], UploadMediaType.image.value);
      expect(uploadUrlBody!['no_need_thumb'], isTrue);
      expect(uploadUrlBody!['rawsize'], 50);
      expect(uploadUrlBody!['filesize'], 64);
      expect(uploadUrlBody!['aeskey'], out.aesKeyHex);
      expect(uploadUrlBody!['filekey'], out.fileKey);
    });

    test('4xx aborts immediately without retries', () async {
      var calls = 0;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('getuploadurl')) {
          return http.Response(jsonEncode({'upload_param': 'up'}), 200);
        }
        calls++;
        return http.Response('', 403, headers: {'x-error-message': 'denied'});
      });
      final ilink = ILinkClient(token: 'T', httpClient: client);
      final uploader = CdnMediaUploader(client: ilink, httpClient: client);
      addTearDown(() {
        ilink.dispose();
        uploader.dispose();
      });

      CdnUploadException? caught;
      try {
        await uploader.upload(
          bytes: Uint8List.fromList([1, 2, 3]),
          mediaType: UploadMediaType.file,
          toUserId: 'u@x',
        );
      } on CdnUploadException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught?.statusCode, 403);
      expect(caught?.message, contains('denied'));
      expect(calls, 1, reason: 'client errors are never retried');
    });

    test('server errors are retried up to 3 attempts in total', () async {
      var uploadCalls = 0;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('getuploadurl')) {
          return http.Response(jsonEncode({'upload_param': 'up'}), 200);
        }
        uploadCalls++;
        if (uploadCalls < 3) return http.Response('', 502);
        return http.Response('', 200,
            headers: {'x-encrypted-param': 'ok-param'});
      });
      final ilink = ILinkClient(token: 'T', httpClient: client);
      final uploader = CdnMediaUploader(client: ilink, httpClient: client);
      addTearDown(() {
        ilink.dispose();
        uploader.dispose();
      });

      final out = await uploader.upload(
        bytes: Uint8List.fromList([1]),
        mediaType: UploadMediaType.video,
        toUserId: 'u@x',
      );
      expect(out.downloadEncryptQueryParam, 'ok-param');
      expect(uploadCalls, 3);
    });

    test('missing x-encrypted-param fails after all attempts', () async {
      var calls = 0;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('getuploadurl')) {
          return http.Response(jsonEncode({'upload_param': 'up'}), 200);
        }
        calls++;
        return http.Response('', 200); // no header at all
      });
      final ilink = ILinkClient(token: 'T', httpClient: client);
      final uploader = CdnMediaUploader(client: ilink, httpClient: client);
      addTearDown(() {
        ilink.dispose();
        uploader.dispose();
      });

      await expectLater(
        uploader.upload(
          bytes: Uint8List.fromList([1]),
          mediaType: UploadMediaType.image,
          toUserId: 'u@x',
        ),
        throwsA(isA<CdnUploadException>()),
      );
      expect(calls, CdnMediaUploader.uploadMaxRetries);
    });

    test('upload_full_url takes precedence and can be proxied', () async {
      Uri? uploadUrl;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('getuploadurl')) {
          return http.Response(
            jsonEncode({'upload_full_url': 'https://cdn.example.com/u'}),
            200,
          );
        }
        uploadUrl = req.url;
        return http.Response('', 200, headers: {'x-encrypted-param': 'p'});
      });
      final ilink = ILinkClient(token: 'T', httpClient: client);
      final uploader = CdnMediaUploader(
        client: ilink,
        httpClient: client,
        // Flutter Web rewrites absolute CDN URLs onto the local proxy.
        uploadUrlRewriter: (url) =>
            'http://proxy:3001/cdnfull/${Uri.parse(url).host}/u',
      );
      addTearDown(() {
        ilink.dispose();
        uploader.dispose();
      });

      await uploader.upload(
        bytes: Uint8List.fromList([1]),
        mediaType: UploadMediaType.image,
        toUserId: 'u@x',
      );
      expect(
          uploadUrl.toString(), 'http://proxy:3001/cdnfull/cdn.example.com/u');
    });

    test('no upload target at all is an error', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('getuploadurl')) {
          return http.Response('{}', 200);
        }
        return http.Response('should not be reached', 500);
      });
      final ilink = ILinkClient(token: 'T', httpClient: client);
      final uploader = CdnMediaUploader(client: ilink, httpClient: client);
      addTearDown(() {
        ilink.dispose();
        uploader.dispose();
      });

      await expectLater(
        uploader.upload(
          bytes: Uint8List.fromList([1]),
          mediaType: UploadMediaType.image,
          toUserId: 'u@x',
        ),
        throwsA(isA<CdnUploadException>()),
      );
    });
  });

  group('Account store — re-bind (换绑) rules from official accounts.ts', () {
    AccountStore storeWith(List<ClawBotAccount> accounts) {
      final storage = MemoryAccountStorage()
        ..entries = [for (final a in accounts) jsonEncode(a.toJson())];
      return AccountStore(storage: storage);
    }

    test('botTokenList is newest-first and capped at ten', () async {
      final store = storeWith([
        for (var i = 1; i <= 13; i++)
          account('b$i@x', 'tok$i', 'u$i@x', i * 10),
      ]);
      final list = await store.botTokenList();
      expect(list, hasLength(AccountStore.maxLocalTokenList));
      expect(list.first, 'tok13', reason: 'newest first');
      expect(list, [for (var i = 13; i > 3; i--) 'tok$i']);
    });

    test('botTokenList skips tokenless entries', () async {
      final store = storeWith([
        account('b1@x', '', 'u@x', 5),
        account('b2@x', 'tok2', 'u@x', 1),
      ]);
      expect(await store.botTokenList(), ['tok2']);
    });

    test('removeStaleForWechatUser prunes only the same WeChat user', () async {
      final store = storeWith([
        account('old1@x', 't1', 'wx@x', 1),
        account('old2@x', 't2', 'other@x', 2),
        account('new@x', 't3', 'wx@x', 3),
      ]);

      final removed = await store.removeStaleForWechatUser(
        keepAccountId: 'new@x',
        wechatUserId: 'wx@x',
      );

      expect(removed, ['old1@x']);
      final kept = await store.loadAll();
      expect(kept.map((a) => a.id), ['old2@x', 'new@x']);
    });

    test('removeStaleForWechatUser is a no-op without a user id', () async {
      final store = storeWith([account('a@x', 't', null, 1)]);
      expect(
        await store.removeStaleForWechatUser(
            keepAccountId: 'b@x', wechatUserId: null),
        isEmpty,
      );
      expect(await store.loadAll(), hasLength(1));
    });

    test('save stamps savedAtMs; clearContextToken keeps the account',
        () async {
      final store = AccountStore(storage: MemoryAccountStorage());
      await store
          .save(account('a@x', 't', 'wx@x', 0).copyWith(contextToken: 'ctx'));
      expect((await store.load('a@x'))!.savedAtMs, isNonZero);

      await store.clearContextToken('a@x');
      final cleared = (await store.load('a@x'))!;
      expect(cleared.contextToken, isNull);
      expect(cleared.token, 't');
      expect(cleared.defaultTo, 'wx@x');
    });
  });

  group('session guard (official -14 handling)', () {
    test('pause / assertActive / remaining / resume with lazy expiry',
        () async {
      final guard = SessionGuard();
      expect(guard.isPaused('a'), isFalse);

      guard.pause('a', duration: const Duration(milliseconds: 40));
      expect(guard.isPaused('a'), isTrue);
      expect(guard.remaining('a').inMilliseconds, greaterThan(0));
      expect(() => guard.assertActive('a'),
          throwsA(isA<SessionPausedException>()));

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(guard.isPaused('a'), isFalse, reason: 'lazy expiry');

      guard.pause('b');
      guard.resume('b');
      expect(guard.isPaused('b'), isFalse);
    });

    test('a -14 getupdates pauses the account and stops polling', () async {
      var requests = 0;
      final guard = SessionGuard();
      final ilink = ILinkClient(
        token: 'STALE',
        httpClient: MockClient((req) async {
          requests++;
          return http.Response('{"ret":-14,"errmsg":"session timeout"}', 200);
        }),
      );
      final poller = MessagePoller(
        client: ilink,
        account: account('b@x', 'STALE', 'wx@x', 1),
        sessionGuard: guard,
      );
      addTearDown(() {
        poller.stop();
        ilink.dispose();
      });

      final errors = <Object>[];
      final done = Completer<void>();
      poller.start().listen((_) {}, onError: (Object e) {
        errors.add(e);
        if (!done.isCompleted) done.complete();
      });
      await done.future.timeout(const Duration(seconds: 5));

      expect(errors.single, isA<SessionPausedException>());
      expect(guard.isPaused('b@x'), isTrue);
      expect(poller.isSessionPaused, isTrue);
      expect(
        poller.sessionPauseRemaining,
        greaterThanOrEqualTo(const Duration(minutes: 59)),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(requests, 1,
          reason: 'the loop must stop, not retry with a dead token');
    });
  });

  group('unbind (解绑) and notify lifecycle', () {
    test('unbind sends notifyStop and deletes the stored credentials',
        () async {
      final paths = <String>[];
      final store = AccountStore(storage: MemoryAccountStorage());
      await store
          .save(account('b@x', 'T', 'wx@x', 1).copyWith(contextToken: 'ctx'));

      final clawbot = WeixinClawbot(
        store: store,
        httpClient: MockClient((req) async {
          paths.add(req.url.path);
          return http.Response('{"ret":0}', 200);
        }),
      );
      addTearDown(clawbot.dispose);

      final removed = await clawbot.unbind(accountId: 'b@x');

      expect(removed, ['b@x']);
      expect(paths, contains('/ilink/bot/msg/notifystop'));
      expect(await clawbot.loadAllAccounts(), isEmpty);
    });

    test('connect sends notifystart like the official startAccount', () async {
      final paths = <String>[];
      final clawbot = WeixinClawbot(
        store: AccountStore(storage: MemoryAccountStorage()),
        httpClient: slowPollingClient(paths),
      );
      addTearDown(clawbot.dispose);

      final sub =
          clawbot.connect(account('b@x', 'T', 'wx@x', 1)).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await sub.cancel();

      expect(paths, contains('/ilink/bot/msg/notifystart'));
      expect(paths, contains('/ilink/bot/getupdates'));
    });

    test('disconnect sends notifystop but keeps the credentials', () async {
      final paths = <String>[];
      final store = AccountStore(storage: MemoryAccountStorage());
      await store.save(account('b@x', 'T', 'wx@x', 1));
      final clawbot = WeixinClawbot(
        store: store,
        httpClient: slowPollingClient(paths),
      );
      addTearDown(clawbot.dispose);

      clawbot.connect(account('b@x', 'T', 'wx@x', 1)).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await clawbot.disconnect('b@x');

      expect(paths, contains('/ilink/bot/msg/notifystop'));
      expect(await clawbot.loadAllAccounts(), hasLength(1));
    });

    test('a confirmed re-bind prunes the previous account of that user',
        () async {
      final store = AccountStore(storage: MemoryAccountStorage());
      await store.save(account('old@x', 'OLD', 'wx@x', 1));

      final clawbot = WeixinClawbot(
        store: store,
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('get_bot_qrcode')) {
            return http.Response(
              jsonEncode({'qrcode': 'Q', 'qrcode_img_content': 'https://qr'}),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'status': 'confirmed',
              'bot_token': 'NEW',
              'ilink_bot_id': 'new@x',
              'ilink_user_id': 'wx@x',
            }),
            200,
          );
        }),
      );
      addTearDown(clawbot.dispose);

      final session = await clawbot.startQrLoginSession();
      final confirmed = Completer<ClawBotAccount>();
      session.events.listen((e) {
        if (e is QrConfirmedEvent && !confirmed.isCompleted) {
          confirmed.complete(e.account);
        }
      });
      final acct = await confirmed.future.timeout(const Duration(seconds: 5));
      // Let the facade's async persist + prune finish.
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(acct.token, 'NEW');
      expect(
        (await clawbot.loadAllAccounts()).map((a) => a.id),
        ['new@x'],
        reason: '换绑 keeps only the newest account for a WeChat user',
      );
    });

    test('facade sendMedia path surfaces upload failures, never throws',
        () async {
      final clawbot = WeixinClawbot(
        store: AccountStore(storage: MemoryAccountStorage()),
        httpClient: slowPollingClient(
          [],
          getUpdatesBody: '{"ret":0,"msgs":[]}',
        ),
      );
      addTearDown(() async {
        clawbot.disconnect('b@x', notify: false);
        await clawbot.dispose();
      });

      final acct = account('b@x', 'T', 'wx@x', 1);
      clawbot.connect(acct).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 40));

      final result = await clawbot.sendImage(
        bytes: Uint8List.fromList([1, 2, 3]),
        toUserId: 'wx@x',
        accountId: 'b@x',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('upload'));
    });
  });

  group('outbound / inbound message models', () {
    test('media items use the official field spellings', () {
      const hex = '00112233445566778899aabbccddeeff';
      final image = MessageItem.image(
        encryptQueryParam: 'dp',
        aesKeyHex: hex,
        midSize: 64,
      ).toJson();
      expect(image['type'], MessageItemType.image.value);
      final imageItem = image['image_item'] as Map;
      expect(imageItem['media'], {
        'encrypt_query_param': 'dp',
        'aes_key': base64AesKeyFromHex(hex),
      });
      expect(imageItem['aeskey'], hex);
      expect(imageItem['mid_size'], 64);

      final file = MessageItem.file(
        encryptQueryParam: 'dp',
        aesKeyHex: hex,
        fileName: 'a.pdf',
        rawSize: 12345,
      ).toJson();
      // Official file sender: len is the PLAINTEXT size as a decimal string.
      expect((file['file_item'] as Map)['len'], '12345');
      expect((file['file_item'] as Map)['file_name'], 'a.pdf');

      final video = MessageItem.video(
        encryptQueryParam: 'dp',
        aesKeyHex: hex,
        videoSize: 999,
      ).toJson();
      expect((video['video_item'] as Map)['video_size'], 999);
    });

    test('inbound tool-call and quoted items are parsed', () {
      final msg = WeixinMessage.fromJson({
        'from_user_id': 'u@x',
        'message_id': 12,
        'item_list': [
          {
            'type': 1,
            'text_item': {'text': 'quoted reply'},
            'ref_msg': {
              'title': '摘要',
              'svr_id': 9007199254740993,
              'partial_text': {'startindex': 1, 'endindex': 4},
            },
          },
          {
            'type': 11,
            'tool_call_start_item': {
              'tool_name': 'search',
              'tool_call_id': 'c1',
            },
          },
          {
            'type': 12,
            'tool_call_result_item': {
              'tool_name': 'search',
              'tool_call_id': 'c1',
              'status': 'ok',
            },
          },
        ],
      });

      expect(msg.items[0].refMsg?.title, '摘要');
      expect(msg.items[0].refMsg?.svrId, '9007199254740993');
      expect(msg.items[0].refMsg?.partialText?.endIndex, 4);
      expect(msg.refMessage, isNotNull);
      expect(msg.items[1].type, MessageItemType.toolCallStart);
      expect(msg.items[1].toolCallStart?.toolName, 'search');
      expect(msg.items[2].type, MessageItemType.toolCallResult);
      expect(msg.items[2].toolCallResult?.status, 'ok');
      // Legacy convenience getters still work.
      expect(msg.textContent, 'quoted reply');
    });

    test('message kind / state enums expose the official codes', () {
      final msg = WeixinMessage.fromJson({
        'from_user_id': 'u@x',
        'message_type': 1,
        'message_state': 1,
        'item_list': [],
      });
      expect(msg.messageKind, MessageType.user);
      expect(msg.state, MessageState.generating);
      expect(msg.isFromUser, isTrue);
    });

    test('voice / file / video items expose their media payloads', () {
      final msg = WeixinMessage.fromJson({
        'item_list': [
          {
            'type': 3,
            'voice_item': {
              'text': '转写内容',
              'playtime': 1200,
              'sample_rate': 16000,
              'media': {'aes_key': 'AAECAwQFBgcICQoLDA0ODw=='},
            },
          },
          {
            'type': 4,
            'file_item': {
              'file_name': 'a.txt',
              'len': '12',
              'media': {'encrypt_query_param': 'p'},
            },
          },
        ],
      });
      expect(msg.voiceItem?.playtime, 1200);
      expect(msg.voiceItem?.sampleRate, 16000);
      expect(msg.textContent, '转写内容');
      expect(msg.fileItem?.fileName, 'a.txt');
      expect(msg.fileItem?.len, '12');
      // Voice carries its key inside media.aes_key; the file item does not.
      expect(msg.voiceItem?.media?.resolveKeyForTest, hasLength(16));
      expect(msg.fileItem?.media?.resolveKeyForTest, isNull);
    });
  });
}

// ── helpers ────────────────────────────────────────────────────────────────

/// A [MockClient] that emulates iLink long-poll latency so the poll loop does
/// not spin hot in tests.
MockClient slowPollingClient(
  List<String> paths, {
  String getUpdatesBody = '{"ret":0,"msgs":[]}',
  Duration latency = const Duration(milliseconds: 25),
}) {
  return MockClient((req) async {
    paths.add(req.url.path);
    if (req.url.path.endsWith('getupdates')) {
      await Future<void>.delayed(latency);
    }
    return http.Response(getUpdatesBody, 200);
  });
}

MessagePoller _pollerWith(
  Future<http.Response> Function(http.Request req) handler,
) {
  final ilink = ILinkClient(token: 'T', httpClient: MockClient(handler));
  final poller =
      MessagePoller(client: ilink, account: account('b@x', 'T', 'wx@x', 1));
  addTearDown(() {
    poller.stop();
    ilink.dispose();
  });
  return poller;
}

extension CdnKeyResolution on CdnMedia {
  /// Convenience accessor used by the tests (voice/file/video items carry
  /// their key only inside `media.aes_key`).
  Uint8List? get resolveKeyForTest => resolveMediaAesKeyBytes(this);
}
