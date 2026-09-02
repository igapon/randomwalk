import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which trips have already been banked and submitted.
///
/// Exists because of an ordering hazard that no amount of care inside a
/// single process removes: `FlutterForegroundTask.stopService()` returns
/// before the service isolate's `onDestroy` has necessarily flushed its last
/// snapshot, so that final write can land *after* the UI has cleared the
/// snapshot file. The document then reappears with `status: recording` for a
/// trip whose kilometres are already in the total and already on the
/// leaderboard — and the next cold start would offer « Trajet interrompu »
/// for it, letting « Terminer » bank the same distance a second time.
///
/// Guarding on the trip's identity rather than trying to win the race makes
/// the outcome the same whichever order the two writes happen in. A trip's
/// identity is its start time: it is stable across resumes (see
/// `TripController.resumeInterrupted`, which deliberately keeps the original
/// `startedAt`) and unique in practice, since two trips cannot start in the
/// same millisecond.
abstract class FinalisedTripMemory {
  Future<bool> wasFinalised(DateTime startedAt);
  Future<void> markFinalised(DateTime startedAt);

  /// Task 2g (owner brief): remembers the identity ([startedAt] — see this
  /// class's own doc comment on why that is a trip's identity) of the most
  /// recently finalised trip whose congratulations screen has not been shown
  /// yet, so it survives a cold start.
  ///
  /// Set by `TripController._finalise` for exactly the trips the brief wants
  /// a celebration for — a guided (route-bound) trip that had latched
  /// arrival, whether it ended via the Task 2g auto-finish or a manual
  /// « Terminer » on an already-arrived trip — including from `restore()`'s
  /// own reconciliation of a trip that auto-finished while nothing was
  /// attached (backgrounded, or the whole app process killed: the foreground
  /// service survives both, see `tracking_service.dart`'s `stopWithTask:
  /// false`). That reconciliation path is the whole reason this exists as
  /// *persisted* state rather than a plain in-memory field on
  /// `TripController`: an in-memory value cannot survive the cold start it
  /// is specifically for.
  ///
  /// A single slot, not a list: only one trip can ever be recording at a
  /// time, so at most one congratulations screen can ever be pending.
  /// [clearPendingCelebration] is called once the screen has actually been
  /// shown.
  Future<void> setPendingCelebration(DateTime startedAt);

  /// The pending celebration's trip identity, or `null` if there is none.
  Future<DateTime?> pendingCelebration();

  Future<void> clearPendingCelebration();
}

class PrefsFinalisedTripMemory implements FinalisedTripMemory {
  static const _key = 'finalised_trip_ids';

  /// Task 2g: see [FinalisedTripMemory.setPendingCelebration].
  static const _pendingCelebrationKey = 'pending_trip_celebration_started_at';

  /// How many ids to keep. One is enough for the race this guards against —
  /// only the trip that was just stopped can be resurrected — but a short
  /// history costs nothing and survives a couple of trips being finalised in
  /// quick succession (stop, then « Terminer » on an older banner).
  static const _maxRemembered = 5;

  @override
  Future<bool> wasFinalised(DateTime startedAt) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? const []).contains(_id(startedAt));
  }

  @override
  Future<void> markFinalised(DateTime startedAt) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = [
      ...(prefs.getStringList(_key) ?? const <String>[]),
      _id(startedAt),
    ];
    await prefs.setStringList(
      _key,
      ids.length <= _maxRemembered
          ? ids
          : ids.sublist(ids.length - _maxRemembered),
    );
  }

  static String _id(DateTime startedAt) => startedAt.toUtc().toIso8601String();

  @override
  Future<void> setPendingCelebration(DateTime startedAt) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingCelebrationKey, _id(startedAt));
  }

  @override
  Future<DateTime?> pendingCelebration() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingCelebrationKey);
    if (raw == null) return null;
    try {
      return DateTime.parse(raw);
    } catch (_) {
      // A corrupt value is exactly "nothing pending" — never worth crashing
      // the map screen's startup check over.
      return null;
    }
  }

  @override
  Future<void> clearPendingCelebration() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingCelebrationKey);
  }
}
