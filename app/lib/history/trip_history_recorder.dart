import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../exploration/exploration_recorder.dart' show FinishedTrip;
import '../exploration/track_sampler.dart';
import '../game/events.dart';
import '../game/reducers.dart';
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
/// simple"): [GameState] read before and after [inner] runs. [inner] is
/// exactly the call that appends this trip's own `xp_earned` events (km,
/// newly-revealed cells, loop bonus — see `ExplorationRecorder._run`), so
/// the XP delta across that one call is this trip's XP, with no need to tag
/// or filter individual journal entries by type. Read failures (a corrupt
/// or momentarily-unreadable journal) make the recorded [TripHistoryEntry.
/// xpEarned] `null` rather than a wrong number — see [_xp].
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
  final GameJournal journal;

  /// Same file `tracking_service.dart`'s `TripTaskHandler` appends the live
  /// trip's sampled points to, and the same file [inner] (the real
  /// `ExplorationRecorder`) reads and then deletes. This class reads it
  /// *first*, without deleting — see [_peekTrack] — so [inner]'s own read
  /// afterwards sees exactly what it always has; the ordering in [process]
  /// (peek, then run [inner]) is what makes that safe rather than a race.
  final File trackFile;

  final Future<void> Function(FinishedTrip trip) inner;

  TripHistoryRecorder({
    required this.store,
    required this.journal,
    required this.trackFile,
    required this.inner,
  });

  /// Never throws: every step is independently best-effort (see [_peekTrack]
  /// and [_xp]), and the final [TripHistoryStore.record] call — the only
  /// step that could still throw (a full disk, a wedged sqlite handle) — is
  /// itself wrapped, so a broken history store costs this trip its history
  /// row, never its exploration processing (brief §4: "échec d'écriture
  /// silencieux").
  Future<void> process(FinishedTrip trip) async {
    final track = await _peekTrack();
    final xpBefore = await _xp();

    await inner(trip);

    try {
      final xpAfter = await _xp();
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
          xpEarned: (xpBefore == null || xpAfter == null)
              ? null
              : (xpAfter - xpBefore).toDouble(),
          track: track,
        ),
      );
    } catch (e) {
      debugPrint('TripHistoryRecorder: failed to record trip, continuing: $e');
    }
  }

  /// Current cumulative XP, or `null` when the journal could not be read —
  /// `GameJournal.readAll` itself is documented to never throw (a
  /// missing/corrupt journal reads as `[]`/skips bad lines), so this catch
  /// is a second, independent guard for whatever reaches it regardless
  /// (e.g. `reduceAll` itself), matching the "never let this cost the trip
  /// its history row" contract [process] promises.
  Future<int?> _xp() async {
    try {
      return reduceAll(await journal.readAll()).xp;
    } catch (_) {
      return null;
    }
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
