import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../exploration/edges_store.dart';
import '../game/game_state_provider.dart';
import '../history/trip_history_store.dart';
import '../sync/sync_state_store.dart';
import '../trip/finalised_trip_memory.dart';
import '../trip/trip_controller.dart';

/// French display names for [LocalDataPurge.purge]'s failure labels — what
/// `_deleteAccount`'s partial-failure snackbar and [PurgeRetryTile] both show
/// so a user actually learns *which* category survived (Task 6 review round
/// 1, Important I2), instead of a single opaque "some data could not be
/// deleted".
const _kFrenchStepLabels = {
  'journal': 'journal de jeu',
  'checkpoint': 'progression enregistrée',
  'edges': 'zones explorées',
  'track': 'trace en cours',
  'trip-history': 'historique des parcours',
  'trip-snapshot': 'trajet en cours',
  'route': 'itinéraire planifié',
  'trip-memory': 'informations de trajet en mémoire',
  'sync-state': 'préférences de synchronisation',
};

/// Renders [LocalDataPurge.purge]'s failure labels as a French,
/// comma-separated list for user-facing copy — an unrecognized label (should
/// never happen; kept as a fail-open fallback) shows verbatim rather than
/// silently dropping out of the message.
String frenchPurgeLabels(List<String> failures) =>
    failures.map((f) => _kFrenchStepLabels[f] ?? f).join(', ');

/// The one refusal message [runLocalPurge] means for BOTH `TripState
/// .recording` and `TripState.interrupted` (Task 6 review round 2, Important:
/// an interrupted trip passed the original recording-only guard, and
/// finishing it afterward — `_finalise` → `TripHistoryRecorder.process` —
/// wrote the pre-purge trip straight back into the just-emptied
/// `trip_history.db`/journal). A single shared constant, used verbatim by
/// both call sites (`AccountScreen._deleteAccount`'s purge offer and
/// [PurgeRetryTile]'s retry) and both their tests, so the copy can never
/// drift between them again — round 2 also fixed a `tu`/`vous` register
/// mix-up the re-review flagged; this app's copy is `vous` throughout.
const kPurgeRefusedTripActiveMessage =
    'Terminez ou abandonnez votre trajet en cours avant de supprimer les '
    'données.';

