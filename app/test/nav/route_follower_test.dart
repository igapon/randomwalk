import 'dart:math' show cos, pi;

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/nav/eta.dart';
import 'package:randomwalk/nav/polyline_math.dart';
import 'package:randomwalk/nav/route_follower.dart';
import 'package:randomwalk/valhalla/models.dart';

/// Builds a [RouteResult] fixture without needing a real Valhalla response.
RouteResult syntheticRoute(
    List<(double, double)> shape, List<(int, String)> maneuvers) {
  return RouteResult(
    shape: shape,
    distanceKm: RouteGeometry(shape).totalKm,
    duration: const Duration(seconds: 0),
    maneuvers: [
      for (final (index, instruction) in maneuvers)
        Maneuver(instruction: instruction, lengthKm: 0, beginShapeIndex: index),
    ],
  );
}

/// Offsets [base] by ([eastM], [northM]) using the same equirectangular
/// approximation `polyline_math.dart` uses internally, so synthetic fixes
/// land where the tests expect relative to route geometry.
(double, double) offsetMeters((double, double) base, double eastM, double northM) {
  final lat = base.$1 + northM / 110540.0;
  final lon = base.$2 + eastM / (111320.0 * cos(base.$1 * pi / 180));
  return (lat, lon);
}

void main() {
  group('behavior 1: current maneuver and distanceToManeuverM', () {
    // Straight line north, 11 points ~111 m apart (~1.1 km total).
    final shape = <(double, double)>[
      for (var i = 0; i <= 10; i++) (46.5200 + i * 0.001, 6.6300),
    ];
    // Last maneuver begins well before the final vertex, so "targets end of
    // route" is distinguishable from "targets the maneuver's own position".
    final route = syntheticRoute(
        shape, [(0, 'Départ'), (4, 'Tournez à gauche'), (8, 'Arrivée')]);
    final geometry = RouteGeometry(shape);

    test('picks the first maneuver strictly ahead of alongKm', () {
      final follower = RouteFollower(route);
      final fix = shape[2];
      final u = follower.update(fix.$1, fix.$2, DateTime(2026, 1, 1));

      expect(u.maneuverIndex, 1);
      expect(u.instruction, 'Tournez à gauche');
      expect(u.distanceToManeuverM,
          closeTo((geometry.cumulativeKm[4] - geometry.cumulativeKm[2]) * 1000, 1));
    });

    test('last maneuver targets the end of the route, not its own position', () {
      final follower = RouteFollower(route);
      final fix = shape[6];
      final u = follower.update(fix.$1, fix.$2, DateTime(2026, 1, 1));

      expect(u.maneuverIndex, 2);
      expect(u.instruction, 'Arrivée');
      final toEnd = (geometry.totalKm - geometry.cumulativeKm[6]) * 1000;
      final toManeuverOwnPosition =
          (geometry.cumulativeKm[8] - geometry.cumulativeKm[6]) * 1000;
      expect(u.distanceToManeuverM, closeTo(toEnd, 1));
      expect((u.distanceToManeuverM - toManeuverOwnPosition).abs(), greaterThan(50));
    });
  });

  group('behavior 2: monotonic progression on self-crossing routes', () {
    test('a fix at a self-crossing point does not snap back to the start', () {
      final base = (46.5200, 6.6300);
      // A figure-8: out on one diamond loop, back through the crossing
      // point at the origin, then out on a second diamond loop.
      final shape = <(double, double)>[
        offsetMeters(base, 0, 0), // P0 - start
        offsetMeters(base, 100, 100), // P1
        offsetMeters(base, 200, 0), // P2
        offsetMeters(base, 100, -100), // P3
        offsetMeters(base, 0, 0), // P4 - closes loop A (== P0)
        offsetMeters(base, -100, 100), // P5
        offsetMeters(base, -200, 0), // P6
        offsetMeters(base, -100, -100), // P7
        offsetMeters(base, 0, 0), // P8 - end, closes loop B (== P0)
      ];
      final route = syntheticRoute(shape, [(0, 'Départ'), (8, 'Arrivée')]);
      final follower = RouteFollower(route);
      var t = DateTime(2026, 1, 1);

      // Establish progress well into loop A, unambiguously inside segment 3
      // (midpoint between P3 and P4), so lastSegmentIndex becomes 3.
      final midSeg3 = offsetMeters(base, 50, -50);
      final u1 = follower.update(midSeg3.$1, midSeg3.$2, t);
      t = t.add(const Duration(seconds: 1));

      // Now feed a fix exactly at the crossing point, which is equidistant
      // (cross-track 0) from segment 0 (route start) and segment 3/4 (where
      // we actually are). Without the searchFrom bias this would snap back
      // to the very start of the route.
      final crossing = offsetMeters(base, 0, 0);
      final u2 = follower.update(crossing.$1, crossing.$2, t);

      expect(u1.alongKm, greaterThan(0.3));
      // Progressed forward (closing loop A), not regressed to the start.
      expect(u2.alongKm, greaterThanOrEqualTo(u1.alongKm - 0.01));
      expect(u2.alongKm, greaterThan(0.3));
    });
  });

  group('behavior 3: off-route timing uses update timestamps', () {
    test('off-route only after >10s continuously beyond threshold, resets on a good fix', () {
      final base = (46.5200, 6.6300);
      final shape = <(double, double)>[
        offsetMeters(base, 0, 0),
        offsetMeters(base, 0, 1000),
      ];
      final route = syntheticRoute(shape, [(0, 'Départ'), (1, 'Arrivée')]);
      final follower = RouteFollower(route);

      var t = DateTime(2026, 1, 1);

      // On-route fix.
      final onRoute = offsetMeters(base, 0, 200);
      final u0 = follower.update(onRoute.$1, onRoute.$2, t);
      expect(u0.offRoute, isFalse);

      // First off-route fix (crossTrack ~50 m > 30 m threshold). Starts the
      // off-route clock; grace period not yet elapsed.
      t = t.add(const Duration(seconds: 1));
      final off1 = offsetMeters(base, 50, 210);
      final u1 = follower.update(off1.$1, off1.$2, t);
      expect(u1.crossTrackM, greaterThan(30));
      expect(u1.offRoute, isFalse);

      // 10 seconds after the clock started: still not strictly over grace.
      var tAt10s = t.add(const Duration(seconds: 10));
      final off10 = offsetMeters(base, 50, 220);
      final u10 = follower.update(off10.$1, off10.$2, tAt10s);
      expect(u10.offRoute, isFalse);

      // 11 seconds after the clock started: grace period exceeded.
      var tAt11s = t.add(const Duration(seconds: 11));
      final off11 = offsetMeters(base, 50, 230);
      final u11 = follower.update(off11.$1, off11.$2, tAt11s);
      expect(u11.offRoute, isTrue);

      // A single fix back under threshold resets immediately.
      var tAfter = tAt11s.add(const Duration(seconds: 1));
      final backOnRoute = offsetMeters(base, 0, 240);
      final uBack = follower.update(backOnRoute.$1, backOnRoute.$2, tAfter);
      expect(uBack.crossTrackM, lessThan(30));
      expect(uBack.offRoute, isFalse);
    });
  });

  group('behavior 4: arrival requires proximity AND last maneuver, and latches', () {
    test('arrived stays false near destination until the last maneuver is active, then latches', () {
      // A loop-like route: leaves the start, and its final point ends up
      // close to the start again. An intermediate maneuver sits between
      // start and finish so maneuverIndex is not "last" at the very start.
      final a = (46.5200, 6.6300); // start
      final b = offsetMeters(a, 500, 0);
      final c = offsetMeters(a, 500, 500);
      final d = offsetMeters(a, 10, 10); // destination, ~14 m from `a`
      final shape = [a, b, c, d];
      final route =
          syntheticRoute(shape, [(0, 'Départ'), (1, 'Tournez'), (3, 'Arrivée')]);
      final follower = RouteFollower(route);
      var t = DateTime(2026, 1, 1);

      // At the very start: within 25 m of the destination geographically,
      // but the active maneuver is "Tournez", not the last one.
      final u0 = follower.update(a.$1, a.$2, t);
      expect(u0.maneuverIndex, 1);
      expect(u0.arrived, isFalse);

      // Progress to the actual destination.
      t = t.add(const Duration(seconds: 60));
      final u1 = follower.update(d.$1, d.$2, t);
      expect(u1.maneuverIndex, 2);
      expect(u1.arrived, isTrue);

      // Once arrived, it latches even if a later fix moves away again.
      t = t.add(const Duration(seconds: 1));
      final u2 = follower.update(a.$1, a.$2, t);
      expect(u2.arrived, isTrue);
    });
  });

  group('behavior 5: a single aberrant fix is reported but does not move progress', () {
    test('crossTrack > 200 m on one fix freezes alongKm/maneuverIndex, recovers after', () {
      final shape = <(double, double)>[
        for (var i = 0; i <= 5; i++) (46.5200 + i * 0.002, 6.6300),
      ];
      final route = syntheticRoute(shape, [(0, 'Départ'), (5, 'Arrivée')]);
      final follower = RouteFollower(route);
      var t = DateTime(2026, 1, 1);

      final good1 = shape[2];
      final u1 = follower.update(good1.$1, good1.$2, t);

      t = t.add(const Duration(seconds: 1));
      final aberrant = offsetMeters(good1, 250, 0);
      final u2 = follower.update(aberrant.$1, aberrant.$2, t);
      expect(u2.crossTrackM, greaterThan(200));
      expect(u2.alongKm, closeTo(u1.alongKm, 1e-9));
      expect(u2.maneuverIndex, u1.maneuverIndex);
      // Still within the off-route grace period on a single sample.
      expect(u2.offRoute, isFalse);

      t = t.add(const Duration(seconds: 1));
      final good2 = shape[4];
      final u3 = follower.update(good2.$1, good2.$2, t);
      expect(u3.crossTrackM, lessThan(30));
      expect(u3.alongKm, greaterThan(u1.alongKm));
    });
  });

  group('SpeedEstimator', () {
    test('speedMps is null until 3 samples, then follows the EMA', () {
      final estimator = SpeedEstimator(halfLife: 30);
      var t = DateTime(2026, 1, 1);
      estimator.add(2.0, t);
      expect(estimator.speedMps, isNull);

      t = t.add(const Duration(seconds: 10));
      estimator.add(2.0, t);
      expect(estimator.speedMps, isNull);

      t = t.add(const Duration(seconds: 10));
      estimator.add(2.0, t);
      expect(estimator.speedMps, closeTo(2.0, 0.01));
    });
  });

  group('RouteFollower ETA', () {
    test('eta becomes available once the internal speed estimator has 3 samples', () {
      final shape = <(double, double)>[
        for (var i = 0; i <= 5; i++) (46.5200 + i * 0.001, 6.6300),
      ];
      final route = syntheticRoute(shape, [(0, 'Départ'), (5, 'Arrivée')]);
      final geometry = RouteGeometry(shape);
      final follower = RouteFollower(route);
      var t = DateTime(2026, 1, 1);

      final u0 = follower.update(shape[0].$1, shape[0].$2, t);
      expect(u0.eta, isNull);

      t = t.add(const Duration(seconds: 10));
      final u1 = follower.update(shape[1].$1, shape[1].$2, t);
      expect(u1.eta, isNull);

      t = t.add(const Duration(seconds: 10));
      final u2 = follower.update(shape[2].$1, shape[2].$2, t);
      expect(u2.eta, isNull);

      t = t.add(const Duration(seconds: 10));
      final u3 = follower.update(shape[3].$1, shape[3].$2, t);
      expect(u3.eta, isNotNull);

      final speedMps = (geometry.cumulativeKm[1] - geometry.cumulativeKm[0]) * 1000 / 10;
      final expectedEtaSeconds = (geometry.totalKm - geometry.cumulativeKm[3]) * 1000 / speedMps;
      expect(u3.eta!.inSeconds, closeTo(expectedEtaSeconds, 2));
    });
  });
}
