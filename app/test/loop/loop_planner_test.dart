import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/loop/geo_offsets.dart';
import 'package:randomwalk/loop/loop_planner.dart';
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

  Future<RouteResult?> route(List<(double, double)> locations) async {
    calls++;
    requests.add(locations);
    if (alwaysNull) return null;
    final cap = capKm;
    var km = _polylineKm(locations);
    if (cap != null && km > cap) km = cap;
    return RouteResult(
      shape: _densify(locations, pointsPerSegment),
      distanceKm: km,
      duration: Duration(seconds: (km * 720).round()), // ~5 km/h
      maneuvers: const [],
    );
  }
}

double _polylineKm(List<(double, double)> pts) {
  var meters = 0.0;
  for (var i = 0; i < pts.length - 1; i++) {
    meters += metersBetween(pts[i].$1, pts[i].$2, pts[i + 1].$1, pts[i + 1].$2);
  }
  return meters / 1000;
}

List<(double, double)> _densify(List<(double, double)> pts, int n) {
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
  }) =>
      LoopRequest(
        kind: PlanKind.toDestination,
        start: start,
        end: end,
        targetKm: targetKm,
        profile: RoutingProfile.walk,
        seed: seed,
      );

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

  group('LoopPlanner — loop', () {
    test('converges within +/-10% of a 5 km walking target', () async {
      final fake = FakeRouter();
      final result =
          await LoopPlanner(router: fake.route).plan(loopRequest(targetKm: 5));

      expect(result.candidates, hasLength(LoopPlanner.candidateCount));
      expect(result.targetMet, isTrue);
      final best = result.candidates.first;
      expect(best.gapRatio.abs(), lessThanOrEqualTo(0.10 + 1e-9));
      expect(best.route.distanceKm, closeTo(5.0, 0.5));
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

    test('the three candidates are geometrically distinct', () async {
      final fake = FakeRouter();
      final result = await LoopPlanner(router: fake.route).plan(loopRequest());

      final shapes = result.candidates.map((c) => c.route.shape[1]).toSet();
      expect(shapes, hasLength(result.candidates.length));
    });

    test('different seeds yield different candidates', () async {
      // Note: candidate sub-seeds are `seed + index`, so *adjacent* request
      // seeds deliberately share two of their three candidates. Distinctness
      // is asserted across seeds far enough apart to have no overlap.
      final fakeA = FakeRouter();
      final fakeB = FakeRouter();
      final a =
          await LoopPlanner(router: fakeA.route).plan(loopRequest(seed: 1));
      final b =
          await LoopPlanner(router: fakeB.route).plan(loopRequest(seed: 12345));

      final firstWaypointsA = a.candidates.map((c) => c.route.shape[1]).toSet();
      final firstWaypointsB = b.candidates.map((c) => c.route.shape[1]).toSet();
      expect(firstWaypointsA.intersection(firstWaypointsB), isEmpty);
    });

    test('same seed is deterministic across runs', () async {
      final fakeA = FakeRouter();
      final fakeB = FakeRouter();
      final a = await LoopPlanner(router: fakeA.route).plan(loopRequest(seed: 99));
      final b = await LoopPlanner(router: fakeB.route).plan(loopRequest(seed: 99));

      expect(fakeA.calls, fakeB.calls);
      expect(fakeA.requests, fakeB.requests);
      expect(a.candidates.length, b.candidates.length);
      for (var i = 0; i < a.candidates.length; i++) {
        expect(a.candidates[i].route.shape, b.candidates[i].route.shape);
        expect(a.candidates[i].gapRatio, b.candidates[i].gapRatio);
        expect(a.candidates[i].score, b.candidates[i].score);
      }
    });

    test('bearings come from the injected rng, seeded per candidate', () async {
      final seeds = <int>[];
      final fake = FakeRouter();
      await LoopPlanner(
        router: fake.route,
        rng: (seed) {
          seeds.add(seed);
          return math.Random(seed);
        },
      ).plan(loopRequest(seed: 1000));

      expect(seeds, [1000, 1001, 1002]);
    });

    test('candidates are sorted by ascending score, 0.6/0.4 weighted',
        () async {
      final fake = FakeRouter();
      final result = await LoopPlanner(router: fake.route).plan(loopRequest());

      for (final c in result.candidates) {
        expect(
          c.score,
          closeTo(0.6 * c.gapRatio.abs() + 0.4 * c.repeatedRatio, 1e-12),
        );
      }
      final scores = result.candidates.map((c) => c.score).toList();
      final sorted = [...scores]..sort();
      expect(scores, sorted);
    });
  });

  group('LoopPlanner — A to B', () {
    test('ellipse detour converges to the target', () async {
      final end = destinationPoint(start.$1, start.$2, 90, 2000);
      final fake = FakeRouter();
      final result = await LoopPlanner(router: fake.route)
          .plan(aToBRequest(end: end, targetKm: 5));

      expect(result.candidates, hasLength(LoopPlanner.candidateCount));
      expect(result.targetMet, isTrue);
      expect(result.candidates.first.gapRatio.abs(),
          lessThanOrEqualTo(0.10 + 1e-9));

      for (final request in fake.requests) {
        expect(request, hasLength(LoopPlanner.waypointCount + 2));
        expect(request.first, start);
        expect(request.last, end);
      }
    });

    test('scores are 0.7/0.3 weighted for A to B', () async {
      final end = destinationPoint(start.$1, start.$2, 90, 2000);
      final fake = FakeRouter();
      final result = await LoopPlanner(router: fake.route)
          .plan(aToBRequest(end: end, targetKm: 5));

      for (final c in result.candidates) {
        expect(
          c.score,
          closeTo(0.7 * c.gapRatio.abs() + 0.3 * c.repeatedRatio, 1e-12),
        );
      }
    });

    test('no surplus (target below the direct distance) routes A to B direct',
        () async {
      final end = destinationPoint(start.$1, start.$2, 45, 6000);
      final fake = FakeRouter();
      final result = await LoopPlanner(router: fake.route)
          .plan(aToBRequest(end: end, targetKm: 3));

      expect(fake.calls, 1);
      expect(fake.requests.single, [start, end]);
      expect(result.candidates, hasLength(1));
      // 6 km direct against a 3 km target: gap is reported, not hidden.
      expect(result.candidates.single.gapRatio, closeTo(1.0, 0.01));
      expect(result.targetMet, isFalse);
    });
  });

  group('LoopPlanner — failure and budget', () {
    test('router failing everywhere gives an empty plan, never a throw',
        () async {
      final fake = FakeRouter(alwaysNull: true);
      final result = await LoopPlanner(router: fake.route).plan(loopRequest());

      expect(result.candidates, isEmpty);
      expect(result.targetMet, isFalse);
      // Two consecutive failures abandon a candidate.
      expect(
        fake.calls,
        LoopPlanner.candidateCount * LoopPlanner.maxConsecutiveFailures,
      );
    });

    test('unreachable target keeps the best real gap with targetMet false',
        () async {
      // The network can never yield more than 2 km, the user wants 10.
      final fake = FakeRouter(capKm: 2);
      final result =
          await LoopPlanner(router: fake.route).plan(loopRequest(targetKm: 10));

      expect(result.candidates, hasLength(LoopPlanner.candidateCount));
      expect(result.targetMet, isFalse);
      expect(result.candidates.first.gapRatio, closeTo(-0.8, 1e-9));
      expect(result.candidates.first.route.distanceKm, closeTo(2.0, 1e-9));
    });

    test('bisection never exceeds 4 router calls per candidate', () async {
      final fake = FakeRouter(capKm: 2);
      await LoopPlanner(router: fake.route).plan(loopRequest(targetKm: 10));

      // A capped router can never converge, so every candidate burns its
      // whole budget — the tightest possible check of the cap.
      expect(
        fake.calls,
        LoopPlanner.candidateCount * LoopPlanner.maxRouterCallsPerCandidate,
      );
    });

    test('a candidate that only fails late still returns its best route',
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

      final result =
          await LoopPlanner(router: flaky).plan(loopRequest(targetKm: 20));

      expect(result.candidates, hasLength(LoopPlanner.candidateCount));
      expect(result.targetMet, isFalse);
      for (final c in result.candidates) {
        expect(c.route.distanceKm, greaterThan(0));
      }
    });
  });
}