/// Deletes every piece of LOCAL game data this device holds: the game
/// journal, its periodic checkpoint, the covered-edges store, trip history,
/// any leftover in-progress track/snapshot/route files (and their `.tmp`
/// write-ahead siblings), the finalised-trip/pending-celebration prefs —
/// plus, when [uid] is given, that account's own sync checkpoint keys.
///
/// **A separate, EXPLICIT step (Task 6's binding decision).** Never implied
/// by `SyncBackend.deleteAccount()` itself (that RPC only touches the
/// server — see its dartdoc) and never implied by a local sign-out either.
/// Local-first game data belongs to the device owner: this is something the
/// player opts into on top of deleting their account, not something account
/// deletion does to them.
///
/// **Purge inventory** (binding, accumulated from prior task reviews):
/// - `game/game_events.jsonl` — the append-only event journal
///   (`GameJournal`, `game/events.dart`), the source of truth for
///   coins/XP/badges/visited places/revealed cells/covered edges.
/// - `game/game_state_checkpoint.json` (plus its `.tmp` write-ahead sibling
///   — see below) — a periodic snapshot of the exact same profile data,
///   persisted *independently* of the journal (`GameStateCheckpointStore`,
///   `game/state_checkpoint.dart` — see its own dartdoc, flagged by Task 5
///   review I4: "any local purge ... MUST delete this file alongside the
///   journal, or a deleted account's data survives in it").
/// - `covered_edges.db` — the covered-OSM-way-id store (`EdgesStore`,
///   `exploration/edges_store.dart`). Cleared via [EdgesStore.clear]
///   (`DELETE FROM covered_edges`) rather than deleting the file outright —
///   see that method's own dartdoc for why: `main.dart`'s `TripController`
///   keeps its own `EdgesStore` handle open for the app's entire lifetime,
///   and `sqflite` reference-counts one native connection per path, so
///   clearing the table reuses that same connection instead of risking a
///   stale file descriptor.
/// - `trip_history.db` — every finalised trip's full GPS trace
///   (`TripHistoryStore`, `history/trip_history_store.dart`). **Critical,
///   Task 6 review round 1**: `account_screen.dart`'s local-purge dialog
///   explicitly promises "parcours" are removed, and this store was never
///   purged at all — a user who opted in kept every historical GPS trace on
///   disk. Fixed with a two-step removal: [TripHistoryStore.deleteAll]
///   (clears every row) FIRST, THEN the `.db` file itself is deleted
///   outright — unlike `covered_edges.db`, this pairs a row-clear with an
///   actual file deletion, because the dialog's promise is "gone from
///   disk", not merely "emptied". `main.dart`'s `TripHistoryRecorder` keeps
///   its own `TripHistoryStore` handle open for the app's whole lifetime,
///   same as `TripController` does for `EdgesStore` — the row-clear runs
///   first specifically so [TripHistoryStore.list] still reads back empty
///   even in the accepted edge case that live handle keeps the file
///   descriptor alive past the delete (POSIX unlink semantics: the
///   directory entry is removed immediately regardless of who still has the
///   file open — the file deletion itself never fails or blocks on that
///   handle). The one remaining, deliberately accepted gap: a trip that is
///   *started and finished in the same still-running process*, after this
///   purge, could be recorded by that pre-existing handle into the
///   now-unlinked file and only reappear after the app restarts — judged
///   acceptable given [purge] already refuses to run at all while a trip is
///   recording (see `runLocalPurge`'s own dartdoc), so this can only happen
///   if the player starts a brand-new trip after the purge completes.
/// - `trip_snapshot.json` (plus its two `.tmp`/`.ui.tmp` write-ahead
///   siblings — see below) — the live/resumable trip state (current
///   distance, steps, route polyline, pending landmark visits — all real
///   coordinates) written by the tracking service
///   (`tracking/trip_snapshot.dart`'s `FileTripSnapshotStore`, wired in
///   `main.dart`). Important, Task 6 review round 1: same directory and
///   same category as `active_track.jsonl` (which was already purged) but
///   was missed. Deleting this file while a trip is actively recording
///   would corrupt that trip's live state out from under the running
///   foreground service — see `runLocalPurge`'s own dartdoc for the
///   refuse-while-recording guard that makes deleting it here safe.
/// - `active_track.jsonl` — the in-progress GPS track file
///   (`tracking/tracking_service.dart`, `exploration/exploration_recorder
///   .dart`). Normally deleted by the trip-processing pipeline itself once a
///   trip finishes; only ever present here as a leftover from a
///   trip in progress or one that crashed mid-processing, but included for
///   completeness ("reveal/track" data per `task-6-brief.md`).
/// - `active_route.json` (plus its `.tmp` write-ahead sibling — see below)
///   — the planned route (`trip/active_route_store.dart`'s
///   `FileActiveRouteStore`, wired in `main.dart`): the FULL route polyline
///   plus the destination/departure coordinates the map screen restores at
///   every cold start (`main.dart`'s `trip.restore()` reads it via
///   `ActiveRouteStore.load`). **M5 final review, Critical C1**: this file
///   was never purged at all, so a deleted account's destination pin and
///   route line survived on disk and were re-rendered — with a "Démarrer
///   l'itinéraire" banner — on the very next launch, even though the purge
///   reported full success. Flagged twice by an earlier task review
///   (`task-6-review.md`) and closed as "addressed" without actually being
///   fixed; this is the fix.
/// - The `.tmp` (and `trip_snapshot.json`'s extra `.ui.tmp`) write-ahead
///   siblings of the checkpoint/snapshot/route files above. **M5 final
///   review, Important I1**: each of those three stores writes its new
///   content to a `<name>.tmp` (or, for the tracking-service-isolate writer
///   of `trip_snapshot.json`, `<name>.ui.tmp`) file first and renames it
///   over the real one (`FileActiveRouteStore.save`,
///   `GameStateCheckpointStore._write`, `FileTripSnapshotStore.write`) — a
///   process death between that write and the rename leaves a FULL copy of
///   the purged content sitting under the `.tmp` name, which the
///   corresponding `_deleteIfExists` on the real filename never touches.
///   Same profile/route data, just under a different name.
/// - [clearFinalisedTripMemoryPrefs] — the two `shared_preferences` keys
///   `trip/finalised_trip_memory.dart`'s `PrefsFinalisedTripMemory` owns:
///   `finalised_trip_ids` (recently-finalised trip identities) and
///   `pending_trip_celebration` (the not-yet-shown congratulations marker,
///   carrying [PendingCelebrationStats] — distance/duration/speed/profile
///   of the last finalised trip). **M5 final review, Important I1**: this
///   invalidates the earlier "transient UI bookkeeping, not personal"
///   characterisation of that key — a later fix round attached real
///   trip-derived stats to it, and it survived every previous purge round.
/// - [PrefsSyncStateStore.deleteFor] — the deleted account's own
///   `sync_pushed_index::<uid>` / `sync_pushed_catchup_ids::<uid>` /
///   `sync_pull_cursor::<uid>` / `sync_known_skipped_lines::<uid>` prefs
///   keys, only when [uid] is non-null (the caller passes the just-deleted
///   account's uid; a purge with no account involved — e.g. a future
///   "clear my local data" entry point with nobody signed in — passes
///   `null` and simply skips this step).
///
/// **Deliberately NOT purged** (documented scope decisions, adjudicated in
/// Task 6's review — not blind spots):
/// - `total_km` (`session/recorder.dart`'s `TotalDistanceStore`) — a running
///   aggregate that feeds the anonymous `drive.lmqc.fr` leaderboard identity
///   and isn't tied to the deleted backend account; a fresh account (or no
///   account) picks up the same running total on the same device, which is
///   the intended behaviour.
/// - `PlayerIdentity` (`settings/identity.dart` — device uuid + pseudo) — a
///   device-level anonymous identity that predates and outlives any
///   signed-in backend account.
/// - `SpeedHistoryStore` (`loop/speed_history.dart` — `speed_ema_walk`/
///   `speed_ema_bike`, two `shared_preferences` doubles) — a derived pace
///   estimate with no location, no timestamps, no track; same category as
///   `total_km`, kept for the same reason (a device-level running estimate,
///   not account-tied personal data).
///
/// **Best-effort, like everything else in this game ("game-never-blocks")**:
/// each step is attempted independently — one failing (a locked file, a
/// permissions error, a corrupt sqlite file) never stops the rest from being
/// attempted. [purge] returns the labels of whichever steps failed, if any,
/// so the caller can decide whether/how to mention it (see
/// [frenchPurgeLabels]); it never throws.
class LocalDataPurge {
  const LocalDataPurge(this.appSupportDir);

