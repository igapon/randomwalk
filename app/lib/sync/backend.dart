import '../game/events.dart';

/// A signed-in (or just-verified) user as reported by a [SyncBackend].
///
/// [uid] is the backend's stable account identifier — unrelated to the
/// local, device-generated [PlayerIdentity.userId] used by the M4
/// leaderboard (`settings/identity.dart`); Task 4's decision is that the two
/// are never merged server-side, only carried side by side locally.
class AuthUser {
  final String uid;
  final String? email;
  const AuthUser({required this.uid, this.email});
}

/// One row of a backend-hosted leaderboard, matching the shape of
/// `LeaderboardEntry` (`leaderboard/repository.dart`) closely enough that a
/// future `SyncBackend`-backed `LeaderboardRepository` can adapt one to the
/// other trivially, without depending on this type.
class LeaderboardRow {
  final String pseudo;
  final double totalKm;
  final int rank;
  const LeaderboardRow({
    required this.pseudo,
    required this.totalKm,
    required this.rank,
  });
}

/// One page of remote [GameEvent]s returned by [SyncBackend.pullEventsSince].
///
/// [nextCursor] is `null` when [events] is the final page — i.e. there is
/// nothing newer on the server as of this call. A non-null cursor should be
/// persisted by the caller and passed back in as `cursor` to resume the pull
/// (either later in the same page sequence, or on a future sync). The cursor
/// is an opaque string as far as callers are concerned: its format is a
/// backend implementation detail (Task 3: a Supabase `inserted_at`
/// timestamp), never parsed outside the backend that issued it.
class PullPage {
  final List<GameEvent> events;
  final String? nextCursor;
  const PullPage({required this.events, this.nextCursor});
}

/// Thrown by every [SyncBackend] method that requires a configured backend
/// when called on [UnconfiguredBackend] — see that class's doc comment for
/// exactly which methods do (and don't) throw this.
///
/// This is a *caller bug*, not a runtime failure: nothing in this app should
/// ever invoke a write/auth method on the backend while
/// `AccountState.phase == AccountPhase.unconfigured` (the settings tile and
/// the future sync engine both gate on that state first) — callers should
/// treat catching this as a signal to fix that gating, not as a case to
/// handle gracefully at every call site.
class SyncUnconfigured implements Exception {
  final String message;
  const SyncUnconfigured([this.message = 'sync backend is not configured']);

  @override
  String toString() => 'SyncUnconfigured: $message';
}

/// A configured backend's request failed for a transport reason (no
/// connectivity, timeout, non-2xx/5xx response, malformed response body).
/// Distinguished from [SyncAuthError] so callers (Task 4's sync engine and
/// account screen) can retry a [SyncNetworkError] silently but must surface
/// a [SyncAuthError] to the user.
class SyncNetworkError implements Exception {
  final String message;
  const SyncNetworkError(this.message);

  @override
  String toString() => 'SyncNetworkError: $message';
}

/// A configured backend rejected an auth operation itself — wrong/expired
/// OTP code, revoked session, account deleted server-side, etc. Never
/// thrown by [UnconfiguredBackend] (which throws [SyncUnconfigured]
/// instead): this is specifically "the backend understood the request and
/// said no", not "there is no backend to ask".
class SyncAuthError implements Exception {
  final String message;
  const SyncAuthError(this.message);

  @override
  String toString() => 'SyncAuthError: $message';
}

/// The M5 sync contract: everything the app needs from an account/sync
/// backend, independent of which service implements it.
///
/// This is the seam the rest of M5 is built against — Task 3's
/// `SupabaseBackend` is a thin adapter onto `supabase_flutter` implementing
/// this exact interface, and Task 4's `SyncEngine` and account screen are
/// written only against these methods, never against Supabase types
/// directly. [UnconfiguredBackend] (below) is the implementation used for
/// every build that hasn't set `SUPABASE_URL`/`SUPABASE_ANON_KEY` — which,
/// per the M5 global constraint, must be indistinguishable from M4: no
/// network calls, ever.
///
/// Event journal notes shared by [pushEvents]/[pullEventsSince]: the local
/// `GameJournal` (`game/events.dart`) is append-only and the reducers
/// dedupe by [GameEvent.id], so both directions of sync are naturally
/// idempotent — pushing an event the server already has, or pulling one the
/// journal already has, is expected to be a safe no-op rather than an
/// error.
abstract class SyncBackend {
  /// The currently signed-in user, or `null` if nobody is signed in (or the
  /// session expired). Never throws for "not signed in" — only for a
  /// genuine backend failure (a configured backend: [SyncNetworkError]; an
  /// unconfigured one: [SyncUnconfigured]).
  Future<AuthUser?> currentUser();

