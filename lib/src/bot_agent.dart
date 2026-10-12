/// `base_info.bot_agent` sanitisation.
///
/// Port of the official openclaw-weixin `sanitizeBotAgent()` in
/// `src/api/api.ts`. `bot_agent` is a UA-style, observability-only identifier
/// (never used for authentication or routing) that is attached to **every**
/// authenticated bot request inside `base_info`.
library;

import 'dart:convert';

/// Value used when the caller declares no `botAgent`, or when every declared
/// token is rejected. Mirrors the official `DEFAULT_BOT_AGENT`.
const String defaultBotAgent = 'OpenClaw';

/// Maximum byte length of the sanitised `bot_agent` string.
const int botAgentMaxLen = 256;

// name      = 1*32( ALPHA / DIGIT / "_" / "." / "-" )
// version   = 1*32( ALPHA / DIGIT / "_" / "." / "+" / "-" )
final RegExp _productRe =
    RegExp(r'^[A-Za-z0-9_.\-]{1,32}/[A-Za-z0-9_.+\-]{1,32}$');

// comment   = 1*64( printable ASCII minus "(" ")" )
final RegExp _commentCharRe = RegExp(r'^[\x20-\x27\x2A-\x7E]{1,64}$');

/// Sanitises a user-supplied `botAgent` value into a wire-safe string.
///
/// Grammar (UA-style):
///
/// ```text
/// bot_agent = product *( SP product )
/// product   = name "/" version [ SP "(" comment ")" ]
/// ```
///
/// Tokens that fail to parse are dropped silently (no partial tokens are
/// kept). Returns [defaultBotAgent] when the input is empty, all tokens were
/// dropped, or the result still exceeds the length cap after truncation.
String sanitizeBotAgent(String? raw) {
  if (raw == null || raw.isEmpty) return defaultBotAgent;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return defaultBotAgent;

  // Tokenize on whitespace, but keep `(comment)` glued to the preceding
  // product. Split by spaces, then re-attach any token that starts with "(".
  final rawTokens = trimmed.split(RegExp(r'\s+'));
  final tokens = <String>[];
  for (var i = 0; i < rawTokens.length; i++) {
    final tok = rawTokens[i];
    if (tok.startsWith('(') && !tok.endsWith(')')) {
      // Multi-word comment; greedily collect until we find the closing ")".
      var acc = tok;
      while (i + 1 < rawTokens.length && !acc.endsWith(')')) {
        i += 1;
        acc = '$acc ${rawTokens[i]}';
      }
      tokens.add(acc);
    } else {
      tokens.add(tok);
    }
  }

  final accepted = <String>[];
  String? pendingProduct;
  for (final tok in tokens) {
    if (tok.startsWith('(') && tok.endsWith(')')) {
      final inner = tok.substring(1, tok.length - 1);
      if (pendingProduct != null && _commentCharRe.hasMatch(inner)) {
        accepted.add('$pendingProduct ($inner)');
        pendingProduct = null;
      } else {
        if (pendingProduct != null) {
          accepted.add(pendingProduct);
          pendingProduct = null;
        }
      }
      continue;
    }
    if (pendingProduct != null) {
      accepted.add(pendingProduct);
      pendingProduct = null;
    }
    if (_productRe.hasMatch(tok)) {
      pendingProduct = tok;
    }
  }
  if (pendingProduct != null) accepted.add(pendingProduct);

  if (accepted.isEmpty) return defaultBotAgent;

  final joined = accepted.join(' ');
  if (_byteLength(joined) <= botAgentMaxLen) return joined;

  // Truncate by dropping trailing tokens until under the cap.
  final truncated = <String>[];
  var len = 0;
  for (final t in accepted) {
    final add = (truncated.isEmpty ? 0 : 1) + _byteLength(t);
    if (len + add > botAgentMaxLen) break;
    truncated.add(t);
    len += add;
  }
  return truncated.isNotEmpty ? truncated.join(' ') : defaultBotAgent;
}

/// UTF-8 byte length of [s] (the official cap is measured in bytes, not
/// characters).
int _byteLength(String s) => utf8.encode(s).length;
