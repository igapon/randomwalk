import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/loop/geo_offsets.dart';
import 'package:randomwalk/loop/loop_planner.dart';
import 'package:randomwalk/loop/repeated_segments.dart';
import 'package:randomwalk/nav/polyline_math.dart';
import 'package:randomwalk/valhalla/models.dart';

/// Synthetic router: no network, no engine — the "route" is simply the
/// polygon through the requested locations, so its length is a pure
/// geometric function of the planner's own waypoints. That makes the
/// bisection's behaviour (convergence, call budget) exactly observable.
///
/// [capKm] simulates a physically unreachable target (the network cannot
/// yield more than that many kilometres); [alwaysNull] simulates a routing
/// engine that refuses every geometry.
class FakeRouter {
  FakeRouter({this.capKm, this.alwaysNull = false, this.pointsPerSegment = 8});

  final double? capKm;
  final bool alwaysNull;

  /// Sub-points inserted per polygon side, so the returned shape looks like
  /// a real (densified) polyline to `repeatedSegmentRatio`. Straight-line
  /// interpolation keeps the length unchanged.
  final int pointsPerSegment;

  int calls = 0;
  final List<List<(double, double)>> requests = [];
  final List<List<(double, double)>> shapes = [];

  Future<RouteResult?> route(List<(double, double)> locations) async {
    calls++;
    requests.add(locations);
    if (alwaysNull) return null;
    final cap = capKm;
    var km = polylineKm(locations);
    if (cap != null && km > cap) km = cap;
    final shape = densify(locations, pointsPerSegment);
    shapes.add(shape);
    return RouteResult(
      shape: shape,
      distanceKm: km,
      duration: Duration(seconds: (km * 720).round()), // ~5 km/h
      maneuvers: const [],
    );
  }
}

/// Router that reports a scripted distance sequence (cycling every
/// [maxRouterCallsPerCandidate] calls, i.e. one full budget per candidate)
/// regardless of the geometry asked for. Lets a test pin *which* probe the
/// planner keeps.
class ScriptedRouter {
  ScriptedRouter(this.distancesKm, {this.shapeFor});

  final List<double> distancesKm;

  /// Optional shape override, by call index (0-based); defaults to the
  /// densified request polygon.
  final List<(double, double)> Function(int callIndex)? shapeFor;

  int calls = 0;

  Future<RouteResult?> route(List<(double, double)> locations) async {
    final index = calls;
    calls++;
    final km = distancesKm[index % distancesKm.length];
    return RouteResult(
      shape: shapeFor?.call(index) ?? densify(locations, 8),
      distanceKm: km,
      duration: Duration.zero,
      maneuvers: const [],
    );
  }
}

/// Records the interleaving of rng draws and router calls. The planner draws
/// from the rng exactly once per candidate, before that candidate's first
/// router call, so the draws mark candidate boundaries exactly — no geometric
/// guessing needed to attribute calls to candidates.
class CallLog {
  final List<Object> events = [];

  math.Random rng(int seed) {
    events.add(seed);
    return math.Random(seed);
  }

  LoopRouter wrap(LoopRouter inner) => (locations) {
    events.add('call');
    return inner(locations);
  };

  List<int> get seeds => events.whereType<int>().toList();

  /// Router calls attributed to each candidate, in order.
  List<int> get callsPerCandidate {
    final counts = <int>[];
    for (final event in events) {
      if (event is int) {
        counts.add(0);
      } else if (counts.isNotEmpty) {
        counts[counts.length - 1]++;
      }
    }
    return counts;
  }
}

double polylineKm(List<(double, double)> pts) {
  var meters = 0.0;
  for (var i = 0; i < pts.length - 1; i++) {
    meters += metersBetween(pts[i].$1, pts[i].$2, pts[i + 1].$1, pts[i + 1].$2);
  }
  return meters / 1000;
}

List<(double, double)> densify(List<(double, double)> pts, int n) {
  final out = <(double, double)>[pts.first];
  for (var i = 0; i < pts.length - 1; i++) {
    final (aLat, aLon) = pts[i];
    final (bLat, bLon) = pts[i + 1];
    for (var k = 1; k <= n; k++) {
      final t = k / n;
      out.add((aLat + (bLat - aLat) * t, aLon + (bLon - aLon) * t));
    }
  }
  return out;
}

