import 'package:shared_preferences/shared_preferences.dart';

/// Everything [SyncEngine] (`sync/sync_engine.dart`) needs to remember
/// between calls to `sync()`: how much of the local journal is confirmed
/// pushed, and how far the remote pull has progressed.
///
/// **Push marker design (binding — see `task-4-report.md` for the full
/// writeup): "last pushed journal line index + catch-up set".**
///
/// - [pushedIndex] is an index into `GameJournal.readAll()`'s PARSED
///   result (its append order, minus any line that call couldn't parse) —
///   NOT a count of raw file lines. `readAll()` silently skips an
///   unparseable line (e.g. a torn write from a crash mid-append,
///   `GameJournal.skippedLines`), so this index shifts if a line that used
///   to parse stops parsing (or vice versa) between two `sync()` calls;
///   `SyncEngine._dropMarkerIfJournalIsCorrupt` resets it to 0 whenever
///   that call's `readAll()` reports any skipped lines, rather than trust
///   a position that may no longer mean what it did when it was written
///   (fix round 1, Task 4 review I3). Every sync push round only ever
///   considers events at or past this index.
/// - [pushedCatchupIds] holds the ids of events *past* [pushedIndex] that
///   are already known server-side without this device ever pushing
///   them itself — specifically, events merged in from a pull (see
///   [SyncEngine]'s merge step) land at the tail of the journal, after
///   [pushedIndex], but must never be re-uploaded. [SyncEngine] "folds"
///   these into [pushedIndex] whenever they form a contiguous run
///   starting exactly at [pushedIndex] (the common case), which is what
///   keeps this set small and bounded — bounded by how many
///   locally-authored, not-yet-pushed events this device can have
///   in flight at once, not by the total journal history.
///
/// Both fields, plus [pullCursor] (the opaque cursor string from
/// `SyncBackend.pullEventsSince`/`PullPage.nextCursor` — see that class's
/// dartdoc for its format; this store never parses it), are persisted
/// together so a process restart mid-sync resumes from the last durably
/// written checkpoint rather than from scratch or from a corrupted mix.
///
/// **Crash-recovery invariant:** every field here is only ever advanced
/// *after* the operation it reflects has actually completed (pushed to the
/// server, or appended to the local journal). A crash between "operation
/// completed" and "this store's write lands" cannot lose data — the next
/// `sync()` simply repeats the not-yet-recorded step, which is always safe:
/// re-pushing an already-pushed event is a server-side no-op (`ON CONFLICT
/// DO NOTHING`, per `SyncBackend.pushEvents`'s dartdoc), and re-pulling
/// from a stale cursor re-merges events the journal already has, which
/// `SyncEngine`'s id-based merge silently skips.
class SyncCursorState {
  final int pushedIndex;
  final Set<String> pushedCatchupIds;
  final String? pullCursor;

  const SyncCursorState({
    this.pushedIndex = 0,
    this.pushedCatchupIds = const {},
    this.pullCursor,
  });

  SyncCursorState copyWith({
    int? pushedIndex,
    Set<String>? pushedCatchupIds,
    String? pullCursor,
    bool clearPullCursor = false,
  }) => SyncCursorState(
    pushedIndex: pushedIndex ?? this.pushedIndex,
    pushedCatchupIds: pushedCatchupIds ?? this.pushedCatchupIds,
    pullCursor: clearPullCursor ? null : (pullCursor ?? this.pullCursor),
  );
}

/// Persists/restores [SyncCursorState] across process restarts.
abstract class SyncStateStore {
  Future<SyncCursorState> read();
  Future<void> write(SyncCursorState state);
}

/// [SyncStateStore] backed by `shared_preferences`, matching how
/// `settings/identity.dart`'s `IdentityStore` persists small bits of local
/// state. All three fields are written together in a single logical
/// checkpoint per [write] call — [SyncEngine] decides when a checkpoint is
/// due (see its own doc comment), this store just durably records whatever
/// it's handed.
///
/// **Scoped by [uid] (fix round 1, Task 4 review C2).** The three
/// `shared_preferences` keys embed [uid], the signed-in
/// [AuthUser.uid](`sync/backend.dart`) — NOT the anonymous
/// `drive.lmqc.fr`/`PlayerIdentity.userId` this store has nothing to do
/// with. Without this, signing out and into a *different* account (or
/// `deleteAccount` followed by re-signup, which yields a new uid) would
/// reuse the previous account's checkpoint: [pullCursor] would resolve to
/// `WHERE (inserted_at, id) > (old account's cursor)` against the NEW
/// account's rows (RLS-scoped, so unrelated to the old account's
/// `inserted_at` values) and silently skip that account's entire history,
/// while [pushedIndex] would claim journal lines are already on a server
/// that has never seen them, so they'd never be (re-)uploaded either —
/// both silent and permanent. Scoping by [uid] means a *new* account
/// simply reads back the zero [SyncCursorState] (nothing has ever been
/// written under its key), which is exactly "full pull from the
/// beginning, full push of everything local" — safe by the same
/// idempotency [SyncEngine] already relies on. A *returning* account
/// (same uid signs out and back in) resumes exactly where it left off,
/// with no explicit sign-out cleanup needed — see `settings/account_screen
/// .dart`'s `_signOut`.
class PrefsSyncStateStore implements SyncStateStore {
  /// Key suffix used when no account is signed in yet — [SyncEngine] is
  /// never actually invoked in that state (every call site gates on
  /// `AccountPhase.signedIn` first, see `sync/auto_sync.dart`), so this
  /// exists only so constructing this class never requires a non-null uid
  /// up front.
  static const noAccountUid = '_no_account';

  final String uid;

  const PrefsSyncStateStore(this.uid);

  String get _pushedIndexKey => 'sync_pushed_index::$uid';
  String get _catchupIdsKey => 'sync_pushed_catchup_ids::$uid';
  String get _pullCursorKey => 'sync_pull_cursor::$uid';

  @override
  Future<SyncCursorState> read() async {
    final prefs = await SharedPreferences.getInstance();
    return SyncCursorState(
      pushedIndex: prefs.getInt(_pushedIndexKey) ?? 0,
      pushedCatchupIds: (prefs.getStringList(_catchupIdsKey) ?? const [])
          .toSet(),
      pullCursor: prefs.getString(_pullCursorKey),
    );
  }

  @override
  Future<void> write(SyncCursorState state) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_pushedIndexKey, state.pushedIndex);
    await prefs.setStringList(_catchupIdsKey, state.pushedCatchupIds.toList());
    final cursor = state.pullCursor;
    if (cursor == null) {
      await prefs.remove(_pullCursorKey);
    } else {
      await prefs.setString(_pullCursorKey, cursor);
    }
  }
}