  /// The same directory `main.dart`'s `_buildTripController` and
  /// `game/game_state_provider.dart`'s `gameJournalProvider` resolve via
  /// `path_provider`'s `getApplicationSupportDirectory()` — the caller
  /// resolves it once and passes it in, which is also what makes this class
  /// trivially unit-testable against a temp directory.
  final Directory appSupportDir;

  Future<List<String>> purge({String? uid}) async {
    final failures = <String>[];

    Future<void> step(String label, Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        failures.add(label);
      }
    }

    await step(
      'journal',
      () => _deleteIfExists('${appSupportDir.path}/game/game_events.jsonl'),
    );
    await step(
      'checkpoint',
      () => _deleteWithTmpSiblings(
        '${appSupportDir.path}/game/game_state_checkpoint.json',
      ),
    );
    await step('edges', () => _clearEdges());
    await step('trip-history', () => _deleteTripHistory());
    await step(
      'trip-snapshot',
      () => _deleteWithTmpSiblings(
        '${appSupportDir.path}/trip_snapshot.json',
        // `tracking_service.dart` writes this document's *other* writer
        // (the UI isolate, at trip start) through a separate `.ui.tmp`
        // scratch path — see `FileTripSnapshotStore.tmpSuffix`'s own
        // dartdoc for why the two isolates can't share one.
        extraSuffixes: const ['.ui.tmp'],
      ),
    );
    await step(
      'track',
      () => _deleteIfExists('${appSupportDir.path}/active_track.jsonl'),
    );
    // M5 final review, Critical C1: the planned route (destination + full
    // polyline) — see the class dartdoc's own bullet for why this was a
    // blind spot severe enough to resurrect a deleted account's route on
    // the very next launch.
    await step(
      'route',
      () => _deleteWithTmpSiblings('${appSupportDir.path}/active_route.json'),
    );
    // M5 final review, Important I1: the finalised-trip-ids/pending-
    // celebration prefs — see the class dartdoc's own bullet.
    await step('trip-memory', clearFinalisedTripMemoryPrefs);
    if (uid != null) {
      await step('sync-state', () => PrefsSyncStateStore.deleteFor(uid));
    }

