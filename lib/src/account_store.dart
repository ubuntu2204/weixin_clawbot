/// Persistent storage for bot account credentials.
///
/// The persistence backend is pluggable via [AccountStorage]; the default
/// implementation is platform-dependent:
/// - native (mobile / desktop / Dart servers): JSON file under
///   `~/.weixin_clawbot/`
/// - web: browser localStorage
/// - other: in-memory
///
/// Before 0.3.0 this class used `shared_preferences` (Flutter only); the
/// public API is unchanged.
library;

import 'dart:convert';

import 'account_storage.dart';
import 'account_storage_default.dart' show createDefaultAccountStorage;

import 'models.dart';

/// Persists and retrieves [ClawBotAccount] credentials across app restarts.
class AccountStore {
  AccountStore._(this.storage);

  static AccountStore? _instance;

  /// Returns the singleton instance.
  static AccountStore get instance => _instance ??= AccountStore._(
        createDefaultAccountStorage(),
      );

  /// Storage backend used by this store.
  final AccountStorage storage;

  /// Creates a store with an explicit [storage] backend (e.g. a custom
  /// database-backed one on servers). The default backend is chosen by
  /// platform when omitted.
  factory AccountStore({AccountStorage? storage}) =>
      AccountStore._(storage ?? createDefaultAccountStorage());

  // ── Public API ────────────────────────────────────────────────────────────

  /// Saves [account] to persistent storage, overwriting any existing entry
  /// with the same [ClawBotAccount.id].
  ///
  /// The official `saveWeixinAccount()` refreshes `savedAt` whenever a token is
  /// stored, so [botTokenList] orders tokens by most-recent login; the same
  /// stamp is applied here.
  Future<void> save(ClawBotAccount account) async {
    final all = await loadAll();
    final stamped = account.token.isNotEmpty
        ? account.copyWith(savedAtMs: DateTime.now().millisecondsSinceEpoch)
        : account;
    final updated = {
      for (final a in all) a.id: a,
      stamped.id: stamped,
    };
    await _persist(updated.values.toList());
  }

  // ── Re-bind (换绑) helpers, official `accounts.ts` ───────────────────────

  /// Number of bot tokens `get_bot_qrcode` may carry as `local_token_list`.
  /// The official plugin sends at most the ten most recent ones.
  static const int maxLocalTokenList = 10;

  /// The locally-known bot tokens, **newest first**, capped at [max].
  ///
  /// Mirrors the official `getLocalBotTokenList()`. Accounts without a stored
  /// token are skipped.
  Future<List<String>> botTokenList({int max = maxLocalTokenList}) async {
    final all = await loadAll();
    // Newest first; legacy entries without a timestamp sort last.
    final sorted = [...all]
      ..sort((a, b) => (b.savedAtMs ?? 0).compareTo(a.savedAtMs ?? 0));
    return sorted
        .where((a) => a.token.isNotEmpty)
        .map((a) => a.token)
        .take(max)
        .toList();
  }

  /// Removes every stored account bound to the same WeChat user as the freshly
  /// confirmed [account], keeping [account] itself.
  ///
  /// This is the official re-binding rule (`clearStaleAccountsForUserId`):
  /// a WeChat user is only ever tracked once per client, which prevents
  /// ambiguous `context_token` matches across the stale and the new bot.
  /// Returns the IDs that were removed.
  Future<List<String>> removeStaleForWechatUser({
    required String keepAccountId,
    required String? wechatUserId,
  }) async {
    final userId = wechatUserId?.trim();
    if (userId == null || userId.isEmpty) return const [];

    final all = await loadAll();
    final stale = <String>[];
    for (final a in all) {
      if (a.id == keepAccountId) continue;
      if (a.defaultTo?.trim() == userId) stale.add(a.id);
    }
    if (stale.isEmpty) return const [];

    await _persist(all.where((a) => !stale.contains(a.id)).toList());
    return stale;
  }

  /// Drops the cached `context_token` of [accountId] without removing the
  /// account itself (official `clearContextTokensForAccount`).
  Future<void> clearContextToken(String accountId) async {
    final all = await loadAll();
    final hit = all.any((a) => a.id == accountId);
    if (!hit) return;
    await _persist([
      for (final a in all)
        if (a.id == accountId)
          ClawBotAccount(
            id: a.id,
            token: a.token,
            baseUrl: a.baseUrl,
            botId: a.botId,
            defaultTo: a.defaultTo,
            savedAtMs: a.savedAtMs,
          )
        else
          a,
    ]);
  }

  /// Updates only the [contextToken] and optionally [defaultTo] for the
  /// account identified by [accountId]. No-op when the account does not exist.
  Future<void> updateContextToken({
    required String accountId,
    required String userId,
    required String contextToken,
  }) async {
    final all = await loadAll();
    final updated = all.map((a) {
      if (a.id != accountId) return a;
      // Store only the latest per-user token in the defaultTo/contextToken pair.
      // For multi-user context caching see the poller's in-memory map.
      return a.copyWith(
        defaultTo: a.defaultTo ?? userId,
        contextToken: contextToken,
      );
    }).toList();
    await _persist(updated);
  }

  /// Returns all stored accounts.
  Future<List<ClawBotAccount>> loadAll() async {
    final raw = await storage.read();
    return raw
        .map((s) {
          try {
            return ClawBotAccount.fromJson(
                jsonDecode(s) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<ClawBotAccount>()
        .toList();
  }

  /// Returns the first stored account, or `null` if none exist.
  Future<ClawBotAccount?> loadFirst() async {
    final all = await loadAll();
    return all.isEmpty ? null : all.first;
  }

  /// Loads the account whose [ClawBotAccount.id] matches [accountId].
  Future<ClawBotAccount?> load(String accountId) async {
    final all = await loadAll();
    try {
      return all.firstWhere((a) => a.id == accountId);
    } on StateError {
      return null;
    }
  }

  /// Removes the account with the given [accountId].
  Future<void> remove(String accountId) async {
    final all = await loadAll();
    await _persist(all.where((a) => a.id != accountId).toList());
  }

  /// Removes all stored accounts.
  Future<void> clear() async {
    await _persist(const []);
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  Future<void> _persist(List<ClawBotAccount> accounts) async {
    await storage.write(accounts.map((a) => jsonEncode(a.toJson())).toList());
  }
}
