/// Download, decrypt **and upload** media on the WeChat iLink CDN.
///
/// Replicates the receive path of the official openclaw-weixin plugin
/// (`media-download.js` + `pic-decrypt.js` + `cdn-url.js`):
///
/// 1. Build the download URL from `full_url` when present, otherwise from
///    `{cdnBaseUrl}/download?encrypted_query_param=<param>`.
/// 2. GET the payload (ciphertext when `aes_key` is set).
/// 3. Decrypt with AES-128-ECB and strip PKCS7 padding.
///
/// The send path mirrors `cdn/upload.ts` + `cdn/cdn-upload.ts` +
/// `cdn/cdn-url.ts`: hash the plaintext, generate a random 16-byte key, call
/// `getuploadurl`, encrypt with AES-128-ECB + PKCS#7, POST the ciphertext to
/// `{cdnBaseUrl}/upload?encrypted_query_param=…&filekey=…` and read the
/// download parameter back from the `x-encrypted-param` response header.
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
import 'package:pointycastle/digests/md5.dart';

import 'client.dart';
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
  })  : cdnBaseUrl =
            (cdnBaseUrl ?? defaultCdnBaseUrl).replaceAll(RegExp(r'/+$'), ''),
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

  final cipher = ECBBlockCipher(AESEngine())..init(false, KeyParameter(key));

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

// ── CDN URL construction (official `cdn/cdn-url.ts`) ───────────────────────

/// Builds a CDN **download** URL from `encrypt_query_param`.
String buildCdnDownloadUrl(String encryptedQueryParam, String cdnBaseUrl) =>
    '$cdnBaseUrl/download'
    '?encrypted_query_param=${Uri.encodeComponent(encryptedQueryParam)}';

/// Builds a CDN **upload** URL from `upload_param` + `filekey`.
String buildCdnUploadUrl({
  required String cdnBaseUrl,
  required String uploadParam,
  required String filekey,
}) =>
    '$cdnBaseUrl/upload'
    '?encrypted_query_param=${Uri.encodeComponent(uploadParam)}'
    '&filekey=${Uri.encodeComponent(filekey)}';

// ── Outbound media (official `cdn/upload.ts`) ──────────────────────────────

/// Ciphertext size for [rawSize] plaintext bytes under AES-128-ECB with
/// PKCS#7 padding (official `aesEcbPaddedSize`).
int aesEcbPaddedSize(int rawSize) => rawSize + 16 - (rawSize % 16);

