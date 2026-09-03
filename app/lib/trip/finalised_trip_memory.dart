import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../valhalla/models.dart';

/// Task 2g fix round 1 (Important 5): the synchronously-known stats
/// `TripController._finalise` builds for a celebration-worthy trip,
/// persisted alongside [FinalisedTripMemory.setPendingCelebration]'s marker
/// so the DEFERRED path (nothing was watching live when the trip finalised)
/// can render distance/durée/vitesse immediately too, exactly like the live
/// path's `FinishedTripCelebration` — only the combined XP figure still
/// needs `TripHistoryStore`'s own poll, on both paths equally. Before this,
/// the deferred path pushed `celebration: null` and relied entirely on that
/// poll for every stat, so a timeout left the screen with nothing to show
/// at all — the exact scenario this task's flagship background-arrival case
/// hits hardest.
class PendingCelebrationStats {
  final double distanceKm;
  final Duration duration;
  final double avgSpeedKmh;
  final RoutingProfile profile;
  final bool isLoop;

  const PendingCelebrationStats({
    required this.distanceKm,
    required this.duration,
    required this.avgSpeedKmh,
    required this.profile,
    required this.isLoop,
  });

  Map<String, dynamic> toJson() => {
    'distanceKm': distanceKm,
    'durationMs': duration.inMilliseconds,
    'avgSpeedKmh': avgSpeedKmh,
    'profile': profile.name,
    'isLoop': isLoop,
  };

  /// Parses one value back, or `null` for anything corrupt/missing — a
  /// broken persisted payload must degrade to "nothing pending" (the same
  /// as no marker at all), never crash the startup check that reads it.
  static PendingCelebrationStats? tryParse(Object? json) {
    if (json is! Map) return null;
    try {
      return PendingCelebrationStats(
        distanceKm: (json['distanceKm'] as num).toDouble(),
        duration: Duration(milliseconds: (json['durationMs'] as num).toInt()),
        avgSpeedKmh: (json['avgSpeedKmh'] as num).toDouble(),
        profile: RoutingProfile.values.firstWhere(
          (p) => p.name == json['profile'],
          orElse: () => RoutingProfile.walk,
        ),
        isLoop: json['isLoop'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }
}

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
  /// yet, plus [stats] (fix round 1, Important 5 — see
  /// [PendingCelebrationStats]'s own doc comment), so both survive a cold
  /// start.
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
  Future<void> setPendingCelebration(
    DateTime startedAt,
    PendingCelebrationStats stats,
  );

  /// The pending celebration's trip identity and stats, or `null` if there
  /// is none (including when the persisted payload is corrupt — see
  /// [PendingCelebrationStats.tryParse]).
  Future<(DateTime, PendingCelebrationStats)?> pendingCelebration();

  Future<void> clearPendingCelebration();
}

class PrefsFinalisedTripMemory implements FinalisedTripMemory {
  static const _key = 'finalised_trip_ids';

  /// Task 2g: see [FinalisedTripMemory.setPendingCelebration]. One combined
  /// JSON blob (identity + stats) rather than two keys, so a read can never
  /// observe one half written without the other.
  static const _pendingCelebrationKey = 'pending_trip_celebration';

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
  Future<void> setPendingCelebration(
    DateTime startedAt,
    PendingCelebrationStats stats,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _pendingCelebrationKey,
      jsonEncode({'startedAt': _id(startedAt), 'stats': stats.toJson()}),
    );
  }

  @override
  Future<(DateTime, PendingCelebrationStats)?> pendingCelebration() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingCelebrationKey);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final startedAt = DateTime.parse(json['startedAt'] as String);
      final stats = PendingCelebrationStats.tryParse(json['stats']);
      if (stats == null) {
        // M5 final review, Important I1: a corrupt `stats` sub-payload used
        // to return null WITHOUT removing the key, so `_checkPendingCelebration`
        // (`main.dart`) early-returns on `null` and never calls
        // `clearPendingCelebration()` — the marker then survives forever,
        // including through a local purge that specifically targets it (see
        // `LocalDataPurge`'s "trip-memory" step). Since a corrupt value is
        // already treated as "nothing pending" one line below, it must also
        // be treated as "nothing left to clear later" — remove it here,
        // exactly like the `catch` block just below does for a payload that
        // doesn't even parse as JSON.
        await prefs.remove(_pendingCelebrationKey);
        return null;
      }
      return (startedAt, stats);
      // A corrupt value is exactly "nothing pending" — never worth crashing
      // the map screen's startup check over.
    } catch (_) {
      await prefs.remove(_pendingCelebrationKey);
      return null;
    }
  }

  @override
  Future<void> clearPendingCelebration() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingCelebrationKey);
  }
}

/// M5 final review, fix wave F1 (folds Important I1 in with Critical C1):
/// removes both of [PrefsFinalisedTripMemory]'s `shared_preferences` keys —
/// `finalised_trip_ids` (the last few finalised trip identities, used to
/// reject a stale "Trajet interrompu" resurrection) and
/// `pending_trip_celebration` (the not-yet-shown congratulations marker,
/// carrying [PendingCelebrationStats] — real trip-derived personal data,
/// see that class's own dartdoc). [LocalDataPurge] calls this the same way
/// it calls [PrefsSyncStateStore.deleteFor] for the sync-state keys: a
/// static helper next to the storage it clears, rather than local_purge.dart
/// reaching into `shared_preferences` key names it doesn't own.
Future<void> clearFinalisedTripMemoryPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(PrefsFinalisedTripMemory._key);
  await prefs.remove(PrefsFinalisedTripMemory._pendingCelebrationKey);
}
