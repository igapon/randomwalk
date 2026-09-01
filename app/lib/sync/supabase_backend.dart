import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../game/events.dart';
import 'backend.dart';
import 'config.dart';

/// A thin adapter from [SyncBackend] onto `supabase_flutter`, matching
/// `supabase/migrations/0001_init.sql` and its design notes
/// (`supabase/notes.md`) exactly. Every method here is a direct translation
/// of one [SyncBackend] call into one PostgREST/GoTrue call — no retries, no
/// caching, no merge/replay logic. That belongs to Task 4's `SyncEngine`,
/// which is written only against the [SyncBackend] interface and never
/// against this class or the `supabase_flutter` types it wraps.
///
/// Method-by-method mapping (see `task-3-report.md` for the full table):
/// - [currentUser] reads the locally-cached GoTrue session
///   (`auth.currentUser`) — no network round trip.
/// - [signInWithOtp]/[verifyOtp]/[signOut] map onto GoTrue's
///   `signInWithOtp`/`verifyOTP(type: OtpType.email)`/`signOut`.
/// - [pushEvents] calls the `push_events` RPC with a JSON array shaped like
///   [GameEvent.toJson], except [GameEvent.ts] is forced to UTC first (see
///   [eventToRow]) — required because the migration's `::timestamptz` cast
///   is ambiguous on an offset-less string (`supabase/notes.md` "Still Task
///   3/4's responsibility").
/// - [pullEventsSince] reads `game_events` directly (RLS scopes it to the
///   caller's own rows — no explicit `user_id` filter needed) using the
///   two-field `(inserted_at, id)` cursor described on [encodeCursor].
/// - [upsertProfile] upserts `profiles` directly, keyed on `user_id`.
/// - [topProfiles] calls the `top_profiles` RPC.
/// - [deleteAccount] calls the `delete_account` RPC.
///
/// Construction alone never touches the network: the `supabase_flutter`
/// singleton is initialized lazily, on the first call that actually needs
/// it (see [_ensureClient]) — [SupabaseConfig.fromEnvironment] already
/// gates whether a [SupabaseBackend] is constructed at all
/// (`sync/providers.dart`), so this is a second, independent line of
/// defense against ever calling `Supabase.initialize` for an unconfigured
/// build.
class SupabaseBackend implements SyncBackend {
  final SupabaseConfig config;

  SupabaseBackend(this.config);

  /// Page size for [pullEventsSince]. Not part of the [SyncBackend]
  /// contract (callers page by following [PullPage.nextCursor] until
  /// [PullPage.events] comes back empty) — purely an implementation detail
  /// of how many rows one round trip fetches.
  static const int _pageSize = 200;

  /// `Supabase.initialize` is idempotent (it logs and returns the existing
  /// singleton if already initialized — see `supabase_flutter`'s
  /// `Supabase.initialize` source), so calling it on every method
  /// invocation is safe and cheap after the first call; it is what makes
  /// initialization lazy without this class needing to track its own
  /// "have I initialized yet" flag.
  ///
  /// [SupabaseConfig.anonKey] is passed as `publishableKey` — the current
  /// `supabase_flutter` parameter name (its own `anonKey` parameter is
  /// deprecated in favor of it, same value, no behaviour difference).
  /// [SupabaseConfig]'s own field is unrenamed since it isn't this task's
  /// file (Task 1 owns it) and `SUPABASE_ANON_KEY` is also the dart-define
  /// name the setup guide (`supabase/README.md`) documents.
  Future<sb.SupabaseClient> _ensureClient() async {
    await sb.Supabase.initialize(
      url: config.url,
      publishableKey: config.anonKey,
    );
    return sb.Supabase.instance.client;
  }

  @override
  Future<AuthUser?> currentUser() async {
    try {
      final client = await _ensureClient();
      return userToAuthUser(client.auth.currentUser);
    } catch (e) {
      throw mapError(e);
    }
  }

  @override
  Future<void> signInWithOtp(String email) async {
    try {
      final client = await _ensureClient();
      await client.auth.signInWithOtp(email: email);
    } catch (e) {
      throw mapError(e);
    }
  }

  @override
  Future<AuthUser?> verifyOtp({
    required String email,
    required String code,
  }) async {
    try {
      final client = await _ensureClient();
      final response = await client.auth.verifyOTP(
        type: sb.OtpType.email,
        email: email,
        token: code,
      );
      return userToAuthUser(response.user);
    } catch (e) {
      throw mapError(e);
    }
  }

