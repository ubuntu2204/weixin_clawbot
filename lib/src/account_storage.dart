/// Pluggable persistence backend for [AccountStore].
///
/// Entries are opaque JSON-encoded account strings; implementations decide
/// where and how the list is stored:
///
/// - native (mobile / desktop / Dart servers): `FileAccountStorage`
///   (`~/.weixin_clawbot/accounts.json`)
/// - web (Flutter Web / Dart web): `LocalStorageAccountStorage`
/// - anything else: `MemoryAccountStorage` (no persistence)
library;

/// Persists a list of JSON-encoded [ClawBotAccount] strings.
abstract class AccountStorage {
  /// Reads all persisted entries; returns an empty list when nothing is
  /// stored or the backend is unavailable.
  Future<List<String>> read();

  /// Atomically replaces all persisted entries.
  Future<void> write(List<String> entries);
}