/// Lower-case hex MD5 of [bytes] — the `rawfilemd5` wire field.
String md5Hex(Uint8List bytes) {
  final digest = MD5Digest().process(bytes);
  final sb = StringBuffer();
  for (final b in digest) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Returns [len] cryptographically-random bytes rendered as lower-case hex.
///
/// Both `filekey` and the AES key are 16 random bytes hex-encoded, matching
/// the official `crypto.randomBytes(16).toString("hex")`.
String randomHexBytes(int len) {
  final rng = Random.secure();
  final sb = StringBuffer();
  for (var i = 0; i < len; i++) {
    sb.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Successful CDN upload result, ready to be embedded in an outbound media
/// item (official `UploadedFileInfo`).
class UploadedMedia {
  /// Client-generated file key sent to `getuploadurl` (32 hex chars).
  final String fileKey;

  /// `x-encrypted-param` response header → `media.encrypt_query_param`.
  final String downloadEncryptQueryParam;

  /// AES-128 key as a 32-char hex string (the wire `aeskey`).
  final String aesKeyHex;

  /// Plaintext byte count (`rawsize`; also `file_item.len`).
  final int rawSize;

  /// Ciphertext byte count (`filesize`; also `mid_size` / `video_size`).
  final int ciphertextSize;

  /// Lower-case hex MD5 of the plaintext (`rawfilemd5`).
  final String rawMd5;

  const UploadedMedia({
    required this.fileKey,
    required this.downloadEncryptQueryParam,
    required this.aesKeyHex,
    required this.rawSize,
    required this.ciphertextSize,
    required this.rawMd5,
  });

  /// `media.aes_key` as the official senders emit it: **base64 of the hex
  /// string**, not base64 of the raw key bytes.
  String get aesKeyBase64 => base64AesKeyFromHex(aesKeyHex);
}

/// Thrown when a CDN upload fails after all attempts, or immediately on a
/// client-side (4xx) rejection.
class CdnUploadException implements Exception {
  final String message;
  final int? statusCode;

  CdnUploadException(this.message, {this.statusCode});

  @override
  String toString() => 'CdnUploadException: $message';
}

/// Uploads outbound media (image / video / file / voice) to the WeChat CDN.
///
/// Pipeline (identical to the official plugin, thumbnails disabled):
///
/// 1. Hash the plaintext and compute the padded ciphertext size.
/// 2. Generate a random `filekey` and a random 16-byte AES key.
/// 3. Call `getuploadurl` with `no_need_thumb: true`.
/// 4. AES-128-ECB + PKCS#7 encrypt and `POST` the ciphertext with
///    `Content-Type: application/octet-stream`.
/// 5. Read `x-encrypted-param` from the response headers.
///
/// Success requires HTTP 200 **and** a non-empty `x-encrypted-param`; 4xx
/// aborts immediately while every other failure is retried up to
/// [CdnMediaUploader.uploadMaxRetries] attempts in total — the official
/// acceptance and retry policy.
class CdnMediaUploader {
  final ILinkClient _client;
  final http.Client _http;
  final bool _ownsClient;

  /// CDN base used when the server does not return `upload_full_url`.
  final String cdnBaseUrl;

  /// Rewrites a server-provided absolute `upload_full_url` before the request
  /// (Flutter Web routes it through the local CORS proxy).
  final String Function(String uploadFullUrl)? uploadUrlRewriter;

  /// Per-attempt timeout for the upload POST.
  final Duration timeout;

  /// Total attempts (first try plus retries), official `UPLOAD_MAX_RETRIES`.
  static const int uploadMaxRetries = 3;

  CdnMediaUploader({
    required ILinkClient client,
    String? cdnBaseUrl,
    http.Client? httpClient,
    this.uploadUrlRewriter,
    this.timeout = const Duration(seconds: 60),
  })  : _client = client,
        cdnBaseUrl =
            (cdnBaseUrl ?? defaultCdnBaseUrl).replaceAll(RegExp(r'/+$'), ''),
        _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  /// Uploads [bytes] and returns the CDN reference for a media item.
  Future<UploadedMedia> upload({
    required Uint8List bytes,
    required UploadMediaType mediaType,
    required String toUserId,
  }) async {
    final rawSize = bytes.length;
    final rawMd5 = md5Hex(bytes);
    final ciphertextSize = aesEcbPaddedSize(rawSize);
    final fileKey = randomHexBytes(16);
    final aesKeyHex = randomHexBytes(16);

    final resp = await _client.getUploadUrl(GetUploadUrlRequest(
      fileKey: fileKey,
      mediaType: mediaType,
      toUserId: toUserId,
      rawSize: rawSize,
      rawFileMd5: rawMd5,
      fileSize: ciphertextSize,
      aesKeyHex: aesKeyHex,
      noNeedThumb: true,
    ));

    if (!resp.hasUploadTarget) {
      throw CdnUploadException(
        'getuploadurl returned no upload URL '
        '(need upload_full_url or upload_param)',
      );
    }

    final full = resp.uploadFullUrl?.trim();
    final url = full != null && full.isNotEmpty
        ? (uploadUrlRewriter != null ? uploadUrlRewriter!(full) : full)
        : buildCdnUploadUrl(
            cdnBaseUrl: cdnBaseUrl,
            uploadParam: resp.uploadParam!,
            filekey: fileKey,
          );

    final ciphertext = aesEcbEncrypt(bytes, hexToBytes(aesKeyHex));
    final downloadParam = await _postEncrypt(url, ciphertext, fileKey);

    return UploadedMedia(
      fileKey: fileKey,
      downloadEncryptQueryParam: downloadParam,
      aesKeyHex: aesKeyHex,
      rawSize: rawSize,
      ciphertextSize: ciphertextSize,
      rawMd5: rawMd5,
    );
  }

  Future<String> _postEncrypt(
    String url,
    Uint8List ciphertext,
    String fileKey,
  ) async {
    Object? lastError;

    for (var attempt = 1; attempt <= uploadMaxRetries; attempt++) {
      try {
        final req = http.Request('POST', Uri.parse(url))
          ..headers['Content-Type'] = 'application/octet-stream'
          ..bodyBytes = ciphertext;

        final streamed = await _http.send(req).timeout(timeout);
        final status = streamed.statusCode;
        // Always drain the body so the connection can be reused.
        final bodyBytes = await streamed.stream
            .toBytes()
            .timeout(timeout, onTimeout: () => Uint8List(0));
        final errHeader = streamed.headers['x-error-message'];
        final detail = (errHeader != null && errHeader.isNotEmpty)
            ? errHeader
            : (bodyBytes.isEmpty
                ? 'status $status'
                : String.fromCharCodes(bodyBytes.sublist(
                    0, bodyBytes.length < 200 ? bodyBytes.length : 200)));

        if (status >= 400 && status < 500) {
          // Client error: abort immediately, never retried (official).
          throw CdnUploadException(
            'CDN upload client error $status: $detail',
            statusCode: status,
          );
        }
        if (status != 200) {
          throw CdnUploadException('CDN upload server error: $detail',
              statusCode: status);
        }
        final downloadParam = streamed.headers['x-encrypted-param'];
        if (downloadParam == null || downloadParam.isEmpty) {
          throw CdnUploadException(
            'CDN upload response missing x-encrypted-param header',
            statusCode: status,
          );
        }
        return downloadParam;
      } on CdnUploadException catch (e) {
        lastError = e;
        if (e.statusCode != null &&
            e.statusCode! >= 400 &&
            e.statusCode! < 500) {
          rethrow;
        }
        if (attempt == uploadMaxRetries) break;
      } catch (e) {
        lastError = e;
        if (attempt == uploadMaxRetries) break;
      }
    }

    throw lastError is Exception
        ? lastError
        : CdnUploadException(
            'CDN upload failed after $uploadMaxRetries attempts '
            '(filekey=$fileKey)');
  }

  /// Releases the underlying HTTP connection pool when owned.
  void dispose() {
    if (_ownsClient) _http.close();
  }
}
