import 'dart:async';
import 'dart:math' show cos, pi;

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/nav/nav_fields.dart';
import 'package:randomwalk/nav/navigation_runtime.dart';
import 'package:randomwalk/nav/polyline_math.dart';
import 'package:randomwalk/nav/route_follower.dart';
import 'package:randomwalk/valhalla/models.dart';

/// A straight 11-point line running north from (46.52, 6.63 + [lonOffset]),
/// ~110 m between points (~1.1 km total), with three maneuvers: départ, a
/// turn at vertex 4, and arrival at the final vertex.
RouteResult straightRoute({double lonOffset = 0, String turn = 'Rue du Lac'}) {
  final shape = <(double, double)>[
    for (var i = 0; i <= 10; i++) (46.5200 + i * 0.001, 6.6300 + lonOffset),
  ];
  return RouteResult(
    shape: shape,
    distanceKm: RouteGeometry(shape).totalKm,
    duration: const Duration(minutes: 15),
    maneuvers: [
      const Maneuver(instruction: 'Départ', lengthKm: 0, beginShapeIndex: 0),
      Maneuver(instruction: turn, lengthKm: 0, beginShapeIndex: 4),
      const Maneuver(instruction: 'Arrivée', lengthKm: 0, beginShapeIndex: 10),
    ],
  );
}

/// The east offset, in degrees of longitude, of [meters] at [lat] — the same
/// equirectangular approximation the route geometry uses internally.
double eastDegrees(double lat, double meters) =>
    meters / (111320.0 * cos(lat * pi / 180));

(double, double) eastOf((double, double) p, double meters) =>
    (p.$1, p.$2 + eastDegrees(p.$1, meters));

/// A stand-in for the service's `engine.route(...)` call: records every
/// origin it was asked about, answers from a queue of results, and can be
/// held open (see [gate]) to model a slow round trip to Valhalla.
class FakeReplan {
  final List<RouteResult?> answers;
  final origins = <(double, double)>[];
  Completer<void>? gate;

  FakeReplan(this.answers);

  int get calls => origins.length;

  Future<RouteResult?> call(double lat, double lon) async {
    origins.add((lat, lon));
    final open = gate;
    if (open != null) await open.future;
    return answers.isEmpty ? null : answers.removeAt(0);
  }
}

