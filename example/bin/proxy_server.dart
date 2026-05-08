/// Local CORS proxy for Flutter Web development.
///
/// The WeChat iLink API (`https://ilinkai.weixin.qq.com`) does not send CORS
/// headers, so browsers block direct XHR/fetch calls from Flutter Web.
/// This server runs on `localhost:3001`, adds the required CORS headers, and
/// forwards every request to the real iLink endpoint.
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
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

const _targetBase = 'https://ilinkai.weixin.qq.com';
const _listenPort = 3001;

/// Headers the iLink API needs from the client side.
const _forwardHeaders = {
  'content-type',
  'authorization',
  'authorizationtype',
  'x-wechat-uin',
  'ilink-app-clientversion',
};

const _corsHeaders = <String, String>{
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers':
      'Content-Type, Authorization, AuthorizationType, '
          'X-WECHAT-UIN, iLink-App-ClientVersion',
  'Access-Control-Max-Age': '86400',
};

Future<void> main() async {
  final client = http.Client();

  Response handleOptions(Request _) => Response.ok('', headers: _corsHeaders);

  Future<Response> handleProxy(Request request) async {
    // Reconstruct the target URL
    final targetUri = Uri.parse(
      '$_targetBase${request.requestedUri.path}'
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