  /// Requests a one-time login code be sent to [email]. Completes once the
  /// backend has accepted the request, not once the email arrives.
  Future<void> signInWithOtp(String email);

  /// Redeems the [code] sent to [email] by a prior [signInWithOtp] call.
  /// Returns the now-signed-in [AuthUser] on success. An invalid/expired
  /// code is a [SyncAuthError], not a `null` return — a `null` return is
  /// reserved for backends that don't distinguish (none currently do; kept
  /// nullable for forward compatibility with the contract's shape
  /// elsewhere).
  Future<AuthUser?> verifyOtp(String email, String code);

  /// Ends the current session, if any. Safe to call with no active session
  /// on a configured backend (a no-op); [UnconfiguredBackend] still throws
  /// [SyncUnconfigured] — callers are expected to gate on `AccountState`
  /// before calling any auth method at all, see [SyncUnconfigured]'s doc.
  Future<void> signOut();

  /// Uploads [events] the local journal has produced. Events already known
  /// to the server (same [GameEvent.id]) are accepted silently, not
  /// rejected — see this class's doc comment on idempotency. Order within
  /// [events] is not significant to the backend; the server is a bag of
  /// events keyed by id, not an ordered log.
  Future<void> pushEvents(List<GameEvent> events);

  /// Fetches remote events the caller doesn't have yet, resuming from
  /// [cursor] (`null` to start from the beginning). See [PullPage] for how
  /// to drive pagination across multiple calls.
  Future<PullPage> pullEventsSince(String? cursor);

  /// Upserts the signed-in user's leaderboard profile — display name and
  /// cumulative distance — so [topProfiles] (called by anyone, signed in or
  /// not) can include it.
  Future<void> upsertProfile(String pseudo, double totalKm);

  /// The top [limit] leaderboard rows across all accounts on this backend,
  /// ranked by `totalKm` descending.
  Future<List<LeaderboardRow>> topProfiles(int limit);

  /// Permanently deletes the signed-in user's account and all
  /// server-side data belonging to it (Task 2: cascading `delete_account`
  /// RPC). Irreversible; the local journal is untouched by this call — any
  /// local purge is a separate, explicit step (Task 6).
  Future<void> deleteAccount();
}

/// The [SyncBackend] used by every build that has no Supabase configuration
/// (`SupabaseConfig.fromEnvironment() == null` — the default). Performs
/// zero network I/O, which is what makes the M5 global constraint ("sans
/// configuration, rien ne change") checkable by inspection as well as by
/// test: there is no `http`/`supabase_flutter` call anywhere in this class
/// to accidentally fire.
///
/// Method-by-method behaviour (the contract Task 1's report records):
/// - Auth methods ([currentUser], [signInWithOtp], [verifyOtp], [signOut],
///   [deleteAccount]) throw [SyncUnconfigured]. `currentUser` throwing
///   rather than returning `null` is deliberate: it forces every call site
///   to go through `AccountState` (which is always `unconfigured` here)
///   rather than silently treating "no backend" the same as "backend says
///   nobody's signed in".
/// - Pull methods ([pullEventsSince], [topProfiles]) return an empty
///   result rather than throwing — these are read paths a caller may poll
///   opportunistically (e.g. a leaderboard screen), and an empty result is
///   already the correct, representable answer ("nothing to show").
/// - Write methods ([pushEvents], [upsertProfile]) throw [SyncUnconfigured]
///   — silently discarding data the caller believes it just persisted
///   remotely would be a correctness trap, not graceful degradation.
class UnconfiguredBackend implements SyncBackend {
  const UnconfiguredBackend();

  @override
  Future<AuthUser?> currentUser() async => throw const SyncUnconfigured();

  @override
  Future<void> signInWithOtp(String email) async =>
      throw const SyncUnconfigured();

  @override
  Future<AuthUser?> verifyOtp(String email, String code) async =>
      throw const SyncUnconfigured();

  @override
  Future<void> signOut() async => throw const SyncUnconfigured();

  @override
  Future<void> pushEvents(List<GameEvent> events) async =>
      throw const SyncUnconfigured();

  @override
  Future<PullPage> pullEventsSince(String? cursor) async =>
      const PullPage(events: []);

  @override
  Future<void> upsertProfile(String pseudo, double totalKm) async =>
      throw const SyncUnconfigured();

  @override
  Future<List<LeaderboardRow>> topProfiles(int limit) async => const [];

  @override
  Future<void> deleteAccount() async => throw const SyncUnconfigured();
}
