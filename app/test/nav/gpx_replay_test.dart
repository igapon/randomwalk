import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/nav/route_follower.dart';

import '../support/gpx.dart';
import '../support/make_fixtures.dart';

/// Reads a committed fixture (relative to the package root, which is where
/// `flutter test` always sets its working directory) and replays it through
/// a fresh [RouteFollower] built on the shared reference route.
List<NavUpdate> _replay(String fixtureName) {
  final xml = File('test/nav/fixtures/$fixtureName.gpx').readAsStringSync();
  final points = parseGpx(xml);
  final follower = RouteFollower(buildReferenceRoute());
  return [for (final p in points) follower.update(p.lat, p.lon, p.time)];
}

/// Slack allowed on top of a strict decrease in `distanceToManeuverM`
/// between two fixes still approaching the same maneuver (final review item
/// 7 — the old check allowed up to +0.5 m of *increase*, loose enough to
/// hide a genuine regression). Zero: the `nominal` fixture walks the route
/// exactly, with no GPS jitter, and against it a fully strict decrease
/// (`lessThan(prev)`, no slack at all) passes cleanly — tried first per the
/// review's own fallback instruction ("keep the smallest slack that
/// passes"), and the smallest slack that passes turned out to be none.
/// Revisit if this ever starts flaking against a regenerated fixture — see
/// `../support/make_fixtures.dart`.
const _kManeuverEpsilonM = 0.0;

void main() {
  final route = buildReferenceRoute();

  group('nominal fixture', () {
    test(
      'never off-route, arrives, maneuvers advance in order through all 4',
      () {
        final updates = _replay('nominal');

        expect(
          updates.any((u) => u.offRoute),
          isFalse,
          reason:
              'a fix walked exactly on the route should never read as off-route',
        );
        expect(updates.last.arrived, isTrue);

        // RouteFollower never (re-)publishes maneuverIndex 0 once any fix has
        // been processed — index 0 sits at alongKm 0, never "strictly ahead"
        // of a non-negative alongKm (see route_follower_test.dart's "behavior
        // 4"). With 5 maneuvers (depart + 3 turns + arrival) the four
        // reachable published indices are 1..4.
        final seen = <int>{};
        var prevIndex = updates.first.maneuverIndex;
        for (final u in updates) {
          expect(
            u.maneuverIndex,
            greaterThanOrEqualTo(prevIndex),
            reason: 'published maneuverIndex must never regress',
          );
          prevIndex = u.maneuverIndex;
          seen.add(u.maneuverIndex);
        }
        expect(seen, {1, 2, 3, 4});
        expect(updates.last.maneuverIndex, route.maneuvers.length - 1);

        // Within each maneuver, distanceToManeuverM should count down as the
        // walker heads straight toward it on an unjittered trace — a strict
        // decrease, not merely "not much of an increase". [_kManeuverEpsilonM]
        // is the smallest slack that still passes against this fixture; see
        // its doc comment for why it is not exactly zero.
        for (var i = 1; i < updates.length; i++) {
          if (updates[i].maneuverIndex == updates[i - 1].maneuverIndex) {
            expect(
              updates[i].distanceToManeuverM,
              lessThan(updates[i - 1].distanceToManeuverM + _kManeuverEpsilonM),
              reason:
                  'distanceToManeuverM should strictly decrease while '
                  'approaching maneuver ${updates[i].maneuverIndex}',
            );
          }
        }
      },
    );
  });

  group('jitter fixture', () {
    test(
      'never off-route despite ±8 m noise, arrives, total progress ≈ route length',
      () {
        final updates = _replay('jitter');

        expect(
          updates.any((u) => u.offRoute),
          isFalse,
          reason:
              '±8 m gaussian noise should stay well clear of the 30 m '
              'off-route threshold for any continuous 10 s stretch',
        );
        expect(updates.last.arrived, isTrue);

        final totalKm = route.distanceKm;
        expect(updates.last.alongKm, closeTo(totalKm, totalKm * 0.1));
      },
    );
  });

  group('detour fixture', () {
    test(
      'off-route triggers 10-20s after first exceeding 30m, clears on rejoin, arrives',
      () {
        final updates = _replay('detour');

        final firstExceedIndex = updates.indexWhere((u) => u.crossTrackM > 30);
        expect(
          firstExceedIndex,
          greaterThanOrEqualTo(0),
          reason: 'the detour fixture should actually leave the route',
        );

        final firstOffRouteIndex = updates.indexWhere((u) => u.offRoute);
        expect(firstOffRouteIndex, greaterThan(firstExceedIndex));

        final points = parseGpx(
          File('test/nav/fixtures/detour.gpx').readAsStringSync(),
        );
        final delay = points[firstOffRouteIndex].time.difference(
          points[firstExceedIndex].time,
        );
        expect(delay.inSeconds, greaterThanOrEqualTo(10));
        expect(delay.inSeconds, lessThanOrEqualTo(20));

        // Falls back to false again after rejoining the route, and stays
        // clear through to arrival.
        final laterFalseIndex = updates.indexWhere(
          (u) => !u.offRoute,
          firstOffRouteIndex + 1,
        );
        expect(laterFalseIndex, greaterThan(firstOffRouteIndex));
        expect(updates.skip(laterFalseIndex).any((u) => u.offRoute), isFalse);

        expect(updates.last.arrived, isTrue);
      },
    );
  });

  group('tunnel fixture', () {
    test(
      'no false arrival during the gap; resumes cleanly with a forward alongKm jump',
      () {
        final points = parseGpx(
          File('test/nav/fixtures/tunnel.gpx').readAsStringSync(),
        );
        final follower = RouteFollower(route);
        final updates = <NavUpdate>[];
        for (final p in points) {
          updates.add(follower.update(p.lat, p.lon, p.time));
        }

        // Locate the gap: the largest interval between consecutive fixes.
        var gapIndex = 0;
        var gapDuration = Duration.zero;
        for (var i = 1; i < points.length; i++) {
          final dt = points[i].time.difference(points[i - 1].time);
          if (dt > gapDuration) {
            gapDuration = dt;
            gapIndex = i;
          }
        }
        expect(
          gapDuration.inSeconds,
          greaterThanOrEqualTo(45),
          reason: 'the tunnel fixture should contain a genuine ~45s gap',
        );

        // No arrival latched anywhere up to and including the resumed fix
        // after the gap — `sublist(0, gapIndex)` alone excludes
        // `updates[gapIndex]` itself, the exact fix whose forward alongKm
        // jump (checked below) is the one most likely to spuriously cross
        // the arrival radius; `gapIndex + 1` brings it into the window.
        expect(updates.sublist(0, gapIndex + 1).any((u) => u.arrived), isFalse);

        // alongKm jumps forward across the gap by roughly the distance a
        // walker at 1.4 m/s would cover during the missing time, not just one
        // ordinary 1-second step.
        final before = updates[gapIndex - 1];
        final after = updates[gapIndex];
        final jumpM = (after.alongKm - before.alongKm) * 1000;
        expect(
          jumpM,
          greaterThan(20),
          reason:
              'resuming after the gap should advance well beyond a '
              'single normal update step',
        );

        // The trace stays exactly on the route throughout (no jitter), so
        // there is no off-route flapping at all around the gap.
        expect(updates[gapIndex - 1].offRoute, isFalse);
        expect(updates[gapIndex].offRoute, isFalse);

        expect(updates.last.arrived, isTrue);
      },
    );
  });
}
