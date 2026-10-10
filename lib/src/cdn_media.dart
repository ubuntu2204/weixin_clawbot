/// Download and decrypt inbound media from the WeChat iLink CDN.
///
/// Replicates the receive path of the official openclaw-weixin plugin
/// (`media-download.js` + `pic-decrypt.js` + `cdn-url.js`):
///
/// 1. Build the download URL from `full_url` when present, otherwise from
///    `{cdnBaseUrl}/download?encrypted_query_param=<param>`.
/// 2. GET the payload (ciphertext when `aes_key` is set).
/// 3. Decrypt with AES-128-ECB and strip PKCS7 padding.
///
/// On Flutter Web both URL forms are carried by the local CORS proxy: the
/// self-built URL via `cdnBaseUrl` and `full_url` via [CdnMediaDownloader.fullUrlRewriter].
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/ecb.dart';

import 'client.dart' show ILinkApiException;
import 'models.dart';

/// Default CDN base URL assigned by the iLink server.
const String defaultCdnBaseUrl = 'https://novac2c.cdn.weixin.qq.com/c2c';

/// Downloads (and decrypts) media files referenced by inbound message items.
class CdnMediaDownloader {
  /// Base URL of the CDN. Overridden on Flutter Web through the local CORS
  /// proxy (e.g. `http://localhost:3001/cdn`).
  final String cdnBaseUrl;

  /// Rewriter applied to `media.full_url` before the request.
  ///
  /// The server usually sends a pre-built `full_url` pointing directly at the
  /// CDN host. On Flutter Web a direct request to that host is blocked by the
  /// browser (no CORS headers, possible mixed content), so the facade passes a
  /// rewriter that maps the absolute URL onto the local proxy's
  /// `/cdnfull/<host>/<path>?<query>` route. `null` (native) keeps the URL
  /// as-is.
  final String Function(String fullUrl)? fullUrlRewriter;

  final http.Client? _httpClient;

  /// Whether the HTTP client was created internally (and thus disposed here).
  final bool _ownsClient;

  /// Per-request timeout for CDN downloads.
  final Duration timeout;

  CdnMediaDownloader({
    String? cdnBaseUrl,
    this.fullUrlRewriter,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
  })  : cdnBaseUrl = (cdnBaseUrl ?? defaultCdnBaseUrl)
            .replaceAll(RegExp(r'/+$'), ''),
        _httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  /// Downloads and decrypts an inbound image item.
  ///
  /// Returns the raw picture bytes (e.g. JPEG/PNG/GIF) ready to be fed to
  /// `Image.memory`. Plain (unencrypted) payloads are returned as-is.
  Future<Uint8List> downloadImage(ImageItemData image) {
    final media = image.media ?? const CdnMedia();
    return downloadMedia(media, aesKeyBytes: image.resolveAesKeyBytes());
  }

  /// Downloads and decrypts a generic CDN-backed media item.
  ///
  /// Pass the resolved key via [aesKeyBytes] (see
  /// [ImageItemData.resolveAesKeyBytes]); `null` downloads the payload as-is.
  Future<Uint8List> downloadMedia(
    CdnMedia media, {
    Uint8List? aesKeyBytes,
  }) async {
    final param = media.encryptQueryParam;
    final hasFullUrl = media.fullUrl?.isNotEmpty == true;
    // `full_url` takes precedence over the self-built URL (official parity),
    // but on Flutter Web it must be routed through the local CORS proxy.
    var url = hasFullUrl && fullUrlRewriter != null
        ? Uri.parse(fullUrlRewriter!(media.fullUrl!))
        : hasFullUrl
            ? Uri.parse(media.fullUrl!)
            : Uri.parse('$cdnBaseUrl/download'
                '?encrypted_query_param=${Uri.encodeComponent(param ?? '')}');

    final client = _httpClient ?? http.Client();
    final http.Response resp;
    try {
      resp = await client.get(url).timeout(timeout);
    } on TimeoutException {
      throw ILinkApiException('CDN download timed out: ${url.host}',
          statusCode: null);
    } on http.ClientException catch (e) {
      // Browser fetch/XHR failures (CORS, mixed content, offline) surface here.
      throw ILinkApiException(
        'CDN network error (${url.host}): ${e.message}',
        statusCode: null,
      );
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ILinkApiException(
        'CDN download HTTP ${resp.statusCode}: '
        '${resp.body.substring(0, min(200, resp.body.length))}',
        statusCode: resp.statusCode,
      );
    }

    final bytes = resp.bodyBytes;
    if (aesKeyBytes == null || aesKeyBytes.isEmpty) return bytes;
    return aesEcbDecrypt(bytes, aesKeyBytes);
  }

  /// Releases the underlying HTTP connection pool when owned.
  void dispose() {
    if (_ownsClient) _httpClient?.close();
  }
}

/// Decrypts an AES-128-ECB ciphertext with PKCS7 padding.
///
/// Falls back to returning the unpadded-but-untrimmed data when the trailing
/// padding is malformed, mirroring the permissive behaviour needed for CDN
/// payloads.
Uint8List aesEcbDecrypt(Uint8List cipherBytes, Uint8List key) {
  if (cipherBytes.isEmpty) return Uint8List(0);
  if (key.isEmpty || cipherBytes.length % 16 != 0) {
    throw const FormatException(
      'AES-ECB ciphertext must be non-empty and 16-byte aligned',
    );
  }

  final cipher = ECBBlockCipher(AESEngine())
    ..init(false, KeyParameter(key));

  final out = Uint8List(cipherBytes.length);
  var offset = 0;
  while (offset < cipherBytes.length) {
    offset += cipher.processBlock(cipherBytes, offset, out, offset);
  }

  final unpadded = stripPkcs7(out);
  return unpadded ?? out;
}

/// Removes PKCS7 padding; returns `null` when the padding is invalid.
Uint8List? stripPkcs7(Uint8List data) {
  if (data.isEmpty) return null;
  final pad = data.last;
  if (pad < 1 || pad > 16 || pad > data.length) return null;
  for (var i = data.length - pad; i < data.length; i++) {
    if (data[i] != pad) return null;
  }
  return Uint8List.sublistView(data, 0, data.length - pad);
}

/// Encrypts [plain] with AES-128-ECB + PKCS7 padding. Used by tests and
/// available for future outbound-media support.
Uint8List aesEcbEncrypt(Uint8List plain, Uint8List key) {
  final padded = pkcs7Pad(plain, 16);
  final cipher = ECBBlockCipher(AESEngine())..init(true, KeyParameter(key));
  final out = Uint8List(padded.length);
  var offset = 0;
  while (offset < padded.length) {
    offset += cipher.processBlock(padded, offset, out, offset);
  }
  return out;
}

/// Applies PKCS7 padding to reach a multiple of [blockSize].
Uint8List pkcs7Pad(Uint8List data, int blockSize) {
  final pad = blockSize - (data.length % blockSize);
  final out = Uint8List(data.length + pad)
    ..setRange(0, data.length, data)
    ..fillRange(data.length, data.length + pad, pad);
  return out;
}
