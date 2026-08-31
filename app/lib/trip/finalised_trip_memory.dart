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
}

class PrefsFinalisedTripMemory implements FinalisedTripMemory {
  static const _key = 'finalised_trip_ids';

  /// How many ids to keep. One is enough for the race this guards against —
  /// only the trip that was just stopped can be resurrected — but a short
  /// history costs nothing and survives a couple of trips being finalised in
  /// quick succession (stop, then « Terminer » on an older banner).
  static const _maxRemembered = 5;

  @override
  Future<bool> wasFinalised(DateTime startedAt) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? const [])
        .contains(_id(startedAt));
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

  static String _id(DateTime startedAt) =>
      startedAt.toUtc().toIso8601String();
}
