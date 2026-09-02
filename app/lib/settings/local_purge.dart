import 'dart:io';

import '../exploration/edges_store.dart';
import '../sync/sync_state_store.dart';

/// Deletes every piece of LOCAL game data this device holds: the game
/// journal, its periodic checkpoint, the covered-edges store, and any
/// leftover in-progress track file — plus, when [uid] is given, that
/// account's own sync checkpoint keys.
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
/// - `game/game_state_checkpoint.json` — a periodic snapshot of the exact
///   same profile data, persisted *independently* of the journal
///   (`GameStateCheckpointStore`, `game/state_checkpoint.dart` — see its own
///   dartdoc, flagged by Task 5 review I4: "any local purge ... MUST delete
///   this file alongside the journal, or a deleted account's data survives
///   in it").
/// - `covered_edges.db` — the covered-OSM-way-id store (`EdgesStore`,
///   `exploration/edges_store.dart`). Cleared via [EdgesStore.clear]
///   (`DELETE FROM covered_edges`) rather than deleting the file outright —
///   see that method's own dartdoc for why: `main.dart`'s `TripController`
///   keeps its own `EdgesStore` handle open for the app's entire lifetime,
///   and `sqflite` reference-counts one native connection per path, so
///   clearing the table reuses that same connection instead of risking a
///   stale file descriptor.
/// - `active_track.jsonl` — the in-progress GPS track file
///   (`tracking/tracking_service.dart`, `exploration/exploration_recorder
///   .dart`). Normally deleted by the trip-processing pipeline itself once a
///   trip finishes; only ever present here as a leftover from a
///   trip in progress or one that crashed mid-processing, but included for
///   completeness ("reveal/track" data per `task-6-brief.md`).
/// - [PrefsSyncStateStore.deleteFor] — the deleted account's own
///   `sync_pushed_index::<uid>` / `sync_pushed_catchup_ids::<uid>` /
///   `sync_pull_cursor::<uid>` / `sync_known_skipped_lines::<uid>` prefs
///   keys, only when [uid] is non-null (the caller passes the just-deleted
///   account's uid; a purge with no account involved — e.g. a future
///   "clear my local data" entry point with nobody signed in — passes
///   `null` and simply skips this step).
///
/// **Deliberately NOT purged** (out of this task's explicit scope, flagged
/// in `task-6-report.md`'s concerns for a future reviewer): `total_km`
/// (`session/recorder.dart`'s `TotalDistanceStore`) and the device's
/// `PlayerIdentity` (`settings/identity.dart` — uuid + pseudo). Neither is
/// tied to the backend account being deleted: `PlayerIdentity` is a
/// device identity that predates and outlives any signed-in account, and
/// `TotalDistanceStore`'s running total is what continues to feed the
/// leaderboard submission for whatever account (or none) plays next on this
/// device.
///
/// **Best-effort, like everything else in this game ("game-never-blocks")**:
/// each of the five steps above is attempted independently — one failing
/// (a locked file, a permissions error, a corrupt sqlite file) never stops
/// the rest from being attempted. [purge] returns the labels of whichever
/// steps failed, if any, so the caller can decide whether/how to mention it;
/// it never throws.
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
      () => _deleteIfExists(
        '${appSupportDir.path}/game/game_state_checkpoint.json',
      ),
    );
    await step('edges', () => _clearEdges());
    await step(
      'track',
      () => _deleteIfExists('${appSupportDir.path}/active_track.jsonl'),
    );
    if (uid != null) {
      await step('sync-state', () => PrefsSyncStateStore.deleteFor(uid));
    }

    return failures;
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

  Future<void> _deleteIfExists(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}
