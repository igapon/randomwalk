import 'package:shared_preferences/shared_preferences.dart';

/// Everything [SyncEngine] (`sync/sync_engine.dart`) needs to remember
/// between calls to `sync()`: how much of the local journal is confirmed
/// pushed, and how far the remote pull has progressed.
///
/// **Push marker design (binding — see `task-4-report.md` for the full
/// writeup): "last pushed journal line index + catch-up set".**
///
/// - [pushedIndex] is the number of leading journal lines (in
///   `GameJournal.readAll()`'s append order) that are known to exist on the
///   server. Every sync push round only ever considers events at or past
///   this index.
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
class PrefsSyncStateStore implements SyncStateStore {
  static const _pushedIndexKey = 'sync_pushed_index';
  static const _catchupIdsKey = 'sync_pushed_catchup_ids';
  static const _pullCursorKey = 'sync_pull_cursor';

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