    return failures;
  }

  /// Deletes [path] and its `.tmp` write-ahead sibling (the scratch file
  /// every `.tmp`-then-rename writer in this codebase —
  /// `FileActiveRouteStore`, `GameStateCheckpointStore`,
  /// `FileTripSnapshotStore` — leaves behind if the process dies between
  /// the write and the rename), plus any [extraSuffixes] a particular
  /// document needs beyond the plain `.tmp` one. See the class dartdoc's
  /// "M5 final review, Important I1" bullet.
  Future<void> _deleteWithTmpSiblings(
    String path, {
    List<String> extraSuffixes = const [],
  }) async {
    await _deleteIfExists(path);
    await _deleteIfExists('$path.tmp');
    for (final suffix in extraSuffixes) {
      await _deleteIfExists('$path$suffix');
    }
  }

  Future<void> _clearEdges() async {
    final store = await EdgesStore.open(
      '${appSupportDir.path}/covered_edges.db',
    );
    try {
      await store.clear();
    } finally {
      await store.close();
    }
  }

  /// See [LocalDataPurge]'s own dartdoc ("`trip_history.db`" bullet) for the
  /// full reasoning behind clearing rows before deleting the file.
  Future<void> _deleteTripHistory() async {
    final path = '${appSupportDir.path}/trip_history.db';
    final store = await TripHistoryStore.open(path);
    try {
      await store.deleteAll();
    } finally {
      await store.close();
    }
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      await _deleteIfExists('$path$suffix');
    }
  }

  Future<void> _deleteIfExists(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}

/// Persists whether the most recent local purge left some categories
/// un-purged, and which account's [uid] it was purging for (if any) — Task 6
/// review round 1, Important I2. Backs [PurgeRetryTile]'s "Réessayer la
/// suppression des données locales" entry in `Réglages`: the account is
/// already deleted and the session already signed out by the time a purge
/// runs, so there is no way back into `AccountScreen`'s own flow to retry —
/// this is the only surviving entry point.
class PurgeRetryState {
  static const _incompleteKey = 'purge_incomplete';
  static const _uidKey = 'purge_incomplete_uid';

  Future<bool> isIncomplete() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_incompleteKey) ?? false;
  }

  /// The `uid` a pending retry should pass back into [LocalDataPurge.purge]
  /// — `null` either when nothing is pending or the original purge had no
  /// account uid to begin with (both are valid "purge with `uid: null`"
  /// retries).
  Future<String?> pendingUid() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_uidKey);
  }

  Future<void> markIncomplete(String? uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_incompleteKey, true);
    if (uid == null) {
      await prefs.remove(_uidKey);
    } else {
      await prefs.setString(_uidKey, uid);
    }
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_incompleteKey);
    await prefs.remove(_uidKey);
  }
}

/// Thrown-free outcome of [runLocalPurge] — distinguishes "refused, a trip
/// is recording" from "ran, with these failures" so every call site can
/// build its own French copy without re-deriving the distinction.
class PurgeRunOutcome {
  final bool refusedTripActive;
  final List<String> failures;

  const PurgeRunOutcome({
    this.refusedTripActive = false,
    this.failures = const [],
  });
  const PurgeRunOutcome.tripActive()
    : refusedTripActive = true,
      failures = const [];

  bool get isFullSuccess => !refusedTripActive && failures.isEmpty;
}