void main() {
  final start = DateTime.utc(2026, 8, 30, 10, 0, 0);

  group('NavigationRuntime', () {
    late DateTime clock;
    late RouteResult planned;

    setUp(() {
      clock = start;
      planned = straightRoute();
    });

    NavigationRuntime runtime(FakeReplan replan) => NavigationRuntime(
          follower: RouteFollower(planned),
          replan: replan.call,
          now: () => clock,
        );

    /// The route's own vertex [i], and a point 60 m east of it — well past
    /// the 30 m off-route threshold, well short of the 200 m spike threshold.
    (double, double) on(int i) => planned.shape[i];
    (double, double) off(int i) => eastOf(planned.shape[i], 60);

    Future<NavFields> fixAt(
        NavigationRuntime nav, (double, double) p, int seconds) {
      clock = start.add(Duration(seconds: seconds));
      return nav.onFix(p.$1, p.$2, 1.4, clock);
    }

    test('follows the seeded route and reports its shape from the first fix',
        () async {
      final replan = FakeReplan([]);
      final nav = runtime(replan);

      final fields = await fixAt(nav, on(2), 0);

      expect(replan.calls, 0);
      expect(fields.instruction, 'Rue du Lac');
      expect(fields.offRoute, isFalse);
      expect(fields.arrived, isFalse);
      expect(fields.replanCount, 0);
      expect(fields.degraded, isFalse);
      expect(fields.routeShapeEnc, encodePolyline6(planned.shape));
      expect(fields.remainingKm, closeTo(planned.distanceKm - 0.221, 0.01));
      expect(fields.distanceToManeuverM, closeTo(221, 5));
    });

    test('lastUpdate exposes the raw follower update behind the fields',
        () async {
      final replan = FakeReplan([]);
      final nav = runtime(replan);

      expect(nav.lastUpdate, isNull);
      final fields = await fixAt(nav, on(2), 0);

      expect(nav.lastUpdate, isNotNull);
      expect(nav.lastUpdate!.maneuverIndex, 1);
      expect(nav.lastUpdate!.distanceToManeuverM, fields.distanceToManeuverM);
    });

    test('an off-route walker triggers exactly one replan onto a fresh route',
        () async {
      final replacement = straightRoute(
          lonOffset: eastDegrees(46.52, 60), turn: 'Chemin de Bellerive');
      final replan = FakeReplan([replacement]);
      final nav = runtime(replan);

      await fixAt(nav, on(1), 0);
      // Off the route, but inside the follower's 10 s grace: still nothing.
      await fixAt(nav, off(2), 5);
      expect(replan.calls, 0);

      final fields = await fixAt(nav, off(2), 20);

      expect(replan.calls, 1);
      expect(replan.origins.single.$1, closeTo(off(2).$1, 1e-9));
      expect(replan.origins.single.$2, closeTo(off(2).$2, 1e-9));
      // The fields describe the *new* route, read from a fresh follower:
      // RouteFollower deliberately cannot recover from a large divergence on
      // its own, so a replan must never reuse the old one.
      expect(fields.replanCount, 1);
      expect(fields.instruction, 'Chemin de Bellerive');
      expect(fields.routeShapeEnc, encodePolyline6(replacement.shape));
      expect(fields.offRoute, isFalse);
      expect(fields.degraded, isFalse);
      // offRoute itself is honestly false — the fresh follower really does
      // read the walker as on the new line — but this tick did leave the
      // old route, and replanning is what still says so (final review item
      // 5: without it, a *successful* same-tick replan is invisible to the
      // off-route alert and the "Recalcul…" card, which only ever saw a
      // failed one).
      expect(fields.replanning, isTrue);
    });

    test('a divergence big enough to look like a GPS spike still replans',
        () async {
      // Beyond 200 m the follower treats a fix as multipath and freezes
      // progress on it — but it is still evidence of being off the route,
      // and a walker who has taken a different street entirely is exactly
      // the walker who most needs a new one. This is the path that would
      // strand a trip if the runtime kept feeding the old follower.
      final replacement = straightRoute(
          lonOffset: eastDegrees(46.52, 250), turn: 'Route de Berne');
      final replan = FakeReplan([replacement]);
      final nav = runtime(replan);
      (double, double) far(int i) => eastOf(planned.shape[i], 250);

      await fixAt(nav, on(1), 0);
      final spike = await fixAt(nav, far(2), 5);
      expect(spike.offRoute, isFalse, reason: 'still inside the grace');
      expect(replan.calls, 0);

      final fields = await fixAt(nav, far(2), 20);

      expect(replan.calls, 1);
      expect(fields.replanCount, 1);
      expect(fields.instruction, 'Route de Berne');
      expect(fields.routeShapeEnc, encodePolyline6(replacement.shape));
      expect(fields.offRoute, isFalse,
          reason: 'the fresh follower has the walker on the new line');
      // Same distinction as the previous test: offRoute is honestly false,
      // but replanning still says this tick recalculated onto a new route
      // (final review item 5).
      expect(fields.replanning, isTrue);
    });

    test('no second replan starts while one is in flight', () async {
      final replacement = straightRoute(lonOffset: eastDegrees(46.52, 60));
      final replan = FakeReplan([replacement])..gate = Completer<void>();
      final nav = runtime(replan);

      await fixAt(nav, on(1), 0);
      await fixAt(nav, off(2), 5);

      clock = start.add(const Duration(seconds: 20));
      final first = nav.onFix(off(2).$1, off(2).$2, 1.4, clock);
      await pumpEventQueue();
      expect(replan.calls, 1);

      final second = await fixAt(nav, off(3), 22);

      // The in-flight guard, not the retry backoff: the second fix is
      // answered from the route still being followed rather than queueing a
      // duplicate round trip to Valhalla.
      expect(replan.calls, 1);
      expect(second.replanCount, 0);
      expect(second.offRoute, isTrue);
      // A replan is genuinely in flight (the first fix's), even though this
      // second call did not start it.
      expect(second.replanning, isTrue);

      replan.gate!.complete();
      expect((await first).replanCount, 1);
    });

    test('a replan that fails keeps the old route and is not retried for 30 s',
        () async {
      final replan = FakeReplan([null, null]);
      final nav = runtime(replan);

      await fixAt(nav, on(1), 0);
      await fixAt(nav, off(2), 5);
      final failed = await fixAt(nav, off(2), 20);

      expect(replan.calls, 1);
      expect(failed.degraded, isTrue);
      expect(failed.replanCount, 0);
      expect(failed.offRoute, isTrue);
      // A replan was attempted this tick (it just failed) — offRoute alone
      // already covers alerting for this case, but replanning is set
      // regardless of outcome.
      expect(failed.replanning, isTrue);
      // Still following the planned route — a walker out of tile coverage is
      // better served by a stale line than by nothing at all.
      expect(failed.instruction, 'Rue du Lac');
      expect(failed.routeShapeEnc, encodePolyline6(planned.shape));

      await fixAt(nav, off(3), 45);
      expect(replan.calls, 1, reason: 'inside the 30 s retry window');

      final retried = await fixAt(nav, off(3), 51);
      expect(replan.calls, 2);
      expect(retried.degraded, isTrue);
    });

    test('a replan answering with an unusable route counts as a failure',
        () async {
      final replan = FakeReplan([
        const RouteResult(
            shape: [(46.52, 6.63)],
            distanceKm: 0,
            duration: Duration.zero,
            maneuvers: []),
      ]);
      final nav = runtime(replan);

      await fixAt(nav, on(1), 0);
      await fixAt(nav, off(2), 5);
      final fields = await fixAt(nav, off(2), 20);

      expect(fields.degraded, isTrue);
      expect(fields.replanCount, 0);
      expect(fields.routeShapeEnc, encodePolyline6(planned.shape));
    });

    test('a replan that throws is a failure, not a crashed trip', () async {
      var calls = 0;
      final nav = NavigationRuntime(
        follower: RouteFollower(planned),
        replan: (lat, lon) async {
          calls++;
          throw Exception('no routing engine in this isolate');
        },
        now: () => clock,
      );

      await fixAt(nav, on(1), 0);
      await fixAt(nav, off(2), 5);
      final fields = await fixAt(nav, off(2), 20);

      expect(calls, 1);
      expect(fields.degraded, isTrue);
      expect(fields.instruction, 'Rue du Lac');
    });

    test('getting back on the route clears the degraded flag', () async {
      final replan = FakeReplan([null]);
      final nav = runtime(replan);

      await fixAt(nav, on(1), 0);
      await fixAt(nav, off(2), 5);
      expect((await fixAt(nav, off(2), 20)).degraded, isTrue);

      final back = await fixAt(nav, on(3), 25);
      expect(back.degraded, isFalse);
      expect(back.offRoute, isFalse);
    });

    test('arrival stops triggering replans', () async {
      final replan = FakeReplan([straightRoute()]);
      final nav = runtime(replan);

      for (var i = 0; i <= 10; i++) {
        await fixAt(nav, on(i), i * 10);
      }
      // Wandering away from a route that has already been completed is not a
      // wrong turn, and must not spend a Valhalla round trip.
      for (final seconds in [120, 140, 160]) {
        final fields = await fixAt(nav, off(9), seconds);
        expect(fields.arrived, isTrue);
      }
      expect(replan.calls, 0);
    });

    test('the pace estimate survives a replan, so the ETA never blanks out',
        () async {
      final replacement = straightRoute(lonOffset: eastDegrees(46.52, 60));
      final replan = FakeReplan([replacement]);
      final nav = runtime(replan);

      // Four on-route fixes at ~1.4 m/s: enough for the estimator's
      // three-sample minimum.
      NavFields? last;
      for (var i = 0; i <= 3; i++) {
        last = await fixAt(nav, on(i), i * 80);
      }
      expect(last!.etaSeconds, isNotNull);

      await fixAt(nav, off(4), 320);
      final fields = await fixAt(nav, off(4), 340);
      expect(fields.replanCount, 1);
      expect(fields.etaSeconds, isNotNull,
          reason: 'a fresh follower must inherit the speed estimator');
    });

    group('isLoop (final review item 1)', () {
      NavigationRuntime loopRuntime(FakeReplan replan) => NavigationRuntime(
            follower: RouteFollower(planned),
            replan: replan.call,
            now: () => clock,
            isLoop: true,
          );

      test('an off-route loop is never replanned, but still reads off-route',
          () async {
        // The bug this pins: a loop's ActiveRoute carries no destination, so
        // the seed's dest falls back to the shape's last point — which, for a
        // closed loop, *is* the start. Replanning there hands the walker
        // "the shortest way home", arrival fires, and the loop is destroyed.
        final replan = FakeReplan([straightRoute(lonOffset: eastDegrees(46.52, 60))]);
        final nav = loopRuntime(replan);

        await fixAt(nav, on(1), 0);
        await fixAt(nav, off(2), 5);
        final fields = await fixAt(nav, off(2), 20);

        expect(replan.calls, 0, reason: 'a loop must never be recalculated');
        expect(fields.offRoute, isTrue,
            reason: 'the walker still needs to be told they left the line');
        expect(fields.replanning, isFalse,
            reason: 'nothing is being recalculated, so no « Recalcul… »');
        expect(fields.degraded, isFalse,
            reason: 'not replanning is by design here, not a failure');
        expect(fields.replanCount, 0);
        // Still following the planned loop, unchanged.
        expect(fields.routeShapeEnc, encodePolyline6(planned.shape));
        expect(nav.route, same(planned));
      });

      test('staying off-route never accumulates replan attempts', () async {
        final replan = FakeReplan([]);
        final nav = loopRuntime(replan);

        await fixAt(nav, on(1), 0);
        for (final seconds in [5, 20, 60, 120, 300]) {
          final fields = await fixAt(nav, off(2), seconds);
          expect(fields.replanning, isFalse);
        }
        expect(replan.calls, 0,
            reason: 'the retry window must not open a loophole either');
      });

      test('rejoining the loop resumes ordinary guidance', () async {
        final replan = FakeReplan([]);
        final nav = loopRuntime(replan);

        await fixAt(nav, on(1), 0);
        // The off-route clock starts on the *first* off-route fix; the second,
        // past the 10 s grace, is what latches it.
        await fixAt(nav, off(2), 5);
        expect((await fixAt(nav, off(2), 20)).offRoute, isTrue);

        final back = await fixAt(nav, on(3), 30);
        expect(back.offRoute, isFalse);
        expect(back.instruction, 'Rue du Lac');
        expect(replan.calls, 0);
      });

      test('defaults to false, so an A→B trip still replans', () async {
        final replan = FakeReplan([straightRoute(lonOffset: eastDegrees(46.52, 60))]);
        final nav = runtime(replan);

        await fixAt(nav, on(1), 0);
        await fixAt(nav, off(2), 5);
        await fixAt(nav, off(2), 20);

        expect(replan.calls, 1);
      });
    });
  });

  group('navNotificationText', () {
    NavFields fields({
      String? instruction = 'Rue de Bourg',
      double? distanceToManeuverM = 120,
      double? remainingKm = 2.4,
      int? etaSeconds = 32 * 60,
      bool offRoute = false,
      bool arrived = false,
      bool degraded = false,
    }) =>
        NavFields(
          instruction: instruction,
          distanceToManeuverM: distanceToManeuverM,
          remainingKm: remainingKm,
          etaSeconds: etaSeconds,
          offRoute: offRoute,
          arrived: arrived,
          degraded: degraded,
          replanCount: 0,
          routeShapeEnc: null,
        );

    test('reads as two lines: the next turn, then the trip left to go', () {
      expect(navNotificationText(fields()),
          '↰ Rue de Bourg · 100 m\n2,4 km · 32 min');
    });

    test('rounds to 10 m below 100 m and to 50 m above it', () {
      expect(navNotificationText(fields(distanceToManeuverM: 84)),
          startsWith('↰ Rue de Bourg · 80 m'));
      expect(navNotificationText(fields(distanceToManeuverM: 96)),
          startsWith('↰ Rue de Bourg · 100 m'));
      expect(navNotificationText(fields(distanceToManeuverM: 137)),
          startsWith('↰ Rue de Bourg · 150 m'));
      expect(navNotificationText(fields(distanceToManeuverM: 1420)),
          startsWith('↰ Rue de Bourg · 1,4 km'));
    });

    test('a lost route says so instead of pointing at a turn', () {
      expect(
        navNotificationText(fields(offRoute: true, degraded: true)),
        'Itinéraire perdu — revenez sur le tracé\n2,4 km · 32 min',
      );
    });

    test('arrival wins over everything else', () {
      expect(
        navNotificationText(
            fields(arrived: true, offRoute: true, degraded: true)),
        startsWith('Arrivé à destination'),
      );
    });

    test('an ETA the estimator will not commit to is simply left out', () {
      expect(navNotificationText(fields(etaSeconds: null)),
          '↰ Rue de Bourg · 100 m\n2,4 km');
    });

    test('a route with no instruction still says what to do', () {
      expect(navNotificationText(fields(instruction: null)),
          startsWith("Suivez l'itinéraire · 100 m"));
      expect(navNotificationText(fields(instruction: '')),
          startsWith("Suivez l'itinéraire · 100 m"));
    });

    test('a snapshot with no nav progress yet falls back to one line', () {
      expect(
        navNotificationText(fields(
            instruction: null,
            distanceToManeuverM: null,
            remainingKm: null,
            etaSeconds: null)),
        "Suivez l'itinéraire",
      );
    });
  });
}
