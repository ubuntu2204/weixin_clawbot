/// Persistent storage for bot account credentials using SharedPreferences.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

const _kAccountsKey = 'weixin_clawbot_accounts';

/// Persists and retrieves [ClawBotAccount] credentials across app restarts.
class AccountStore {
  AccountStore._();

  static AccountStore? _instance;

  /// Returns the singleton instance.
  static AccountStore get instance => _instance ??= AccountStore._();

  // ── Public API ────────────────────────────────────────────────────────────

  /// Saves [account] to persistent storage, overwriting any existing entry
  /// with the same [ClawBotAccount.id].
  Future<void> save(ClawBotAccount account) async {
    final all = await loadAll();
    final updated = {
      for (final a in all) a.id: a,
      account.id: account,
    };
    await _persist(updated.values.toList());
  }

  /// Updates only the [contextToken] and optionally [defaultTo] for the
  /// account identified by [accountId]. No-op if the account does not exist.
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
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kAccountsKey) ?? [];
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAccountsKey);
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  Future<void> _persist(List<ClawBotAccount> accounts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _kAccountsKey,
      accounts.map((a) => jsonEncode(a.toJson())).toList(),
    );
  }
}
