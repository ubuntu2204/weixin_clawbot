/// File-backed storage for native platforms and Dart servers.
///
/// Stores the account list as a single JSON file. The default location is
/// `~/.weixin_clawbot/accounts.json` (falls back to the current working
/// directory's temp dir when neither HOME nor USERPROFILE is set).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'account_storage.dart';

class FileAccountStorage implements AccountStorage {
  FileAccountStorage({String? filePath})
      : _filePath = filePath ?? _defaultFilePath();

  final String _filePath;

  static String _defaultFilePath() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    return p.join(home, '.weixin_clawbot', 'accounts.json');
  }

  @override
  Future<List<String>> read() async {
    try {
      final raw = await File(_filePath).readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.whereType<String>().toList();
    } catch (_) {
      // Missing or corrupt file → treat as empty (same as a fresh install).
    }
    return const [];
  }

  @override
  Future<void> write(List<String> entries) async {
    final file = File(_filePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(entries), flush: true);
  }
}

AccountStorage createDefaultAccountStorage() => FileAccountStorage();
