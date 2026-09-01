import '../game/events.dart';
import 'backend.dart';
import 'sync_state_store.dart';

/// Outcome of one [SyncEngine.sync] call — purely informational counts, not
/// a success/failure flag: [SyncEngine.sync] *throws* on failure (the same
/// [SyncNetworkError]/[SyncAuthError]/[SyncUnconfigured] taxonomy
/// `SyncBackend` itself uses — see that class's dartdoc), so callers that
/// reach a returned [SyncReport] at all know the call succeeded.
class SyncReport {
  /// Number of local events uploaded this round (0 if nothing was new).
  final int pushedCount;

  /// Number of remote events newly appended to the local journal this round
  /// (0 if nothing new was pulled, including "we're already caught up").
  final int pulledCount;

  const SyncReport({required this.pushedCount, required this.pulledCount});
}

/// The M5 sync engine: reconciles the local [GameJournal] with a
/// [SyncBackend] account, in four steps run in this fixed order every call
/// — **push, pull, merge, recompute** — exactly the shape the M5 plan and
/// `task-4-brief.md` specify.
///
/// ## Push marker design (binding decision, see `SyncCursorState`'s dartdoc
/// for the field-level detail)
///
/// The chosen mechanism is "last pushed journal line index + catch-up set"
/// (the brief's own phrasing), not a `pushed_ids` set covering the whole
/// journal history: an index is O(1) to store and to check "is there
/// anything new to push" against, and stays correct as the journal grows
/// into the thousands of events, which a per-id set would not (unbounded
/// growth, one entry forever per event ever pushed). The catch-up set
/// exists only to handle the one case a bare index can't: events the
/// *merge* step appends to the journal tail are already known server-side
/// (they came from the server) but land past [SyncCursorState.pushedIndex]
/// — the catch-up set records their ids so a later push round skips
/// re-uploading them, and [_compact] folds them back into the index the
/// moment they form a contiguous run from it (the normal case, since merge
/// always runs right after push within the same [sync] call).
///
/// ## Idempotency and crash safety
///
/// - **Push** is naturally idempotent: [SyncBackend.pushEvents]'s contract
///   already requires accepting already-known ids silently (`ON CONFLICT
///   DO NOTHING` server-side). This engine relies on that rather than
///   trying to avoid all redundant pushes itself — the catch-up set is an
///   optimization to *reduce* redundant traffic, not a correctness
///   requirement.
/// - **Never loses an event:** [SyncCursorState] is only durably advanced
///   (via [SyncStateStore.write]) *after* the operation it reflects has
///   actually completed — a push confirmed by [SyncBackend.pushEvents]
///   returning, or events already durably appended via
///   `GameJournal.appendAll`. A crash at any point between "operation
///   completed" and "the store write lands" simply means the next [sync]
///   call repeats that step — always safe, per the idempotency above —
///   never skips it.
/// - **Merge** dedupes by rereading the journal's own id set before
///   appending, so a partially-applied prior pull (cursor persisted, but
///   the crash happened before this round even started) can never
///   double-append.
///
/// ## Ordering
///
/// [sync] pushes first, then pulls+merges. If the push step throws, the
/// pull step is never attempted this round — deliberately: a push failure
/// is most often a connectivity/auth problem the pull would hit too, and
/// this keeps the failure mode simple (the whole call throws, nothing
/// partially applied beyond what was already durably persisted). Callers
/// that want best-effort, silent sync (launch, post-trip, per
/// `task-4-brief.md`) catch and swallow; the manual button and account
/// screen surface the error.
class SyncEngine {
  final GameJournal journal;
  final SyncBackend backend;
  final SyncStateStore stateStore;

  /// Called once, only when [sync] actually merged at least one new remote
  /// event into the journal — the "recompute" step. Defaults to a no-op;
  /// production wiring (`sync/providers.dart`) passes
  /// `GameJournalSignal.instance.bump` so `gameStateProvider` re-replays.
  final void Function() onRecompute;

  SyncEngine({
    required this.journal,
    required this.backend,
    required this.stateStore,
    void Function()? onRecompute,
  }) : onRecompute = onRecompute ?? (() {});

  Future<SyncReport> sync() async {
    var state = await stateStore.read();
    var events = await journal.readAll();

    // ---- PUSH: local events with an id the server doesn't have yet ----
    final confirmed = <String>{...state.pushedCatchupIds};
    final toPush = <GameEvent>[
      for (var i = state.pushedIndex; i < events.length; i++)
        if (!confirmed.contains(events[i].id)) events[i],
    ];
    var pushedCount = 0;
    if (toPush.isNotEmpty) {
      // Not caught: a push failure aborts the whole sync() call (see class
      // dartdoc "Ordering") — nothing has been persisted yet, so this is
      // safe to simply retry on the next call.
      await backend.pushEvents(toPush);
      pushedCount = toPush.length;
      confirmed.addAll(toPush.map((e) => e.id));
      state = _compact(state, events, confirmed);
      await stateStore.write(state);
    }

    // ---- PULL + MERGE: remote events with an id the journal doesn't
    // have yet, paginated via the opaque cursor ----
    var pulledCount = 0;
    final knownIds = events.map((e) => e.id).toSet();
    var cursor = state.pullCursor;
    while (true) {
      final page = await backend.pullEventsSince(cursor);
      if (page.events.isEmpty) break;

      final fresh = [
        for (final e in page.events)
          if (!knownIds.contains(e.id)) e,
      ];
      if (fresh.isNotEmpty) {
        await journal.appendAll(fresh);
        events = [...events, ...fresh];
        for (final e in fresh) {
          knownIds.add(e.id);
          confirmed.add(e.id); // remote-origin: already known server-side.
        }
        pulledCount += fresh.length;
      }

      cursor = page.nextCursor;
      final withCursor = cursor == null
          ? state.copyWith(clearPullCursor: true)
          : state.copyWith(pullCursor: cursor);
      state = _compact(withCursor, events, confirmed);
      await stateStore.write(state);

      // Contract (PullPage dartdoc): nextCursor is null only when events is
      // empty, which is already handled by the loop's top check — this is a
      // defensive stop, not a case the contract expects to hit.
      if (cursor == null) break;
    }

    if (pulledCount > 0) {
      onRecompute();
    }

    return SyncReport(pushedCount: pushedCount, pulledCount: pulledCount);
  }

  /// Advances [state.pushedIndex] forward through [events] while each next
  /// event's id is in [confirmed] (removing it as it's folded in), then
  /// persists whatever of [confirmed] is left over as the new catch-up set.
  /// See the class dartdoc's "Push marker design" for why this is safe and
  /// why it keeps the catch-up set bounded rather than ever-growing.
  SyncCursorState _compact(
    SyncCursorState state,
    List<GameEvent> events,
    Set<String> confirmed,
  ) {
    var idx = state.pushedIndex;
    while (idx < events.length && confirmed.remove(events[idx].id)) {
      idx++;
    }
    return state.copyWith(pushedIndex: idx, pushedCatchupIds: {...confirmed});
  }
}
