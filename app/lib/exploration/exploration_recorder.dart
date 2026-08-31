import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:uuid/uuid.dart';

import '../game/events.dart';
import '../game/grid.dart';
import '../game/reducers.dart';
import '../valhalla/engine.dart';
import 'edges_store.dart';
import 'matcher.dart';

/// XP awarded per kilometer of a finished trip's own distance (Global
/// Constraints §Économie: "+10/km"). Applied to [FinishedTrip.km], not to
/// however much of that distance the map-matcher could confirm — matching
/// can legitimately fail or under-cover a trip (poor GPS, missing tiles)
/// and none of that should cost the walker XP for ground actually covered.
const kXpPerKm = 10;

/// XP per newly-revealed grid cell (Global Constraints: "+5/cellule
/// révélée").
const kXpPerNewCell = 5;

/// XP for completing a planned loop (Global Constraints: "+50/boucle
/// terminée").
const kXpPerLoop = 50;

/// Energy spent per kilometer walked/ridden in Adventure mode (Global
/// Constraints: "−4/km en aventure").
const kEnergyPerKm = -4.0;

/// Fraction of a quartier's cells that must be revealed to unlock the
/// `quartier_25` badge (Global Constraints: "25 % d'un « quartier »").
const kQuartierBadgeThreshold = 0.25;

/// One finished trip's exploration-relevant facts, as [TripController]
/// (the only caller) knows them once a trip has stopped and been banked.
class FinishedTrip {
  /// This trip's own distance, in kilometers — NOT the lifetime cumulative
  /// total (`edge_covered_batch.km` is the total distance *of this trip*,
  /// per the Task 1 payload contract).
  final double km;

  /// Whether this trip followed a planned loop (`ActiveRoute.isLoop`).
  final bool isLoop;

  /// Whether turn-by-turn guidance considered the walker arrived
  /// (`TripSnapshot.navArrived`). Only meaningful together with [isLoop]:
  /// `loop_completed` needs both.
  final bool navArrived;

  const FinishedTrip({
    required this.km,
    this.isLoop = false,
    this.navArrived = false,
  });
}

/// Best-effort post-trip pipeline: map-matches a trip's raw GPS track onto
/// the road network, records newly-covered OSM ways, reveals the grid cells
/// the trip's corridor touches, and journals every economy consequence of
/// that (XP, the loop bonus, the energy drain, and the `quartier_25` badge).
///
/// Every step here can fail independently — no tiles for the area yet, a
/// trace the engine cannot match, a corrupt/missing track file, a wedged
/// journal write — and [process] never lets any of it escape. Per the
/// plan's "le jeu ne bloque jamais l'outil", this whole pipeline runs
/// entirely downstream of a trip that has *already* been finalised (see
/// `TripController._finalise`'s fire-and-forget call), so nothing it does
/// can be "too late" to affect the trip itself — only too late to affect
/// this run's game credit, which the next trip's own processing is
/// unaffected by.
class ExplorationRecorder {
  /// Builds (and initializes) a [RoutingEngine] ready for [matchTrace], or
  /// `null` when one cannot be built (no tile directory resolved yet, or the
  /// engine failed to initialize). The caller treats a `null` engine exactly
  /// like a failed match: matching is skipped, but everything else
  /// (`edge_covered_batch`, cell reveal, XP, energy) still proceeds from the
  /// raw GPS track alone.
  final Future<RoutingEngine?> Function() engineProvider;

  final EdgesStore edgesStore;
  final GameJournal journal;

  /// Where `tracking_service.dart`'s `TripTaskHandler` appends this trip's
  /// sampled `(lat, lon)` points, one JSON object per line. Read once here
  /// and then deleted (best-effort) — see [_readAndClearTrack] — since the
  /// file names *the* currently-finishing trip's track, not a history of
  /// every trip.
  final File trackFile;

  final String Function() _newId;
  final DateTime Function() _clock;

  ExplorationRecorder({
    required this.engineProvider,
    required this.edgesStore,
    required this.journal,
    required this.trackFile,
    String Function()? newId,
    DateTime Function()? clock,
  })  : _newId = newId ?? (() => const Uuid().v4()),
        _clock = clock ?? DateTime.now;

  /// Processes one finished trip. Never throws — any failure anywhere in
  /// the pipeline is logged and swallowed here, on top of every individual
  /// step already guarding itself (see the per-step doc comments below), so
  /// this is a deliberate belt-and-braces final backstop rather than the
  /// only thing standing between a bug here and a broken trip flow.
  Future<void> process(FinishedTrip trip) async {
    try {
      await _run(trip);
    } catch (e) {
      debugPrint('ExplorationRecorder: failed, continuing: $e');
    }
  }

