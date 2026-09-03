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

  /// True when the pull loop stopped for a reason OTHER than the backend
  /// naturally running out of pages (an empty page, or a null cursor) —
  /// either [kMaxSyncPullPages] was reached, or the backend returned the
  /// SAME cursor twice in a row. M5 final review, Important I9: before this
  /// field existed, `_runSync`'s pull loop was `while (true)` with no upper
  /// bound at all — a backend bug (or a proxy/tie-mishandling edge case)
  /// that ever returned a non-advancing `nextCursor` would spin forever,
  /// hammering the network indefinitely, since `fresh` staying empty never
  /// trips the existing "empty page" break and the cursor never becomes
  /// null either. A correctly-implemented backend (the cursor contract is
  /// exclusive, see `PullPage`'s dartdoc) always advances it, so this is a
  /// defensive cap for something that should never happen against a real
  /// server — not a normal outcome — which is exactly why it is surfaced
  /// here rather than silently retried: a caller that logs/reports sync
  /// health has something to alert on.
  final bool pullBounded;

  const SyncReport({
    required this.pushedCount,
    required this.pulledCount,
    this.pullBounded = false,
  });
}

/// Safety cap on how many pull pages one [SyncEngine.sync] call will ever
/// fetch — see [SyncReport.pullBounded]'s dartdoc. Chosen generously above
/// any real page count this app should ever see (`SupabaseBackend`'s pull
/// page size is in the hundreds, so 50 pages is tens of thousands of
/// events) while still bounding the worst case to a finite, small number of
/// network round-trips rather than none at all.
const kMaxSyncPullPages = 50;

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
/// **Fix round 1 (Task 4 review, C1) — the index must be computed against
/// the file, never a stale in-memory copy of it.** `sync()`'s local
/// `events` variable is re-read from `journal.readAll()` immediately after
/// every `journal.appendAll(fresh)` in the merge step (not patched in
/// memory via `[...events, ...fresh]`), and [_compact] only ever walks
/// positions in that freshly-read list. This matters because the local
/// journal is not exclusively this engine's to write: `ExplorationRecorder`
/// and `GameVisitConsumer` both append to it fire-and-forget, concurrently
/// with a sync a post-trip `runAutoSync` call can start at almost the same
/// moment (`trip_controller.dart`'s `_finalise`). If a local event landed
/// on disk between this call's initial `readAll()` and the merge's
/// `appendAll`, an in-memory-only patch would silently drop it from
/// `events` — positions after it would be off by one, and [_compact] would
/// advance `pushedIndex` past that real (unpushed) file row, permanently
/// marking it "pushed" without it ever having been. Re-reading the file is
/// the fix: the concurrently-appended event keeps its real position below
/// `pushedIndex` and stays eligible for the next push, at the cost of one
/// extra `readAll()` per merge round (only when something was actually
/// pulled) — see `sync_engine_test.dart`'s "a local event appended between
/// pull and merge is still pushed on the next sync" for the regression
/// test this fix is pinned by.
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

  /// The currently in-flight [_runSync] call, if any — see [sync]'s doc
  /// comment (fix round 1, Task 4 review I1).
  Future<SyncReport>? _inFlight;

  /// Reconciles the local journal with the backend — see the class
  /// dartdoc's "push, pull, merge, recompute" for the shape.
  ///
  /// **Single-flight (fix round 1, Task 4 review I1):** nothing serialises
  /// `runAutoSync`'s three call sites (launch, post-trip, the manual
  /// button) against each other — a post-trip auto-sync can genuinely
  /// overlap the manual button, or a slow launch sync. Two truly
  /// independent `sync()` calls would each snapshot the journal before the
  /// other's `appendAll`, so both would treat the same pulled page as
  /// "fresh" and both append it — duplicate journal lines, and
  /// `pushedIndex` further off from the file (the same failure shape as
  /// C1, just from a different cause). Instead, a call made while one is
  /// already running joins that SAME in-flight [Future] — both callers
  /// `await` the one round of actual work and get back the identical
  /// [SyncReport] — rather than starting a second, overlapping round.
  Future<SyncReport> sync() {
    final existing = _inFlight;
    if (existing != null) return existing;
    // `.whenComplete()`'s own returned future — not a second, separate one
    // derived from `_runSync()` and left unconsumed — is what gets stored
    // and returned: every caller (however many join this one round) and
    // the `_inFlight = null` cleanup are then just multiple listeners on
    // that SAME future, which `Future` supports natively. Splitting them
    // into two different future objects (e.g. `_runSync()` stored in
    // `_inFlight` while a *different* `.whenComplete(...)` chained off it
    // gets discarded) would leave that second, unconsumed future's
    // potential error unhandled — Dart reports that as a zone-level
    // uncaught error even though the first future's error is properly
    // caught by real callers.
    final future = _runSync().whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  Future<SyncReport> _runSync() async {
    var state = await stateStore.read();
    var events = await journal.readAll();
    state = await _reconcileCorruption(state, journal.skippedLines);

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
    var pullBounded = false;
    final knownIds = events.map((e) => e.id).toSet();
    var cursor = state.pullCursor;
    var pageCount = 0;
    while (true) {
      if (pageCount >= kMaxSyncPullPages) {
        // See kMaxSyncPullPages's dartdoc — a defensive cap, not a normal
        // stopping point.
        pullBounded = true;
        break;
      }
      pageCount++;
      final previousCursor = cursor;
      final page = await backend.pullEventsSince(cursor);
      if (page.events.isEmpty) break;

      final fresh = [
        for (final e in page.events)
          if (!knownIds.contains(e.id)) e,
      ];
      if (fresh.isNotEmpty) {
        await journal.appendAll(fresh);
        // Fix round 1 (Task 4 review, C1): re-anchor to the file itself
        // rather than patching the in-memory snapshot with
        // `[...events, ...fresh]`. If a local event was appended to the
        // journal by something else (ExplorationRecorder,
        // GameVisitConsumer — both fire concurrently with a post-trip
        // sync, see runAutoSync's callers) between this call's original
        // `readAll()` and this `appendAll`, an in-memory patch would not
        // contain it — yet `_compact` below walks positions in `events`,
        // so it would advance `pushedIndex` past that real file slot
        // anyway (indices computed from the stale, shorter list landing on
        // the wrong file rows) and silently mark a never-pushed local
        // event as pushed, forever. Re-reading here makes `events` (and
        // therefore every index `_compact` computes) match the file
        // exactly, so a concurrently-appended local event stays below
        // `pushedIndex` and stays pushable.
        events = await journal.readAll();
        state = await _reconcileCorruption(state, journal.skippedLines);
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

      // M5 final review, Important I9: a correct backend's cursor is
      // exclusive, so a page that returned events always moves it forward —
      // if it comes back IDENTICAL to what was just sent, fetching again
      // with the same cursor would only ever reproduce the same page
      // forever (`fresh` already empty for every id this journal has seen,
      // so `pulledCount` would never grow either). Stop instead of spinning.
      if (cursor == previousCursor) {
        pullBounded = true;
        break;
      }
    }

    if (pulledCount > 0) {
      onRecompute();
    }

    return SyncReport(
      pushedCount: pushedCount,
      pulledCount: pulledCount,
      pullBounded: pullBounded,
    );
  }

  /// Fix round 1 (Task 4 review I3), corrected in fix round 2 (Task 4
  /// review NEW-1): [SyncCursorState.pushedIndex] indexes
  /// `journal.readAll()`'s PARSED result, not raw file lines — [GameJournal]
  /// skips any line it cannot parse (a torn write from a crash mid-append)
  /// and reports how many via [GameJournal.skippedLines], reflecting only
  /// the call just made. A line that was parseable last sync but becomes
  /// corrupt before this one (or vice versa) shifts every later index by
  /// one relative to what [pushedIndex] assumed, which could otherwise
  /// silently mis-mark a real, never-pushed event as already covered.
  /// Since there is no way to tell whether the corruption fell before or
  /// after [SyncCursorState.pushedIndex] from [skippedLines] alone, the
  /// only safe response is to stop trusting the positional marker: reset
  /// [SyncCursorState.pushedIndex] to 0 so the push phase reconsiders the
  /// whole journal. A resulting redundant push is harmless (`ON CONFLICT
  /// DO NOTHING`, same as every other idempotent-retry path this class
  /// relies on); silently dropping an event is not.
  ///
  /// **Fix round 1's version of this compared `skippedLines` to a
  /// hard-coded `0`, not to what was already accounted for** — so on a
  /// journal with a PERSISTENT torn line (which [GameJournal] never
  /// repairs; nothing here can heal it either), this reset fired on
  /// *every single* `sync()` call forever: a full re-push on every launch
  /// and every trip end, and a pull's cursor could never durably stick
  /// either (compaction always ran against a freshly-zeroed index before
  /// it could settle). The fix: [SyncCursorState.knownSkippedLines] records
  /// the `skippedLines` count [pushedIndex] was last computed against, and
  /// the reset only fires when the CURRENT count differs from that — i.e.
  /// "corruption changed since the last checkpoint", not "corruption is
  /// present". A changed count is persisted IMMEDIATELY (not left for a
  /// later phase's own `stateStore.write`, which might not run at all this
  /// round — e.g. nothing new to push) precisely so the next `sync()` call
  /// reads back the same count it just observed and does NOT reset again.
  /// [pushedCatchupIds] is left as-is on a reset — those ids are still
  /// filtered out of `toPush` by id regardless of [pushedIndex], so keeping
  /// them avoids redundant re-uploads for exactly the events the reset
  /// doesn't need to reconsider.
  Future<SyncCursorState> _reconcileCorruption(
    SyncCursorState state,
    int skippedLines,
  ) async {
    if (skippedLines == state.knownSkippedLines) return state;
    final reconciled = state.copyWith(
      pushedIndex: 0,
      knownSkippedLines: skippedLines,
    );
    await stateStore.write(reconciled);
    return reconciled;
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