/// A straight line of [segments] hops of [stepM] metres that then retraces
/// its final hop, giving a shape with a small, exactly known repeated ratio:
/// one repeated hop over `segments` unique ones, i.e. `1 / segments`.
List<(double, double)> lineWithBackstep({
  required int segments,
  required double stepM,
}) {
  final points = [
    for (var i = 0; i <= segments; i++)
      destinationPoint(46.52, 6.63, 90, i * stepM),
  ];
  return [...points, points[points.length - 2]];
}

/// Rounded compass bearing from [from] to [to] — used to tell candidates
/// apart: bisection changes a candidate's radius but never its bearing.
int bearingKey((double, double) from, (double, double) to) {
  final dLat = to.$1 - from.$1;
  final dLon = (to.$2 - from.$2) * math.cos(from.$1 * math.pi / 180);
  return (math.atan2(dLon, dLat) * 180 / math.pi * 10).round();
}

void main() {
  const start = (46.52, 6.63);

  LoopRequest loopRequest({double targetKm = 5, int seed = 42}) => LoopRequest(
    kind: PlanKind.loop,
    start: start,
    targetKm: targetKm,
    profile: RoutingProfile.walk,
    seed: seed,
  );

  LoopRequest aToBRequest({
    required (double, double) end,
    double targetKm = 5,
    int seed = 7,
  }) => LoopRequest(
    kind: PlanKind.toDestination,
    start: start,
    end: end,
    targetKm: targetKm,
    profile: RoutingProfile.walk,
    seed: seed,
  );

  /// Set of bearings the planner probed, one per candidate.
  Set<int> probedBearings(FakeRouter fake) =>
      fake.requests.map((r) => bearingKey(r.first, r[1])).toSet();

  group('LoopRequest validation', () {
    test('non-positive targetKm is rejected', () {
      expect(() => loopRequest(targetKm: 0), throwsArgumentError);
      expect(() => loopRequest(targetKm: -3), throwsArgumentError);
    });

    test('toDestination without end is rejected', () {
      expect(
        () => LoopRequest(
          kind: PlanKind.toDestination,
          start: start,
          targetKm: 5,
          profile: RoutingProfile.walk,
          seed: 1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('LoopPlanner — search constants', () {
    test('are pinned: 4 calls, 2 failures, 0.7 shrink', () {
      expect(LoopPlanner.maxRouterCallsPerCandidate, 4);
      expect(LoopPlanner.maxConsecutiveFailures, 2);
      expect(LoopPlanner.failureShrinkFactor, 0.7);
      expect(LoopPlanner.expansionFactor, 1.5);
      expect(LoopPlanner.candidateCount, 3);
      expect(LoopPlanner.waypointCount, 3);
      expect(LoopPlanner.targetTolerance, 0.10);
    });
  });

  group('LoopPlanner — loop', () {
    test('converges within +/-10% of a 5 km walking target', () async {
      final fake = FakeRouter();
      final result = await LoopPlanner(
        router: fake.route,
      ).plan(loopRequest(targetKm: 5));

      expect(result.candidates, isNotEmpty);
      expect(result.targetMet, isTrue);
      final best = result.candidates.first;
      expect(best.gapRatio.abs(), lessThanOrEqualTo(0.10 + 1e-9));
      expect(best.route.distanceKm, closeTo(5.0, 0.5));
      expect(result.bestGapRatio, closeTo(best.gapRatio.abs(), 1e-12));
    });

    test('locations close the loop: start .. waypoints .. start', () async {
      final fake = FakeRouter();
      await LoopPlanner(router: fake.route).plan(loopRequest());

      for (final request in fake.requests) {
        expect(request, hasLength(LoopPlanner.waypointCount + 2));
        expect(request.first, start);
        expect(request.last, start);
      }
    });

    test('the three candidates probe three distinct bearings', () async {
      final fake = FakeRouter();
      await LoopPlanner(router: fake.route).plan(loopRequest());

      expect(probedBearings(fake), hasLength(LoopPlanner.candidateCount));
    });

    test('consecutive seeds share no candidate', () async {
      // Sub-seeds are spaced by candidateCount, so seed n and seed n+1 have
      // disjoint candidate sets (the UI can offer "other options" with +1).
      final fakeA = FakeRouter();
      final fakeB = FakeRouter();
      await LoopPlanner(router: fakeA.route).plan(loopRequest(seed: 1));
      await LoopPlanner(router: fakeB.route).plan(loopRequest(seed: 2));

      expect(
        probedBearings(fakeA).intersection(probedBearings(fakeB)),
        isEmpty,
      );
    });

    test('same seed is deterministic across runs', () async {
      final fakeA = FakeRouter();
      final fakeB = FakeRouter();
      final a = await LoopPlanner(
        router: fakeA.route,
      ).plan(loopRequest(seed: 99));
      final b = await LoopPlanner(
        router: fakeB.route,
      ).plan(loopRequest(seed: 99));

      expect(fakeA.calls, fakeB.calls);
      expect(fakeA.requests, fakeB.requests);
      expect(a.candidates.length, b.candidates.length);
      for (var i = 0; i < a.candidates.length; i++) {
        expect(a.candidates[i].route.shape, b.candidates[i].route.shape);
        expect(a.candidates[i].gapRatio, b.candidates[i].gapRatio);
        expect(a.candidates[i].score, b.candidates[i].score);
      }
    });

    test(
      'bearings come from the injected rng, sub-seeded per candidate',
      () async {
        final log = CallLog();
        final fake = FakeRouter();
        await LoopPlanner(
          router: log.wrap(fake.route),
          rng: log.rng,
        ).plan(loopRequest(seed: 1000));

        // seed * candidateCount + index.
        expect(log.seeds, [3000, 3001, 3002]);
      },
    );

    test('score is 0.6/0.4 weighted for loops', () async {
      final fake = FakeRouter();
      final result = await LoopPlanner(router: fake.route).plan(loopRequest());

      for (final c in result.candidates) {
        expect(
          c.score,
          closeTo(0.6 * c.gapRatio.abs() + 0.4 * c.repeatedRatio, 1e-12),
        );
      }
    });
  });

  group('LoopPlanner — Task 7: explore-mode bias', () {
    test('preferredBearingsDeg overrides the rng bearing for the candidates '
        'it covers, leaving the rest on their usual rng draw', () async {
      final fake = FakeRouter();
      final request = LoopRequest(
        kind: PlanKind.loop,
        start: start,
        targetKm: 5,
        profile: RoutingProfile.walk,
        seed: 42,
        preferredBearingsDeg: const [10, 130], // covers candidates 0 and 1 only
      );
      await LoopPlanner(router: fake.route).plan(request);

      final degrees = probedBearings(fake).map((b) => b / 10.0).toSet();
      expect(degrees, hasLength(LoopPlanner.candidateCount));
      expect(
        degrees.any((b) => (b - 10).abs() < 0.5),
        isTrue,
        reason: 'candidate 0 should probe ~10°: $degrees',
      );
      expect(
        degrees.any((b) => (b - 130).abs() < 0.5),
        isTrue,
        reason: 'candidate 1 should probe ~130°: $degrees',
      );
    });

    test(
      'preferredBearingsDeg is ignored for A->B (no bearing to seed)',
      () async {
        final fake = FakeRouter();
        final end = destinationPoint(start.$1, start.$2, 90, 4000);
        final request = LoopRequest(
          kind: PlanKind.toDestination,
          start: start,
          end: end,
          targetKm: 6,
          profile: RoutingProfile.walk,
          seed: 7,
          preferredBearingsDeg: const [10, 130, 250],
        );
        final result = await LoopPlanner(router: fake.route).plan(request);
        // Still routes fine — the field is simply a no-op for A->B, never a
        // crash or a behavior change to the ellipse-bulge search.
        expect(result.candidates, isNotEmpty);
      },
    );

    test('explorationBonus shifts candidate ranking toward more-unexplored '
        'routes', () async {
      // Every candidate hits its own scripted distance within tolerance on
      // the very first probe, so there is exactly one router call per
      // candidate — call index 0, 1, 2 — each getting the *same* shape (so
      // repeatedRatio is identical for all three) but a distinct distance:
      // candidate 0 is the worst distance match (8% gap), candidate 1 the
      // best (0% gap), candidate 2 in between (4%). Without a bonus,
      // candidate 1 wins on distance accuracy alone (see the regression
      // test below); `explorationBonus` favoring candidate 0's distance
      // must be able to overturn that.
      final sharedShape = densify([start, start], 4);
      final router = ScriptedRouter([
        5.4,
        5.0,
        5.2,
      ], shapeFor: (_) => sharedShape);

      final favored = LoopRequest(
        kind: PlanKind.loop,
        start: start,
        targetKm: 5,
        profile: RoutingProfile.walk,
        seed: 1,
        explorationBonus: (route) => route.distanceKm == 5.4 ? 1.0 : 0.0,
      );
      final favoredResult = await LoopPlanner(
        router: router.route,
      ).plan(favored);
      expect(
        favoredResult.candidates.first.route.distanceKm,
        5.4,
        reason:
            'the bonus-favored candidate (worst distance match) '
            'should now win over the two better-but-unbonused ones',
      );
    });

    test('explorationBonus absent leaves scoring/ranking exactly as before '
        '(regression)', () async {
      final router = ScriptedRouter(
        [5.0],
        shapeFor: (callIndex) => [
          (46.52, 6.63),
          (46.52 + callIndex * 0.001, 6.63),
          (46.52, 6.63),
        ],
      );
      final plain = LoopRequest(
        kind: PlanKind.loop,
        start: start,
        targetKm: 5,
        profile: RoutingProfile.walk,
        seed: 1,
      );
      final result = await LoopPlanner(router: router.route).plan(plain);
      // No bonus to break the tie: the first-scored (lowest index) candidate
      // survives dedup, exactly the pre-Task-7 tie-break behavior.
      expect(result.candidates.first.route.shape[1].$1, closeTo(46.52, 1e-9));
    });

    test('a uniform (virgin-state) explorationBonus does not change the '
        'candidate ranking — Explorer degrades to Distance behavior when '
        'nothing is revealed yet', () async {
      final fake = FakeRouter();
      final withoutBonus = await LoopPlanner(
        router: fake.route,
      ).plan(loopRequest(seed: 5));

      final fake2 = FakeRouter();
      final withUniformBonus = await LoopPlanner(router: fake2.route).plan(
        LoopRequest(
          kind: PlanKind.loop,
          start: start,
          targetKm: 5,
          profile: RoutingProfile.walk,
          seed: 5,
          // Every route scores the same bonus — a fully-unrevealed area,
          // exactly like a fresh install's GameState.revealedCellKeys.
          explorationBonus: (route) => 1.0,
        ),
      );

      // Subtracting the same constant from every candidate's score cannot
      // change their relative order, so the two plans pick the same
      // candidates in the same order (only the absolute score differs).
      expect(
        withUniformBonus.candidates.length,
        withoutBonus.candidates.length,
      );
      for (var i = 0; i < withoutBonus.candidates.length; i++) {
        expect(
          withUniformBonus.candidates[i].route.shape,
          withoutBonus.candidates[i].route.shape,
        );
        expect(
          withUniformBonus.candidates[i].score,
          closeTo(withoutBonus.candidates[i].score - 0.3, 1e-9),
        );
      }
    });
  });

  group('LoopPlanner — repeated-segment weighting', () {
    // A route that retraces itself completely: repeatedRatio ~= 1.0, so the
    // repeated weight (0.4 loop / 0.3 A->B) is the whole score once the
    // distance is exactly on target.
    final backtrack = destinationPoint(start.$1, start.$2, 30, 500);
    final outAndBack = densify([start, backtrack, start, backtrack, start], 8);

    LoopRouter onTargetOutAndBack(double targetKm) =>
        (locations) async => RouteResult(
          shape: outAndBack,
          distanceKm: targetKm,
          duration: Duration.zero,
          maneuvers: const [],
        );

    test('the out-and-back fixture really does saturate the ratio', () {
      expect(repeatedSegmentRatio(outAndBack, cellM: 25), closeTo(1.0, 1e-9));
    });

    test('a fully retracing loop scores 0.4 on the repeated term', () async {
      final result = await LoopPlanner(
        router: onTargetOutAndBack(5),
      ).plan(loopRequest(targetKm: 5));

      final best = result.candidates.first;
      expect(best.repeatedRatio, closeTo(1.0, 1e-9));
      expect(best.gapRatio, closeTo(0.0, 1e-12));
      expect(best.score, closeTo(0.4, 1e-9)); // 0.6*0 + 0.4*1
      expect(result.targetMet, isTrue);
    });

    test('the same retracing route scores 0.3 for A to B', () async {
      final end = destinationPoint(start.$1, start.$2, 90, 2000);
      final result = await LoopPlanner(
        router: onTargetOutAndBack(5),
      ).plan(aToBRequest(end: end, targetKm: 5));

      final best = result.candidates.first;
      expect(best.repeatedRatio, closeTo(1.0, 1e-9));
      expect(best.score, closeTo(0.3, 1e-9)); // 0.7*0 + 0.3*1
    });
  });

  group('LoopPlanner — targetMet honesty', () {
    test('follows candidates.first, not "any candidate"', () async {
      // Candidates 0 and 1 burn their whole budget at +15%; candidate 2 lands
      // at +9% but retraces itself entirely, so it scores worst (0.454 vs
      // 0.09) and is NOT what the UI shows first.
      final backtrack = destinationPoint(start.$1, start.$2, 30, 500);
      final retracing = densify([start, backtrack, start, backtrack, start], 8);
      final scripted = ScriptedRouter(
        // 4 probes for candidate 0, 4 for candidate 1, then candidate 2.
        [5.75, 5.75, 5.75, 5.75, 5.75, 5.75, 5.75, 5.75, 5.45],
        shapeFor: (index) =>
            index >= 8 ? retracing : densify([start, start], 1),
      );
      final result = await LoopPlanner(
        router: scripted.route,
      ).plan(loopRequest(targetKm: 5));

      final gaps = result.candidates.map((c) => c.gapRatio).toList();
      // Candidates 0 and 1 are identical offers and collapse to one.
      expect(gaps, hasLength(2));
      expect(gaps.first, closeTo(0.15, 1e-9));
      expect(gaps.last, closeTo(0.09, 1e-9));
      expect(
        result.targetMet,
        isFalse,
        reason: 'the displayed candidate is 15% off',
      );
      expect(result.bestGapRatio, closeTo(0.09, 1e-9));

      final scores = result.candidates.map((c) => c.score).toList();
      expect(scores, [...scores]..sort());
    });

    test('bestGapRatio reports a route that dedup dropped', () async {
      // A duplicate pair where the *dropped* one is the closer route:
      //   kept    5.50 km, gap 0.10, repeated 0.000 -> score 0.0600
      //   dropped 5.45 km, gap 0.09, repeated 0.048 -> score 0.0730
      // They are 0.9% apart in distance and 0.048 apart in repeated ratio,
      // so both dedup windows catch them — yet the better-scored survivor is
      // the further-off one. "Closest we found" must still be 0.09.
      final clean = densify([
        start,
        destinationPoint(start.$1, start.$2, 90, 2000),
      ], 20);
      final slightlyRetraced = lineWithBackstep(segments: 21, stepM: 100);
      final scripted = ScriptedRouter([
        5.5,
        5.45,
        5.45,
      ], shapeFor: (index) => index == 0 ? clean : slightlyRetraced);
      final result = await LoopPlanner(
        router: scripted.route,
      ).plan(loopRequest(targetKm: 5));

      expect(
        repeatedSegmentRatio(slightlyRetraced, cellM: 25),
        closeTo(1 / 21, 1e-9),
      );
      expect(result.candidates, hasLength(1));
      expect(result.candidates.single.gapRatio, closeTo(0.10, 1e-9));
      expect(result.candidates.single.repeatedRatio, closeTo(0.0, 1e-9));
      expect(
        result.bestGapRatio,
        closeTo(0.09, 1e-9),
        reason: 'the dropped duplicate was the closest route routed',
      );
    });

    test('bestGapRatio is null on an empty plan', () async {
      final fake = FakeRouter(alwaysNull: true);
      final result = await LoopPlanner(router: fake.route).plan(loopRequest());

      expect(result.candidates, isEmpty);
      expect(result.bestGapRatio, isNull);
      expect(result.targetMet, isFalse);
    });
  });

  group('LoopPlanner — short loops', () {
    test('repeated ratio does not saturate on a clean 300 m loop', () async {
      final fake = FakeRouter();
      final result = await LoopPlanner(
        router: fake.route,
      ).plan(loopRequest(targetKm: 0.3));

      expect(result.candidates, isNotEmpty);
      for (final c in result.candidates) {
        expect(c.repeatedRatio, lessThan(0.3));
      }
      // Why the cell scaling exists: at the unscaled 25 m cell this same
      // clean geometry reads as heavily retraced, because consecutive
      // polyline points of a 300 m loop share cells.
      final worstAtFixedCell = fake.shapes
          .map((s) => repeatedSegmentRatio(s, cellM: 25))
          .reduce(math.max);
      expect(worstAtFixedCell, greaterThan(0.3));
    });
  });

  group('LoopPlanner — A to B', () {
    test('ellipse detour converges to the target', () async {
      final end = destinationPoint(start.$1, start.$2, 90, 2000);
      final fake = FakeRouter();
      final result = await LoopPlanner(
        router: fake.route,
      ).plan(aToBRequest(end: end, targetKm: 5));

      expect(result.candidates, isNotEmpty);
      expect(result.targetMet, isTrue);
      expect(
        result.candidates.first.gapRatio.abs(),
        lessThanOrEqualTo(0.10 + 1e-9),
      );
      final scores = result.candidates.map((c) => c.score).toList();
      expect(scores, [...scores]..sort());

      for (final request in fake.requests) {
        expect(request, hasLength(LoopPlanner.waypointCount + 2));
        expect(request.first, start);
        expect(request.last, end);
      }
    });

    test('scores are 0.7/0.3 weighted for A to B', () async {
      final end = destinationPoint(start.$1, start.$2, 90, 2000);
      final fake = FakeRouter();
      final result = await LoopPlanner(
        router: fake.route,
      ).plan(aToBRequest(end: end, targetKm: 5));

      for (final c in result.candidates) {
        expect(
          c.score,
          closeTo(0.7 * c.gapRatio.abs() + 0.3 * c.repeatedRatio, 1e-12),
        );
      }
    });

    test(
      'no surplus (target below the direct distance) routes A to B direct',
      () async {
        final end = destinationPoint(start.$1, start.$2, 45, 6000);
        final fake = FakeRouter();
        final result = await LoopPlanner(
          router: fake.route,
        ).plan(aToBRequest(end: end, targetKm: 3));

        expect(fake.calls, 1);
        expect(fake.requests.single, [start, end]);
        expect(result.candidates, hasLength(1));
        // 6 km direct against a 3 km target: gap is reported, not hidden.
        expect(result.candidates.single.gapRatio, closeTo(1.0, 0.01));
        expect(result.bestGapRatio, closeTo(1.0, 0.01));
        expect(result.targetMet, isFalse);
      },
    );
  });

  group('LoopPlanner — deduplication', () {
    test('rotation-invariant candidates collapse to one offer', () async {
      // The synthetic router's loop perimeter depends only on the radius, so
      // all three candidates converge to the same length with the same
      // (zero) retracing — three offers the user could not tell apart.
      final log = CallLog();
      final fake = FakeRouter();
      final result = await LoopPlanner(
        router: log.wrap(fake.route),
        rng: log.rng,
      ).plan(loopRequest());

      expect(
        log.seeds,
        hasLength(LoopPlanner.candidateCount),
        reason: 'all three candidates were still searched',
      );
      expect(probedBearings(fake), hasLength(LoopPlanner.candidateCount));
      expect(result.candidates, hasLength(1));
    });

    test('degenerate zero-length routes are never merged', () async {
      // No meaningful relative distance comparison exists at 0 km, so the
      // dedup window must not swallow them (and must not divide by zero).
      final scripted = ScriptedRouter([0.0]);
      final result = await LoopPlanner(
        router: scripted.route,
      ).plan(loopRequest());

      expect(result.candidates, hasLength(LoopPlanner.candidateCount));
      expect(result.bestGapRatio, closeTo(1.0, 1e-9)); // 0 km vs 5 km target
      expect(result.targetMet, isFalse);
    });

    test('genuinely different lengths are both kept', () async {
      // 4.0 km vs 5.6 km against a 5 km target: 32% apart, well outside the
      // 2% dedup window.
      final scripted = ScriptedRouter([4.0, 4.0, 4.0, 4.0, 5.6]);
      final result = await LoopPlanner(
        router: scripted.route,
      ).plan(loopRequest(targetKm: 5));

      expect(result.candidates.map((c) => c.route.distanceKm).toSet(), {
        4.0,
        5.6,
      });
    });
  });

  group('LoopPlanner — failure and budget', () {
    test(
      'router failing everywhere gives an empty plan, never a throw',
      () async {
        final log = CallLog();
        final fake = FakeRouter(alwaysNull: true);
        final result = await LoopPlanner(
          router: log.wrap(fake.route),
          rng: log.rng,
        ).plan(loopRequest());

        expect(result.candidates, isEmpty);
        expect(result.targetMet, isFalse);
        // One shrink-and-retry, then the second consecutive failure gives up.
        expect(log.callsPerCandidate, [2, 2, 2]);
      },
    );

    test(
      'unreachable target keeps the best real gap with targetMet false',
      () async {
        // The network can never yield more than 2 km, the user wants 10.
        final fake = FakeRouter(capKm: 2);
        final result = await LoopPlanner(
          router: fake.route,
        ).plan(loopRequest(targetKm: 10));

        expect(result.candidates, isNotEmpty);
        expect(result.targetMet, isFalse);
        expect(result.candidates.first.gapRatio, closeTo(-0.8, 1e-9));
        expect(result.bestGapRatio, closeTo(0.8, 1e-9));
        expect(result.candidates.first.route.distanceKm, closeTo(2.0, 1e-9));
      },
    );

    test('never exceeds 4 router calls for any single candidate', () async {
      final log = CallLog();
      final fake = FakeRouter(capKm: 2);
      await LoopPlanner(
        router: log.wrap(fake.route),
        rng: log.rng,
      ).plan(loopRequest(targetKm: 10));

      // A capped router can never converge, so every candidate burns its
      // whole budget — the tightest possible check of the per-candidate cap.
      expect(log.callsPerCandidate, hasLength(LoopPlanner.candidateCount));
      for (final calls in log.callsPerCandidate) {
        expect(
          calls,
          lessThanOrEqualTo(LoopPlanner.maxRouterCallsPerCandidate),
        );
      }
      expect(log.callsPerCandidate, [4, 4, 4]);
    });

    test(
      'a later, worse probe never displaces an earlier better one',
      () async {
        // Against a 5 km target: |gap| 0.50, 0.12, 0.40, 0.40 — the keeper is
        // probe 2 (5.6 km), which is neither the first nor the last call.
        final scripted = ScriptedRouter([2.5, 5.6, 3.0, 3.0]);
        final result = await LoopPlanner(
          router: scripted.route,
        ).plan(loopRequest(targetKm: 5));

        expect(result.candidates, isNotEmpty);
        expect(result.candidates.first.route.distanceKm, 5.6);
        expect(result.candidates.first.gapRatio, closeTo(0.12, 1e-9));
        expect(result.targetMet, isFalse);
      },
    );

    test(
      'a candidate that only fails late still returns its best route',
      () async {
        // Succeed on the first probe (too short for a 20 km target), then
        // fail: the planner must keep the successful route.
        var call = 0;
        final fake = FakeRouter();
        Future<RouteResult?> flaky(List<(double, double)> locations) async {
          call++;
          if (call % 3 == 1) return fake.route(locations);
          return null;
        }

        final result = await LoopPlanner(
          router: flaky,
        ).plan(loopRequest(targetKm: 20));

        expect(result.candidates, isNotEmpty);
        expect(result.targetMet, isFalse);
        for (final c in result.candidates) {
          expect(c.route.distanceKm, greaterThan(0));
        }
      },
    );
  });
}
