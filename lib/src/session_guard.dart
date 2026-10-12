/// Session cooldown guard for stale bot tokens.
///
/// Port of the official openclaw-weixin `src/api/session-guard.ts`. When the
/// server answers `-14` (bot token stale / session expired) the official
/// plugin pauses **all** inbound and outbound API calls for that account for
/// one hour; continuing to hammer the endpoint with a dead token is what the
/// guard exists to prevent.
library;

/// Error code returned by the server when the bot token is stale / expired.
const int staleTokenErrcode = -14;

/// How long an account stays paused after a `staleTokenErrcode` response.
const Duration sessionPauseDuration = Duration(hours: 1);

/// Thrown by [SessionGuard.assertActive] while an account is cooling down.
class SessionPausedException implements Exception {
  final String accountId;

  /// Whole minutes remaining in the cooldown window.
  final int remainingMinutes;

  SessionPausedException(this.accountId, this.remainingMinutes) : super();

  @override
  String toString() => 'SessionPausedException: session paused for '
      'accountId=$accountId, $remainingMinutes min remaining '
      '(errcode $staleTokenErrcode)';
}

/// Tracks per-account cooldown windows.
///
/// A single shared instance backs [WeixinClawbot]; construct your own when you
/// need isolated state (e.g. tests).
class SessionGuard {
  /// Shared instance used by the package facades.
  static final SessionGuard shared = SessionGuard();

  final _pauseUntil = <String, DateTime>{};

  /// Pauses all API calls for [accountId] for [duration] (default: 1 hour).
  void pause(String accountId, {Duration duration = sessionPauseDuration}) {
    final until = DateTime.now().add(duration);
    _pauseUntil[accountId] = until;
  }

  /// `true` while [accountId] is inside its cooldown window.
  ///
  /// Expired windows are pruned as they are observed, matching the official
  /// lazy-expiry behaviour.
  bool isPaused(String accountId) {
    final until = _pauseUntil[accountId];
    if (until == null) return false;
    if (DateTime.now().isAfter(until) || DateTime.now() == until) {
      _pauseUntil.remove(accountId);
      return false;
    }
    return true;
  }

  /// Remaining pause time for [accountId] ([Duration.zero] when not paused).
  Duration remaining(String accountId) {
    final until = _pauseUntil[accountId];
    if (until == null) return Duration.zero;
    final left = until.difference(DateTime.now());
    if (left <= Duration.zero) {
      _pauseUntil.remove(accountId);
      return Duration.zero;
    }
    return left;
  }

  /// Throws [SessionPausedException] when [accountId] is cooling down.
  ///
  /// Call before issuing any API request for the account.
  void assertActive(String accountId) {
    if (!isPaused(accountId)) return;
    final left = remaining(accountId);
    // Round up to whole minutes, like the official `Math.ceil(ms / 60000)`.
    final minutes = (left.inMilliseconds / 60000).ceil();
    throw SessionPausedException(accountId, minutes);
  }

  /// Clears all cooldown state (drop the pause after a successful re-login).
  void resume(String accountId) => _pauseUntil.remove(accountId);

  /// Resets internal state — only for tests.
  void reset() => _pauseUntil.clear();
}
