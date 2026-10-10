/// Local CORS proxy for Flutter Web development.
///
/// The WeChat iLink API (`https://ilinkai.weixin.qq.com`) does not send CORS
/// headers, so browsers block direct XHR/fetch calls from Flutter Web.
/// This server runs on `localhost:3001`, adds the required CORS headers, and
/// forwards every request to the real iLink endpoint.
///
/// Inbound media (images/files/videos) live on a second CDN host
/// (`https://novac2c.cdn.weixin.qq.com/c2c`) which also lacks CORS headers;
/// requests whose path starts with `/cdn/` are forwarded there.
/// `/cdnfull/<host>/<path>` forwards to other WeChat media CDN hosts — used
/// for the server-provided `media.full_url` download links; only
/// `weixin.qq.com` / `qq.com` and their subdomains are allowed.
/// `/redirect/<host>/<path>` forwards to another iLink host
/// (`scaned_but_redirect` IDC redirects); only `ilinkai.weixin.qq.com`
/// and its subdomains are allowed.
///
/// Usage:
///   dart run bin/proxy_server.dart
///
/// Then start your Flutter Web app with:
///   flutter run -d chrome --dart-define=PROXY_URL=http://localhost:3001
///
/// The PROXY_URL value is read by main.dart at compile time and passed to
/// WeixinClawbot(proxyBaseUrl: ...). You can also hard-code it:
///   WeixinClawbot(proxyBaseUrl: 'http://localhost:3001')
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

const _targetBase = 'https://ilinkai.weixin.qq.com';
const _cdnTargetBase = 'https://novac2c.cdn.weixin.qq.com/c2c';
const _listenPort = 3001;

/// Headers the iLink API needs from the client side.
const _forwardHeaders = {
  'content-type',
  'authorization',
  'authorizationtype',
  'x-wechat-uin',
  'ilink-app-id',
  'ilink-app-clientversion',
};

const _corsHeaders = <String, String>{
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  // Must list every custom header the app sends (each one triggers a CORS
  // preflight; a missing entry makes the browser abort with
  // `ClientException: Failed to fetch` before the request is ever sent).
  'Access-Control-Allow-Headers':
      'Content-Type, Authorization, AuthorizationType, '
          'X-WECHAT-UIN, iLink-App-Id, iLink-App-ClientVersion',
  'Access-Control-Max-Age': '86400',
};

Future<void> main() async {
  // IMPORTANT: force direct connections regardless of http_proxy/https_proxy
  // environment variables. Dart's HttpClient honours them, and shell sessions
  // where Clash Verge once ran keep exporting `https_proxy=http://127.0.0.1:7897`
  // long after Clash has exited — the upstream request then dies with
  // `Connection refused 127.0.0.1:<port>` even though the network is fine.
  final innerClient = HttpClient()..findProxy = (uri) => 'DIRECT';
  final client = IOClient(innerClient);

  final hasProxyEnv = [
    'http_proxy',
    'https_proxy',
    'HTTP_PROXY',
    'HTTPS_PROXY',
    'ALL_PROXY',
    'all_proxy',
  ].any(Platform.environment.containsKey);
  if (hasProxyEnv) {
    print('! 检测到 http(s)_proxy 环境变量，已强制直连上游 (findProxy=DIRECT)。');
  }

  Response handleOptions(Request _) => Response.ok('', headers: _corsHeaders);

  Future<Response> handleProxy(Request request) async {
    // Route rules, checked in order:
    //   /redirect/<host>/<path> → https://<host>/<path>   (IDC redirects,
    //       restricted to ilinkai.weixin.qq.com and subdomains)
    //   /cdnfull/<host>/<path>  → https://<host>/<path>   (media CDN hosts,
    //       restricted to weixin.qq.com / qq.com and subdomains; carries the
    //       server-provided media `full_url`)
    //   /cdn/<path>             → the media CDN             (inbound media)
    //   anything else           → the iLink API host
    final requestedPath = request.requestedUri.path;

    String? targetHost;
    var targetPath = requestedPath;

    final redirectMatch =
        RegExp(r'^/redirect/([^/]+)(/.*)$').firstMatch(requestedPath);
    final cdnFullMatch =
        RegExp(r'^/cdnfull/([^/]+)(/.*)$').firstMatch(requestedPath);
    if (redirectMatch != null) {
      final host = redirectMatch.group(1)!;
      final allowed = host == 'ilinkai.weixin.qq.com' ||
          host.endsWith('.ilinkai.weixin.qq.com');
      if (!allowed) {
        return Response.badRequest(
          body: 'redirect host not allowed: $host',
          headers: _corsHeaders,
        );
      }
      targetHost = 'https://$host';
      targetPath = redirectMatch.group(2)!;
    } else if (cdnFullMatch != null) {
      final host = cdnFullMatch.group(1)!;
      final allowed = host == 'weixin.qq.com' ||
          host.endsWith('.weixin.qq.com') ||
          host == 'qq.com' ||
          host.endsWith('.qq.com');
      if (!allowed) {
        return Response.badRequest(
          body: 'cdn host not allowed: $host',
          headers: _corsHeaders,
        );
      }
      targetHost = 'https://$host';
      targetPath = cdnFullMatch.group(2)!;
    } else if (requestedPath.startsWith('/cdn/')) {
      targetHost = _cdnTargetBase;
      targetPath = requestedPath.substring('/cdn'.length);
    } else {
      targetHost = _targetBase;
    }

    final targetUri = Uri.parse(
      '$targetHost$targetPath'
      '${request.requestedUri.hasQuery ? '?${request.requestedUri.query}' : ''}',
    );

    final body = await request.read().expand((chunk) => chunk).toList();
    final bodyBytes = Uint8List.fromList(body);

    final proxyReq = http.Request(request.method, targetUri);

    // Only forward safe, API-required headers
    for (final entry in request.headers.entries) {
      if (_forwardHeaders.contains(entry.key.toLowerCase())) {
        proxyReq.headers[entry.key] = entry.value;
      }
    }
    if (bodyBytes.isNotEmpty) proxyReq.bodyBytes = bodyBytes;

    try {
      final streamed = await client.send(proxyReq);
      final respBytes = await streamed.stream.toBytes();

      final headers = <String, String>{..._corsHeaders};
      final ct = streamed.headers['content-type'];
      if (ct != null) headers['content-type'] = ct;

      return Response(streamed.statusCode, body: respBytes, headers: headers);
    } catch (e) {
      return Response.internalServerError(
        body: 'Proxy error: $e',
        headers: _corsHeaders,
      );
    }
  }

  final handler = const Pipeline().addMiddleware(logRequests()).addHandler(
    (request) async {
      if (request.method == 'OPTIONS') return handleOptions(request);
      return handleProxy(request);
    },
  );

  final server =
      await io.serve(handler, InternetAddress.loopbackIPv4, _listenPort);
  print('✓ CORS proxy running on http://localhost:${server.port}');
  print('  Forwarding → $_targetBase');
  print('  Press Ctrl+C to stop.');
}
