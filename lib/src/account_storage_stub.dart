import 'account_storage.dart';

/// In-memory fallback storage (no persistence across restarts).
class MemoryAccountStorage implements AccountStorage {
  List<String> _entries = const [];

  @override
  Future<List<String>> read() async => List.of(_entries);

  @override
  Future<void> write(List<String> entries) async {
    _entries = List.of(entries);
  }
}

AccountStorage createDefaultAccountStorage() => MemoryAccountStorage();
