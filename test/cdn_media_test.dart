import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:weixin_clawbot/weixin_clawbot.dart';

void main() {
  group('hexToBytes', () {
    test('decodes uppercase/lowercase hex', () {
      expect(hexToBytes('0A1f2B3c'),
          equals(const [0x0A, 0x1F, 0x2B, 0x3C]));
    });

    test('throws on odd length', () {
      expect(() => hexToBytes('abc'), throwsFormatException);
    });

    test('throws on invalid characters', () {
      expect(() => hexToBytes('zz'), throwsFormatException);
    });
  });

  group('ImageItemData.resolveAesKeyBytes', () {
    test('top-level hex aeskey wins over media.aes_key', () {
      const item = ImageItemData(
        aesKeyHex: '000102030405060708090a0b0c0d0e0f',
        media: CdnMedia(aesKey: 'AAAAAAAAAAAAAAAAAAAAAA=='),
      );
      expect(item.resolveAesKeyBytes(),
          equals(const [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]));
    });

    test('media.aes_key base64 of raw 16 bytes (image form)', () {
      const item = ImageItemData(
        media: CdnMedia(
            aesKey: 'AAECAwQFBgcICQoLDA0ODw=='), // base64(00..0f)
      );
      expect(item.resolveAesKeyBytes(),
          equals(const [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]));
    });

    test('media.aes_key base64 of 32-char hex string (file/voice form)', () {
      // base64 of "00112233445566778899aabbccddeeff"
      const item = ImageItemData(
        media: CdnMedia(aesKey: 'MDAxMTIyMzM0NDU1NjY3Nzg4OTlhYWJiY2NkZGVlZmY='),
      );
      expect(
          item.resolveAesKeyBytes(),
          equals(const [
            0x00, 0x11, 0x22, 0x33, //
            0x44, 0x55, 0x66, 0x77, //
            0x88, 0x99, 0xaa, 0xbb, //
            0xcc, 0xdd, 0xee, 0xff,
          ]));
    });

    test('returns null without any key', () {
      const item = ImageItemData(media: CdnMedia(encryptQueryParam: 'x'));
      expect(item.resolveAesKeyBytes(), isNull);
      expect(item.isDownloadable, isTrue);
    });

    test('parses inbound image_item JSON from getupdates', () {
      final json = {
        'type': 2,
        'image_item': {
          'aeskey': '00112233445566778899aabbccddeeff',
          'mid_size': 64,
          'media': {
            'encrypt_query_param': 'KQQxxx',
            'aes_key': 'AAAAAAAAAAAAAAAAAAAAAA==',
            'encrypt_type': 1,
          },
        },
      };
      final item = MessageItem.fromJson(json);
      expect(item.type, MessageItemType.image);
      expect(item.image, isNotNull);
      expect(item.image!.aesKeyHex, '00112233445566778899aabbccddeeff');
      expect(item.image!.midSize, 64);
      expect(item.image!.media!.encryptQueryParam, 'KQQxxx');
      expect(item.image!.isDownloadable, isTrue);
      expect(item.image!.resolveAesKeyBytes(), isNotNull);
    });
  });

  group('WeixinMessage.imageItem', () {
    test('returns first image segment', () {
      final msg = WeixinMessage.fromJson({
        'from_user_id': 'user@openim',
        'item_list': [
          {'type': 1, 'text_item': {'text': '看这张图'}},
          {'type': 2, 'image_item': {'media': {'encrypt_query_param': 'p'}}},
        ],
      });
      expect(msg.imageItem, isNotNull);
      expect(msg.textContent, '看这张图');
    });

    test('returns null for text-only message', () {
      final msg = WeixinMessage.fromJson({
        'item_list': [
          {'type': 1, 'text_item': {'text': 'hi'}},
        ],
      });
      expect(msg.imageItem, isNull);
    });
  });

  group('aesEcb round trip', () {
    final key = Uint8List.fromList(
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);

    test('encrypt → decrypt restores plaintext (any length)', () {
      final plain = Uint8List.fromList(List.generate(100, (i) => i % 256));
      final cipher = aesEcbEncrypt(plain, key);
      expect(cipher.length, 112); // ceil(100+1 / 16) * 16
      expect(aesEcbDecrypt(cipher, key), equals(plain));
    });

    test('exact block size gets full extra padding block', () {
      final plain = Uint8List(32);
      final cipher = aesEcbEncrypt(plain, key);
      expect(cipher.length, 48);
      expect(aesEcbDecrypt(cipher, key), equals(plain));
    });

    test('decrypt throws on non-block-aligned input', () {
      expect(
        () => aesEcbDecrypt(Uint8List.fromList([1, 2, 3]), key),
        throwsFormatException,
      );
    });

    test('stripPkcs7 returns null on malformed padding', () {
      expect(stripPkcs7(Uint8List.fromList([1, 2, 0])), isNull);
      expect(stripPkcs7(Uint8List.fromList([1, 2, 5, 5, 3])), isNull);
      expect(stripPkcs7(Uint8List.fromList([1, 2, 2, 2])),
          equals(const [1, 2]));
    });
  });

  group('CdnMediaDownloader', () {
    test('builds download URL from encrypt_query_param and decrypts',
        () async {
      final key = Uint8List.fromList(
          [0x0f, 0x0e, 0x0d, 0x0c, 0x0b, 0x0a, 0x09, 0x08, //
           0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00]);
      final plain = Uint8List.fromList(
          List.generate(37, (i) => (i * 7 + 3) % 256));
      final cipher = aesEcbEncrypt(plain, key);

      Uri? requestedUrl;
      final client = MockClient((req) async {
        requestedUrl = req.url;
        return http.Response.bytes(cipher, 200,
            headers: {'content-type': 'application/octet-stream'});
      });

      final downloader = CdnMediaDownloader(httpClient: client);
      final bytes = await downloader.downloadImage(ImageItemData(
        aesKeyHex: '0f0e0d0c0b0a09080706050403020100',
        media: const CdnMedia(encryptQueryParam: 'abc/def+ghi='),
      ));

      expect(
        requestedUrl.toString(),
        'https://novac2c.cdn.weixin.qq.com/c2c/download'
        '?encrypted_query_param=${Uri.encodeComponent('abc/def+ghi=')}',
      );
      expect(bytes, equals(plain));
    });

    test('prefers full_url when present', () async {
      Uri? requestedUrl;
      final client = MockClient((req) async {
        requestedUrl = req.url;
        return http.Response.bytes(Uint8List.fromList([1, 2, 3]), 200);
      });

      final downloader = CdnMediaDownloader(httpClient: client);
      final bytes = await downloader.downloadMedia(
        const CdnMedia(
          encryptQueryParam: 'unused',
          fullUrl: 'https://example.com/img.jpg',
        ),
      );

      expect(requestedUrl.toString(), 'https://example.com/img.jpg');
      expect(bytes, equals(const [1, 2, 3]));
    });

    test('plain payload returned as-is without key', () async {
      final client = MockClient((req) async {
        return http.Response.bytes(Uint8List.fromList([9, 9]), 200);
      });
      final downloader = CdnMediaDownloader(httpClient: client);
      final bytes = await downloader.downloadImage(
        const ImageItemData(media: CdnMedia(encryptQueryParam: 'p')),
      );
      expect(bytes, equals(const [9, 9]));
    });

    test('non-200 raises ILinkApiException', () async {
      final client = MockClient((req) async {
        return http.Response('forbidden', 403);
      });
      final downloader = CdnMediaDownloader(httpClient: client);
      expect(
        () => downloader.downloadImage(
          const ImageItemData(media: CdnMedia(encryptQueryParam: 'p')),
        ),
        throwsA(isA<ILinkApiException>()),
      );
    });
  });
}
