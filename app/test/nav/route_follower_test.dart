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

      // Genuinely out on the loop (near `c`, ~693 m from `d`) — this is what
      // establishes the task-8 "left the destination's vicinity at least
      // once" latch (`_leftArrivalRadius`) honestly, rather than the
      // start-to-destination jump alone (only ~14 m, see `d`'s comment).
      t = t.add(const Duration(seconds: 30));
      final u0b = follower.update(c.$1, c.$2, t);
      expect(u0b.arrived, isFalse);

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

    group('arrival requires actual progress (final review item 5)', () {
      test('a closed loop with no maneuvers does not arrive at its departure',
          () {
        // The regression: `isLastManeuver` is *true* from the first fix for a
        // route with no maneuvers at all (and for one whose last maneuver
        // begins at index 0), and a closed loop's start is by definition
        // within the arrival radius of its end. The walker's very first fix
        // therefore latched "Arrivé !" before they had taken a step, killing
        // the trip — the same coincidence a replan onto a 2-point route to
        // the loop's own start used to produce (see NavigationRuntime.isLoop).
        final a = (46.5200, 6.6300);
        final shape = [
          a,
          offsetMeters(a, 800, 0),
          offsetMeters(a, 800, 800),
          offsetMeters(a, 0, 800),
          a, // closes on the departure
        ];
        final route = syntheticRoute(shape, const []);
        final follower = RouteFollower(route);
        var t = DateTime(2026, 1, 1);

        final u0 = follower.update(a.$1, a.$2, t);
        expect(u0.arrived, isFalse,
            reason: 'standing at the start of a loop is not arriving');

        // A couple of metres in — still nowhere near having walked the loop.
        t = t.add(const Duration(seconds: 2));
        final crawl = offsetMeters(a, 3, 0);
        expect(follower.update(crawl.$1, crawl.$2, t).arrived, isFalse);

        // Genuinely out on the loop, ~1.1 km from the departure — this is
        // what honestly establishes the task-8 "left the destination's
        // vicinity at least once" latch (`_leftArrivalRadius`), rather than
        // the crawl-to-home jump alone (both within a few metres of `a`).
        t = t.add(const Duration(minutes: 10));
        final farCorner = offsetMeters(a, 800, 800);
        expect(follower.update(farCorner.$1, farCorner.$2, t).arrived, isFalse);

        // All the way round, back to the departure: now it really is arrival.
        t = t.add(const Duration(minutes: 20));
        final home = offsetMeters(a, 2, 2);
        expect(follower.update(home.$1, home.$2, t).arrived, isTrue);
      });

      test('a single-maneuver A→B route still arrives normally', () {
        // The guard must not cost an ordinary route its arrival: the progress
        // floor is a fraction of the route, so any route actually walked to
        // its end clears it.
        final a = (46.5200, 6.6300);
        final shape = [a, offsetMeters(a, 0, 400)];
        final route = syntheticRoute(shape, [(0, 'Départ'), (1, 'Arrivée')]);
        final follower = RouteFollower(route);
        var t = DateTime(2026, 1, 1);

        expect(follower.update(a.$1, a.$2, t).arrived, isFalse);
        t = t.add(const Duration(minutes: 5));
        final end = offsetMeters(a, 0, 400);
        expect(follower.update(end.$1, end.$2, t).arrived, isTrue);
      });

      test('a degenerate route shorter than the arrival radius still arrives',
          () {
        // The floor is the *smaller* of the two bounds by construction, so a
        // route too short for the absolute one cannot become unarrivable —
        // it just needs to be walked (nearly) end to end.
        final a = (46.5200, 6.6300);
        final shape = [a, offsetMeters(a, 0, 12)];
        final route = syntheticRoute(shape, [(0, 'Départ'), (1, 'Arrivée')]);
        final follower = RouteFollower(route);
        var t = DateTime(2026, 1, 1);

        expect(follower.update(a.$1, a.$2, t).arrived, isFalse);
        t = t.add(const Duration(seconds: 20));
        final end = offsetMeters(a, 0, 12);
        expect(follower.update(end.$1, end.$2, t).arrived, isTrue);
      });

      test(
          'switchback near the start does not arrive; the real, far-away end still does '
          '(task-8 backlog item 1)', () {
        // A loop with a short out-and-back right after departure: it goes
        // 40 m out (p1) and back to within ~7 m of the start (p2) — well
        // inside arrivalRadiusM (25 m) — *before* heading out on the real
        // loop (p3, ~990 m away) and closing back on the start (== end).
        //
        // The switchback alone already walks 40 + 35.4 ≈ 75 m of path,
        // which clears [_minProgressForArrivalKm]'s floor (≈41 m for this
        // route) on its own — so the progress floor from final review
        // item 5 is *not* enough here: without [_leftArrivalRadius], `p2`
        // would satisfy every other arrival condition (last maneuver — none
        // exist — within arrivalRadiusM of the end, and past the progress
        // floor) despite the walker having physically gone nowhere. Only
        // having genuinely left the destination's vicinity (reaching `p3`,
        // 990 m away) may unlatch arrival at the real end.
        final a = (46.5200, 6.6300);
        final p1 = offsetMeters(a, 40, 0);
        final p2 = offsetMeters(a, 5, 5);
        final p3 = offsetMeters(a, 700, 700);
        final shape = [a, p1, p2, p3, a];
        final route = syntheticRoute(shape, const []);
        final follower = RouteFollower(route);
        var t = DateTime(2026, 1, 1);

        // Back near the start after the switchback: NOT arrived, despite
        // being within arrivalRadiusM and past the progress floor.
        final uSwitchback = follower.update(p2.$1, p2.$2, t);
        expect(uSwitchback.arrived, isFalse);

        // Genuinely out on the loop, ~990 m from the start/end.
        t = t.add(const Duration(minutes: 10));
        final uFar = follower.update(p3.$1, p3.$2, t);
        expect(uFar.arrived, isFalse);

        // Back at the real end, now having genuinely left and returned. Uses
        // a point a few metres short of `a` along the closing segment
        // (p3 -> a), not the exact vertex `a` itself: `a` is also segment 0's
        // *start* (a -> p1), so a fix landing exactly on it ties between
        // "just departed" (alongKm ~= 0) and "just arrived" (alongKm ~=
        // total) — an ambiguity real GPS noise never lands on exactly
        // either, and orthogonal to what this test is about.
        t = t.add(const Duration(minutes: 10));
        final nearEnd = offsetMeters(a, 7, 7);
        final uEnd = follower.update(nearEnd.$1, nearEnd.$2, t);
        expect(uEnd.arrived, isTrue);
      });
    });
  });

  group('published maneuverIndex is monotonic despite GPS wobble', () {
    test('a backward wobble right after passing a maneuver does not revert the instruction', () {
      // Départ / Tournez / Continuez tout droit / Arrivée, so there is a
      // non-final maneuver transition to wobble across.
      final shape = <(double, double)>[
        for (var i = 0; i <= 10; i++) (46.5200 + i * 0.001, 6.6300),
      ];
      final route = syntheticRoute(shape,
          [(0, 'Départ'), (4, 'Tournez'), (6, 'Continuez tout droit'), (9, 'Arrivée')]);
      final follower = RouteFollower(route);
      var t = DateTime(2026, 1, 1);

      // Past maneuver "Tournez" (index 4), before "Continuez tout droit"'s
      // own position (index 6): the active maneuver is "Continuez tout
      // droit".
      final u1 = follower.update(shape[5].$1, shape[5].$2, t);
      expect(u1.instruction, 'Continuez tout droit');

      // GPS wobble drops the fix back near index 3, within the follower's
      // -2 segment search tolerance. alongKm is allowed to wobble backward
      // by design...
      t = t.add(const Duration(seconds: 1));
      final u2 = follower.update(shape[3].$1, shape[3].$2, t);
      expect(u2.alongKm, lessThan(u1.alongKm));

      // ...but the *published* maneuverIndex/instruction must not revert to
      // the maneuver we already passed.
      expect(u2.maneuverIndex, u1.maneuverIndex);
      expect(u2.instruction, 'Continuez tout droit');
    });
  });

  group('ETA safety', () {
    test('eta goes null after the estimator decays to a near-stationary speed', () {
      final shape = <(double, double)>[
        for (var i = 0; i <= 5; i++) (46.5200 + i * 0.001, 6.6300),
      ];
      final route = syntheticRoute(shape, [(0, 'Départ'), (5, 'Arrivée')]);
      final follower = RouteFollower(route);
      var t = DateTime(2026, 1, 1);

      // Establish a brisk ~11 m/s speed estimate (3 samples).
      follower.update(shape[0].$1, shape[0].$2, t);
      t = t.add(const Duration(seconds: 10));
      follower.update(shape[1].$1, shape[1].$2, t);
      t = t.add(const Duration(seconds: 10));
      follower.update(shape[2].$1, shape[2].$2, t);
      t = t.add(const Duration(seconds: 10));
      final moving = follower.update(shape[3].$1, shape[3].$2, t);
      expect(moving.eta, isNotNull);

      // Now stop moving (a coffee break): repeated fixes at the same spot,
      // 60 s apart, decay the EMA toward zero.
      Duration? lastEta;
      for (var i = 0; i < 4; i++) {
        t = t.add(const Duration(seconds: 60));
        final stationary = follower.update(shape[3].$1, shape[3].$2, t);
        lastEta = stationary.eta;
      }

      expect(lastEta, isNull);
    });

    test('eta is capped at 24h and never negative for a long remaining distance at low speed', () {
      final base = (46.5200, 6.6300);
      // A single ~44 km segment, far longer than is reachable in 24h at the
      // very slow speed established below.
      final shape = <(double, double)>[base, (46.9200, 6.6300)];
      final route = syntheticRoute(shape, [(0, 'Départ'), (1, 'Arrivée')]);
      final follower = RouteFollower(route);
      var t = DateTime(2026, 1, 1);

      // 0.35 m/s, constant, so the EMA settles exactly there after 3 samples.
      follower.update(base.$1, base.$2, t);
      t = t.add(const Duration(seconds: 10));
      final p1 = offsetMeters(base, 0, 3.5);
      follower.update(p1.$1, p1.$2, t);
      t = t.add(const Duration(seconds: 10));
      final p2 = offsetMeters(base, 0, 7.0);
      follower.update(p2.$1, p2.$2, t);
      t = t.add(const Duration(seconds: 10));
      final p3 = offsetMeters(base, 0, 10.5);
      final u = follower.update(p3.$1, p3.$2, t);

      expect(u.eta, isNotNull);
      expect(u.eta!.isNegative, isFalse);
      expect(u.eta, const Duration(hours: 24));
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
