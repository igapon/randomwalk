/// Directional bias for the « Explorer » planning mode (Task 7): scores a
/// handful of compass sectors around a would-be loop by how unexplored each
/// one looks, and hands back the best few as bearings `LoopPlanner` can seed
/// its candidates' `startBearingDeg` with (see `LoopRequest.preferredBearingsDeg`).
///
/// Deliberately kept separate from `LoopPlanner` itself: the planner stays
/// pure/ignorant of the game (no `Set<CellId>`, no grid import) and this file
/// stays pure/ignorant of routing (no `RouteResult`, no router) — the two
/// meet only through the plain `List<double>` `LoopPlanner` already accepts.
/// This file is Flutter- and async-free, same as `loop/geo_offsets.dart` and
/// `game/grid.dart`, which it builds directly on.
library;

import 'dart:math' as math;

import '../game/grid.dart';
import '../loop/geo_offsets.dart';

/// Distance, in meters, between consecutive samples along a sector's center
/// line — matches the grid's own cell size (`cellSizeM` in `game/grid.dart`),
/// so consecutive samples land in distinct cells rather than double-counting
/// one.
const double _sampleStepM = 150.0;

/// Scores `sectors` compass directions around ([start]'s) would-be loop by
/// how unexplored each looks, and returns the best `count` sector centers as
/// bearings (degrees, 0-360) — biased toward `revealedCellKeys`'s complement.
///
/// **Scoring**: sector `i`'s center bearing is `i * (360 / sectors)` (0, 45,
/// 90, ... for the default 8 sectors — 0° = due north, clockwise). Its score
/// is the fraction of grid cells along that bearing's center line — sampled
/// every [_sampleStepM] out to the loop radius `r = targetKm * 1000 / (2π)`
/// (the same radius `LoopPlanner._initialParam` seeds a loop candidate's
/// circle with) — that are **not** in [revealedCellKeys]. A sector pointed
/// entirely at fresh ground scores 1.0; one entirely re-covering already-seen
/// ground scores 0.0.
///
/// **Selection**: the `count` highest-scoring sectors win. Ties — most
/// obviously a virgin state, where every sector scores 1.0 — are broken by a
/// [seed]-derived shuffle rather than sector index order, so a fully unknown
/// area still spreads its candidates across different directions instead of
/// always picking sectors 0, 1, 2. A ±15° jitter (from the same seeded rng)
/// is then applied to every returned bearing — ties or not — so repeated
/// « Autres propositions » (bumping [seed]) do not keep proposing the exact
/// same handful of compass points.
///
/// [rng] mirrors `LoopPlanner`'s own constructor parameter: tests can pin it,
/// production leaves it as a real seeded `Random`. The same [seed] always
/// reproduces the same bearings.
List<double> exploreBearings({
  required (double, double) start,
  required double targetKm,
  required Set<String> revealedCellKeys,
  required int count,
  int sectors = 8,
  math.Random Function(int seed)? rng,
  int seed = 0,
}) {
  assert(sectors > 0, 'sectors must be positive');
  assert(count > 0, 'count must be positive');
  assert(targetKm > 0, 'targetKm must be positive');

  final radiusM = targetKm * 1000 / (2 * math.pi);
  final sectorStepDeg = 360.0 / sectors;
  final scores = List<double>.generate(
    sectors,
    (i) => _sectorUnrevealedFraction(
        start, i * sectorStepDeg, radiusM, revealedCellKeys),
  );

  final randomFactory = rng ?? math.Random.new;
  final random = randomFactory(seed);

  // A seeded shuffle gives every sector a reproducible-but-varied tie-break
  // rank, so equal-scoring sectors (the virgin-state norm) are still picked
  // in a spread-out, seed-dependent order rather than always index 0,1,2....
  final shuffled = List<int>.generate(sectors, (i) => i)..shuffle(random);
  final tieBreakRank = <int, int>{
    for (var i = 0; i < shuffled.length; i++) shuffled[i]: i,
  };

  final order = List<int>.generate(sectors, (i) => i)
    ..sort((a, b) {
      final byScore = scores[b].compareTo(scores[a]);
      if (byScore != 0) return byScore;
      return tieBreakRank[a]!.compareTo(tieBreakRank[b]!);
    });

  return [
    for (final sectorIndex in order.take(count))
      _jittered(sectorIndex * sectorStepDeg, random),
  ];
}

/// Fraction (0.0-1.0) of grid cells sampled every [_sampleStepM] along the
/// line from [start] toward [bearingDeg], out to [radiusM], that are absent
/// from [revealedCellKeys]. Always samples at least once, even when
/// [radiusM] is under one step.
double _sectorUnrevealedFraction(
  (double, double) start,
  double bearingDeg,
  double radiusM,
  Set<String> revealedCellKeys,
) {
  final (lat, lon) = start;
  final steps = math.max(1, (radiusM / _sampleStepM).ceil());
  var unrevealed = 0;
  for (var s = 1; s <= steps; s++) {
    final distanceM = math.min(s * _sampleStepM, radiusM);
    final (sampleLat, sampleLon) =
        destinationPoint(lat, lon, bearingDeg, distanceM);
    final cell = cellIdFor(sampleLat, sampleLon);
    if (!revealedCellKeys.contains(cell.key)) unrevealed++;
  }
  return unrevealed / steps;
}

/// [bearingDeg] offset by a draw from [random] in `[-15, 15)` degrees,
/// normalized back into `[0, 360)`.
double _jitterDeg(math.Random random) => (random.nextDouble() * 2 - 1) * 15.0;

double _jittered(double bearingDeg, math.Random random) {
  final jittered = (bearingDeg + _jitterDeg(random)) % 360;
  return jittered < 0 ? jittered + 360 : jittered;
}