/// Runs [LocalDataPurge.purge] for [uid] against this process's real
/// app-support directory (derived from `gameJournalProvider`, exactly like
/// `DataExporter`'s edges-count lookup — see that class's own dartdoc for
/// why: it avoids a second `path_provider` call and stays overridable via
/// the same provider tests already use), records the outcome in
/// [PurgeRetryState], and bumps [GameJournalSignal] so `gameStateProvider`
/// re-replays against whatever the purge just emptied.
///
/// **Refuses to run at all unless the trip controller is [TripState.idle]**
/// (Task 6 review round 1, Important I1; widened in review round 2):
/// `trip_snapshot.json` is live state a running foreground service tick can
/// rewrite at any moment, and deleting it out from under that service would
/// corrupt the in-progress trip. `TripState.recording` alone isn't the whole
/// story, though — round 2's re-review walked through `TripState
/// .interrupted` (a trip whose process died mid-recording, parked behind the
/// « Trajet interrompu » banner until the user resumes-and-finishes or
/// abandons it) and found it passes a recording-only guard: purge the local
/// data, then tap through to finish that interrupted trip, and
/// `TripController._finalise` → `TripHistoryRecorder.process` writes the
/// PRE-PURGE trip straight back into the just-emptied `trip_history.db` and
/// appends fresh events to the just-emptied journal — silently reintroducing
/// exactly what the purge just promised to remove. So this checks
/// [tripControllerProvider]'s `isRecording` OR `isInterrupted` — the same
/// signals every other trip-aware screen in this app already trusts —
/// rather than re-reading `trip_snapshot.json` independently, which could
/// not distinguish a genuinely live/pending trip from a stale leftover the
/// way the app's one running [TripController] instance can.
///
/// Both call sites needing this (`AccountScreen._deleteAccount`'s purge
/// offer, and [PurgeRetryTile]'s retry) share it rather than duplicating the
/// refuse-check/`PurgeRetryState` bookkeeping, and both show
/// [kPurgeRefusedTripActiveMessage] verbatim on refusal.
Future<PurgeRunOutcome> runLocalPurge(WidgetRef ref, {String? uid}) async {
  final trip = ref.read(tripControllerProvider);
  if (trip.isRecording || trip.isInterrupted) {
    return const PurgeRunOutcome.tripActive();
  }
  final journal = await ref.read(gameJournalProvider.future);
  final failures = await LocalDataPurge(journal.dir.parent).purge(uid: uid);
  GameJournalSignal.instance.bump();

  final retryState = PurgeRetryState();
  if (failures.isEmpty) {
    await retryState.clear();
  } else {
    await retryState.markIncomplete(uid);
  }
  return PurgeRunOutcome(failures: failures);
}

/// `Réglages` entry point for retrying an incomplete local purge (Task 6
/// review round 1, Important I2) — invisible ([SizedBox.shrink]) unless
/// [PurgeRetryState.isIncomplete] says a previous purge left something
/// un-purged. Retries ONLY the purge: the account itself is already deleted
/// and the session already signed out by the time this can ever show, so
/// there is nothing else left to redo.
class PurgeRetryTile extends ConsumerStatefulWidget {
  const PurgeRetryTile({super.key});

  @override
  ConsumerState<PurgeRetryTile> createState() => _PurgeRetryTileState();
}

class _PurgeRetryTileState extends ConsumerState<PurgeRetryTile> {
  final _retryState = PurgeRetryState();

  /// `null` while the initial [PurgeRetryState.isIncomplete] read is still
  /// in flight (renders as invisible, same as a settled `false`, so there is
  /// no visible "flash" either way).
  ///
  /// Deliberately plain state, not a `FutureBuilder` over a re-assignable
  /// `Future<bool>` field: `FutureBuilder`'s `AsyncSnapshot` KEEPS the
  /// previous build's `data` while a newly-assigned future is still
  /// `ConnectionState.waiting` (Flutter's own documented "avoid flashing
  /// back to nothing while refreshing" behaviour) — which meant a
  /// successful retry's `setState` swapping in a fresh, not-yet-resolved
  /// future left this tile rendering the STALE `true` from before the
  /// retry, right up until — and only exactly when — that fresh future's
  /// own completion callback happened to fire a further rebuild. Loading
  /// the value directly into a field and `setState`-ing once it resolves
  /// makes "hidden the instant the retry knows the answer" the only
  /// possible rendering, with no intermediate stale frame to race.
  bool? _incomplete;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadIncomplete();
  }

  Future<void> _loadIncomplete() async {
    final incomplete = await _retryState.isIncomplete();
    if (mounted) setState(() => _incomplete = incomplete);
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    final uid = await _retryState.pendingUid();
    final outcome = await runLocalPurge(ref, uid: uid);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(_messageFor(outcome))));
    final incomplete = await _retryState.isIncomplete();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _incomplete = incomplete;
    });
  }

  String _messageFor(PurgeRunOutcome outcome) {
    if (outcome.refusedTripActive) {
      return kPurgeRefusedTripActiveMessage;
    }
    if (outcome.isFullSuccess) return 'Données locales supprimées.';
    return "Certaines données locales n'ont pas pu être supprimées : "
        '${frenchPurgeLabels(outcome.failures)}.';
  }

  @override
  Widget build(BuildContext context) {
    if (_incomplete != true) return const SizedBox.shrink();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.replay_outlined),
      title: const Text('Réessayer la suppression des données locales'),
      subtitle: const Text(
        "La dernière suppression n'a pas pu retirer toutes les données.",
      ),
      trailing: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onTap: _busy ? null : _retry,
    );
  }
}