  @override
  Future<void> signOut() async {
    try {
      final client = await _ensureClient();
      await client.auth.signOut();
    } catch (e) {
      throw mapError(e);
    }
  }

  @override
  Future<void> pushEvents(List<GameEvent> events) async {
    try {
      final client = await _ensureClient();
      await client.rpc(
        'push_events',
        params: {'events': events.map(eventToRow).toList()},
      );
    } catch (e) {
      throw mapError(e);
    }
  }

  @override
  Future<PullPage> pullEventsSince(String? cursor) async {
    try {
      final client = await _ensureClient();
      var query = client
          .from('game_events')
          .select('id, ts, type, payload, inserted_at');
      if (cursor != null) {
        final decoded = decodeCursor(cursor);
        // Composite-cursor pagination: PostgREST has no tuple comparison
        // syntax, so "(inserted_at, id) > (:cursor)" (supabase/notes.md
        // section 1) is expressed as the equivalent OR of two filters —
        // strictly later inserted_at, OR same inserted_at with a strictly
        // later id (the tiebreaker) — matching the composite index and the
        // ORDER BY below exactly.
        query = query.or(
          'inserted_at.gt.${decoded.insertedAt},'
          'and(inserted_at.eq.${decoded.insertedAt},id.gt.${decoded.id})',
        );
      }
      final rows = await query
          .order('inserted_at')
          .order('id')
          .limit(_pageSize);
      final events = rows.map(rowToEvent).toList();
      final nextCursor = rows.isEmpty
          ? null
          : encodeCursor(
              insertedAt: rows.last['inserted_at'] as String,
              id: rows.last['id'] as String,
            );
      return PullPage(events: events, nextCursor: nextCursor);
    } catch (e) {
      throw mapError(e);
    }
  }

  @override
  Future<void> upsertProfile({
    required String pseudo,
    required double totalKm,
  }) async {
    try {
      final client = await _ensureClient();
      final uid = client.auth.currentUser?.id;
      await client.from('profiles').upsert({
        if (uid != null) 'user_id': uid,
        'pseudo': pseudo,
        'total_km': totalKm,
      }, onConflict: 'user_id');
    } catch (e) {
      throw mapError(e);
    }
  }

  @override
  Future<List<LeaderboardRow>> topProfiles({required int limit}) async {
    try {
      final client = await _ensureClient();
      final response = await client.rpc(
        'top_profiles',
        params: {'p_limit': limit},
      );
      final rows = (response as List).cast<Map<String, dynamic>>();
      return rows.map(rowToLeaderboardRow).toList();
    } catch (e) {
      throw mapError(e);
    }
  }

  @override
  Future<void> deleteAccount() async {
    try {
      final client = await _ensureClient();
      await client.rpc('delete_account');
    } catch (e) {
      throw mapError(e);
    }
  }

  // ---------------------------------------------------------------------
  // Pure mapping helpers below — no client, no network. These are the
  // pieces this task's tests exercise directly (see
  // test/sync/supabase_backend_test.dart).
  // ---------------------------------------------------------------------

  /// Maps a GoTrue [sb.User] (as returned by `auth.currentUser` and
  /// `verifyOTP`) onto the contract's [AuthUser]. `null` in, `null` out —
  /// "no user" is not an error at this layer, see [currentUser]'s
  /// dartdoc on [SyncBackend].
  static AuthUser? userToAuthUser(sb.User? user) =>
      user == null ? null : AuthUser(uid: user.id, email: user.email);

  /// One [GameEvent] as the JSON object `push_events` expects inside its
  /// `events` array — the same shape as [GameEvent.toJson] except [ts] is
  /// forced to UTC first. The migration's `push_events` casts the incoming
  /// `ts` string to `timestamptz`; an offset-less string is interpreted
  /// against the session's timezone (ambiguous), so this class — not the
  /// SQL layer — is what guarantees an explicit UTC marker
  /// (`supabase/notes.md`, "Still Task 3/4's responsibility").
  static Map<String, dynamic> eventToRow(GameEvent event) => {
    'id': event.id,
    'ts': event.ts.toUtc().toIso8601String(),
    'type': event.type,
    'payload': event.payload,
  };

