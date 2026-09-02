import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../exploration/exploration_recorder.dart' show FinishedTrip;
import '../exploration/track_sampler.dart';
import '../game/events.dart';
import '../valhalla/models.dart';
import 'trip_history_store.dart';

/// Wraps [inner] (in production, `ExplorationRecorder.process`) to also
/// write a per-trip [TripHistoryEntry] to [store] once it finishes — Task
/// 2f, owner-requested: « ce serait bien d'ajouter les anciens trajets
/// comme historique ».
///
/// **Why a decorator, not a new `TripController` dependency**:
/// `TripController._finalise` already fires exactly one
/// `processTripExploration(trip)` call per finished trip, fire-and-forget —
/// never awaited, so it can never delay or block finalisation (brief §3:
/// "l'écriture du résumé ne bloque JAMAIS la finalisation"). `FinishedTrip`
/// carries everything a summary needs once Task 2f's three extra fields
/// ([FinishedTrip.startedAt]/[endedAt]/[profile]) are populated (see that
/// class's own doc comment), so wrapping the existing hook in `main.dart`
/// gets this feature for free without `trip_controller.dart` or
/// `exploration_recorder.dart` ever needing to know a history store exists.
///
/// **XP source** (brief: "les événements du journal sur la fenêtre du
/// trajet, ou le GameState avant/après — choisir la source la plus
/// simple"): the `xp_earned` events [inner] itself returns from *this call*
/// (see [ExplorationRecorder.process]'s return value).
///
/// **Review fix round 1 (Critical 1)**: the first version of this class
/// instead read `GameState.xp` before and after [inner] ran and stored the
/// difference. That is unsafe in this codebase specifically:
/// `TripController._finalise` fires `processTripExploration` *and* the
/// post-trip auto-sync trigger unawaited from the same call
/// (`main.dart`'s `_onSessionEnded` → `runAutoSync`), so `SyncEngine.sync()`
/// can merge remote `xp_earned` events into the very same `GameJournal` in
/// the window between the two reads — polluting this trip's recorded XP
/// with XP that has nothing to do with it (`sync_engine.dart`'s own doc
/// comment: "the journal is not exclusively this engine's to write").
/// Summing the events [inner] *returns* rather than re-reading the journal
/// sidesteps that race by construction: whatever anyone else appends
/// concurrently is simply never consulted.
///
/// **Timing**: the history row (including XP) is written only after
/// [inner] finishes, since XP genuinely is not known before then — the same
/// fire-and-forget timing tier the exploration pipeline's own game-state
/// updates already have (cells/badges/streak are not final until this same
/// call resolves either). On real hardware this is consistently sub-second
/// (on-device, offline, no network involved). See `task-2f-report.md` for
/// what this means for Task 2g's congratulations screen.
class TripHistoryRecorder {
  final TripHistoryStore store;

  /// Same file `tracking_service.dart`'s `TripTaskHandler` appends the live
  /// trip's sampled points to, and the same file [inner] (the real
  /// `ExplorationRecorder`) reads and then deletes. This class reads it
  /// *first*, without deleting — see [_peekTrack] — so [inner]'s own read
  /// afterwards sees exactly what it always has; the ordering in [process]
  /// (peek, then run [inner]) is what makes that safe rather than a race.
  final File trackFile;

  /// In production, `ExplorationRecorder.process` — returns exactly the
  /// events that one call appended to the game journal (`const []` if
  /// nothing durably landed), which is what makes [process] immune to a
  /// concurrent journal writer (see this class's own doc comment).
  final Future<List<GameEvent>> Function(FinishedTrip trip) inner;

  TripHistoryRecorder({
    required this.store,
    required this.trackFile,
    required this.inner,
  });