  /// Emits this trip's events in the Task 1 contract's required order:
  /// `edge_covered_batch`, then `cell_revealed` (if any new cells) and a
  /// `quartier_25` `badge_unlocked` (if crossed), then one `xp_earned` per
  /// source (km, cells, loop — each `preMultiplied: false`), then
  /// `loop_completed` (if applicable), then finally `energy_changed` — the
  /// trip's XP must be appended before its energy drain so the energy
  /// multiplier reflects what the walker had going in, not what is left
  /// after paying for the trip.
  Future<void> _run(FinishedTrip trip) async {
    final now = _clock();
    final shape = await _readAndClearTrack();
    final events = <GameEvent>[
      _event(GameEventTypes.edgeCoveredBatch, {'km': trip.km}, now),
    ];

    final newCells = await _revealCorridor(shape, now, events);

    events.add(_event(GameEventTypes.xpEarned,
        {'amount': kXpPerKm * trip.km, 'preMultiplied': false}, now));
    if (newCells > 0) {
      events.add(_event(
          GameEventTypes.xpEarned,
          {'amount': kXpPerNewCell * newCells, 'preMultiplied': false},
          now));
    }
    final loopCompleted = trip.isLoop && trip.navArrived;
    if (loopCompleted) {
      events.add(_event(GameEventTypes.xpEarned,
          {'amount': kXpPerLoop, 'preMultiplied': false}, now));
      events.add(_event(GameEventTypes.loopCompleted, const {}, now));
    }

    events.add(_event(
        GameEventTypes.energyChanged, {'delta': kEnergyPerKm * trip.km}, now));

    await journal.appendAll(events);
  }

  /// Map-matches [shape] (best-effort — see [engineProvider]'s doc comment)
  /// and, regardless of whether that succeeded, reveals the corridor around
  /// the RAW GPS shape: matching only narrows which OSM ways get credit in
  /// [edgesStore], it does not hand back geometry of its own, so fog reveal
  /// always works from the shape actually walked rather than depending on a
  /// successful match. Appends `cell_revealed` and — if some quartier
  /// crosses the 25% threshold for the first time — a `badge_unlocked` event
  /// into [events]. Returns the number of newly-revealed cells, for [_run]'s
  /// XP calculation.
  Future<int> _revealCorridor(
    List<(double, double)> shape,
    DateTime now,
    List<GameEvent> events,
  ) async {
    if (shape.length < kMinTraceShapePoints) return 0;

    await _tryMatchAndStore(shape, now);

    final corridor = corridorCells(shape);
    if (corridor.isEmpty) return 0;

    final state = reduceAll(await journal.readAll());
    final revealedIds = <CellId>{
      for (final key in state.revealedCellKeys)
        if (CellId.parseKey(key) case final parsed?) parsed,
    };
    final newCells = corridor.difference(revealedIds);
    if (newCells.isEmpty) return 0;

    events.add(_event(
        GameEventTypes.cellRevealed,
        {'cells': [for (final c in newCells) c.key]},
        now));

    if (!state.badges.contains(GameBadges.quartier25)) {
      final revealedAfter = {...revealedIds, ...newCells};
      final crossed = newCells.any((c) =>
          quartierCompletion(c, revealedAfter) >= kQuartierBadgeThreshold);
      if (crossed) {
        events.add(_event(GameEventTypes.badgeUnlocked,
            {'badge': GameBadges.quartier25}, now));
      }
    }

    return newCells.length;
  }

  /// Best-effort: a failure anywhere in map-matching or persisting the
  /// matched way ids costs this trip its edge/way credit, never its fog
  /// reveal or economy events (see [_revealCorridor]'s doc comment).
  Future<void> _tryMatchAndStore(
      List<(double, double)> shape, DateTime now) async {
    try {
      final engine = await engineProvider();
      if (engine == null) return;
      final match = await matchTrace(engine, shape);
      if (match == null || match.wayIds.isEmpty) return;
      await edgesStore.upsertAll(match.wayIds, now);
    } catch (_) {
      // Matching/storing edges is a bonus on top of fog reveal, never a
      // prerequisite for it.
    }
  }

  /// Reads [trackFile] as newline-delimited `{"lat":.., "lon":..}` objects,
  /// then deletes it (best-effort either way) — the file names *the*
  /// currently-finishing trip, so once read it must not bleed into the next
  /// one. A missing file, an unreadable one, or one containing corrupt lines
  /// all degrade gracefully: missing/unreadable yields no points at all, and
  /// a corrupt line costs only that one point rather than the whole track.
  Future<List<(double, double)>> _readAndClearTrack() async {
    try {
      if (!await trackFile.exists()) return const [];
      final lines = await trackFile.readAsLines();
      final points = <(double, double)>[];
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final j = jsonDecode(line) as Map<String, dynamic>;
          points.add(
              ((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()));
        } catch (_) {
          // One corrupt line costs one point, not the whole track.
        }
      }
      return points;
    } catch (_) {
      return const [];
    } finally {
      try {
        if (await trackFile.exists()) await trackFile.delete();
      } catch (_) {
        // Best-effort cleanup; nothing here is worth surfacing.
      }
    }
  }

  GameEvent _event(String type, Map<String, dynamic> payload, DateTime ts) =>
      GameEvent(id: _newId(), ts: ts, type: type, payload: payload);
}
