/// Browser localStorage storage for Flutter Web / Dart web.
///
/// Replaces the 0.2.x `shared_preferences` backend (which also used
/// localStorage under the hood). Reads fall back to the legacy
/// `flutter.weixin_clawbot_accounts` key written by 0.2.x so existing
/// browser data survives the upgrade; writes go to both keys.
library;

import 'dart:convert';

import 'package:web/web.dart' as web;

import 'account_storage.dart';

class LocalStorageAccountStorage implements AccountStorage {
  static const _key = 'weixin_clawbot_accounts';

  /// Legacy key used by the 0.2.x shared_preferences backend on web.
  static const _legacyKey = 'flutter.weixin_clawbot_accounts';

  static List<String> _parse(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => e.toString()).toList();
    } catch (_) {
      // Corrupt entry → treat as empty.
    }
    return const [];
  }

  @override
  Future<List<String>> read() async {
    final current = _parse(web.window.localStorage.getItem(_key));
    if (current.isNotEmpty) return current;
    return _parse(web.window.localStorage.getItem(_legacyKey));
  }

  @override
  Future<void> write(List<String> entries) async {
    final raw = jsonEncode(entries);
    web.window.localStorage.setItem(_key, raw);
    web.window.localStorage.setItem(_legacyKey, raw);
  }
}

AccountStorage createDefaultAccountStorage() => LocalStorageAccountStorage();