  /// Never throws: every step is independently best-effort (see
  /// [_peekTrack] and [_xpFrom]), and the final [TripHistoryStore.record]
  /// call — the only step that could still throw (a full disk, a wedged
  /// sqlite handle) — is itself wrapped, so a broken history store costs
  /// this trip its history row, never its exploration processing (brief
  /// §4: "échec d'écriture silencieux").
  Future<void> process(FinishedTrip trip) async {
    final track = await _peekTrack();

    final appended = await inner(trip);

    try {
      // `TripController._finalise` (the only production caller) always
      // supplies both timestamps; the fallbacks below only matter for a
      // hand-built `FinishedTrip` (e.g. a test) that omits them.
      final startedAt = trip.startedAt ?? trip.endedAt ?? DateTime.now();
      final endedAt = trip.endedAt ?? startedAt;
      final rawDuration = endedAt.difference(startedAt);
      // A clock skew between the two timestamps must never produce a
      // negative duration/speed in the stored summary.
      final duration = rawDuration.isNegative ? Duration.zero : rawDuration;
      final hours = duration.inMilliseconds / Duration.millisecondsPerHour;
      await store.record(
        TripHistoryEntry(
          startedAt: startedAt,
          endedAt: endedAt,
          profile: trip.profile ?? RoutingProfile.walk,
          distanceKm: trip.km,
          duration: duration,
          avgSpeedKmh: hours > 0 ? trip.km / hours : 0,
          xpEarned: _xpFrom(appended),
          track: track,
        ),
      );
    } catch (e) {
      debugPrint('TripHistoryRecorder: failed to record trip, continuing: $e');
    }
  }

  /// Sums the `xp_earned` amounts among the events [inner] itself appended
  /// for this trip, or `null` when [appended] is empty — which only happens
  /// when [inner] failed before durably committing anything (see
  /// `ExplorationRecorder.process`'s doc comment), since on any successful
  /// run it always appends at least a km-based `xp_earned` event, even for
  /// a zero-distance trip. `null` therefore cleanly means "unknown", never
  /// a wrong number — it is never conflated with a real zero.
  ///
  /// Deliberately the raw `amount` payload, not the energy-multiplied value
  /// the reducer would eventually bank (`reducers.dart`'s private
  /// `_energyMultiplier`, out of scope for this class to depend on): this
  /// is "what this trip itself earned," an intrinsic property of the trip,
  /// rather than "what it happened to bank," which depends on the player's
  /// energy level at whatever moment the reducer runs — a quantity this
  /// class has no race-free way to pin down anyway (see this class's own
  /// doc comment on why a `GameState` read was dropped entirely).
  double? _xpFrom(List<GameEvent> appended) {
    if (appended.isEmpty) return null;
    var total = 0.0;
    for (final event in appended) {
      if (event.type != GameEventTypes.xpEarned) continue;
      total += (event.payload['amount'] as num?)?.toDouble() ?? 0;
    }
    return total;
  }

  /// Reads [trackFile] as newline-delimited `{"lat":.., "lon":..}` objects
  /// WITHOUT deleting it — mirrors `ExplorationRecorder._readAndClearTrack`'s
  /// tolerant parsing (a missing file, an unreadable one, or a corrupt line
  /// all degrade gracefully) but leaves the file itself untouched for
  /// [inner]'s own read to consume and clear as it always has. Folded
  /// through a [TrackSampler] the same way, so the persisted track never
  /// exceeds `kTrackMaxPoints` regardless of how large the on-disk file
  /// happens to be (brief: "borne de taille par trajet").
  Future<List<(double, double)>> _peekTrack() async {
    try {
      if (!await trackFile.exists()) return const [];
      final lines = await trackFile.readAsLines();
      final sampler = TrackSampler();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final j = jsonDecode(line) as Map<String, dynamic>;
          sampler.seed(
            (j['lat'] as num).toDouble(),
            (j['lon'] as num).toDouble(),
          );
        } catch (_) {
          // One corrupt line costs one point, not the whole track.
        }
      }
      return sampler.points;
    } catch (_) {
      return const [];
    }
  }
}