  /// One row from a `game_events` select (`id, ts, type, payload,
  /// inserted_at`) back into a [GameEvent]. [GameEvent.fromJson] only reads
  /// the four keys it knows about, so the extra `inserted_at` column
  /// (needed by [pullEventsSince] to build the next cursor, but not part
  /// of [GameEvent] itself) is silently ignored here.
  static GameEvent rowToEvent(Map<String, dynamic> row) =>
      GameEvent.fromJson(row);

  /// One row from the `top_profiles` RPC (`pseudo, total_km, rank`) into a
  /// [LeaderboardRow]. `total_km`/`rank` are read via `num` first because a
  /// whole-number `double precision`/`bigint` value can arrive over JSON as
  /// either an `int` or a `double` literal depending on its value.
  static LeaderboardRow rowToLeaderboardRow(Map<String, dynamic> row) =>
      LeaderboardRow(
        pseudo: row['pseudo'] as String,
        totalKm: (row['total_km'] as num).toDouble(),
        rank: (row['rank'] as num).toInt(),
      );

  /// Encodes the two-field `(inserted_at, id)` cursor `pullEventsSince`
  /// pages by (`supabase/notes.md` section 1) into the single opaque
  /// string [PullPage.nextCursor] carries.
  ///
  /// Format: `"<inserted_at>|<id>"` — the verbatim `inserted_at` string
  /// PostgREST returned (already a valid `timestamptz` literal, e.g.
  /// `2026-09-01T10:00:00.123456+00:00`) and the row's `id` (a uuid),
  /// joined by a single `|`. Neither field can itself contain `|`, so this
  /// is unambiguous to split back apart. This format is a private
  /// implementation detail of [SupabaseBackend] — callers (Task 4's
  /// `SyncEngine`) only ever persist and replay the string verbatim, per
  /// [PullPage]'s dartdoc; they must never parse or construct it
  /// themselves.
  static String encodeCursor({
    required String insertedAt,
    required String id,
  }) => '$insertedAt|$id';

  /// Inverse of [encodeCursor]. Throws [FormatException] if [cursor] isn't
  /// exactly one `|`-joined pair — which only happens if a caller passes
  /// back a string [SupabaseBackend] didn't itself produce, a caller bug
  /// rather than a runtime/network condition, so it isn't mapped onto one
  /// of the contract's typed exceptions.
  static ({String insertedAt, String id}) decodeCursor(String cursor) {
    final parts = cursor.split('|');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) {
      throw FormatException('malformed SupabaseBackend cursor: "$cursor"');
    }
    return (insertedAt: parts[0], id: parts[1]);
  }

  /// Maps whatever `supabase_flutter`/`gotrue`/`postgrest` threw onto the
  /// [SyncBackend] contract's two typed exceptions. See
  /// `task-3-report.md`'s error-mapping table for the full rationale;
  /// summary:
  /// - [sb.AuthRetryableFetchException] (GoTrue's own name for a
  ///   transient/network auth-request failure) → [SyncNetworkError].
  /// - Any other [sb.AuthException] (wrong/expired OTP, missing session,
  ///   ...) → [SyncAuthError] — these are GoTrue affirmatively rejecting
  ///   the auth operation itself, exactly [SyncAuthError]'s doc comment.
  /// - [sb.PostgrestException] whose message is the `push_events`/
  ///   `delete_account` RPCs' own `raise exception '...: authentication
  ///   required'` → [SyncAuthError] (the backend saying "you must be
  ///   signed in", not a transport problem — `supabase/notes.md`'s open
  ///   question, resolved this way here). Every other [sb.PostgrestException]
  ///   (RLS rejections on direct table access, constraint violations,
  ///   malformed 2xx bodies, ...) → [SyncNetworkError], matching that
  ///   exception's own dartdoc, which explicitly lists "non-2xx/5xx
  ///   response" and "malformed response body" as its cases.
  /// - Everything else (no connectivity, timeout, ...) → [SyncNetworkError].
  static Exception mapError(Object error) {
    if (error is sb.AuthRetryableFetchException) {
      return SyncNetworkError(error.message);
    }
    if (error is sb.AuthException) {
      return SyncAuthError(error.message);
    }
    if (error is sb.PostgrestException) {
      if (error.message.contains('authentication required')) {
        return SyncAuthError(error.message);
      }
      return SyncNetworkError(error.message);
    }
    return SyncNetworkError(error.toString());
  }
}
