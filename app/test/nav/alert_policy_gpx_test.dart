import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/nav/alert_policy.dart';
import 'package:randomwalk/nav/route_follower.dart';
import 'package:randomwalk/valhalla/models.dart';

import '../support/gpx.dart';
import '../support/make_fixtures.dart';

/// Replays the committed `nominal` GPX fixture (1 fix/second at 1.4 m/s —
/// see `make_fixtures.dart`) through a fresh [RouteFollower] built on the
/// shared reference route, exactly like `gpx_replay_test.dart`, then through
/// a fresh [AlertPolicy] for [profile] — returning, for each
/// `maneuverIndex`, the `distanceToManeuverM` of every tick [AlertPolicy]
/// judged alert-worthy for it (in encounter order).
///
/// This is the "rejeu GPX" the Task 2e brief asks for: a fixture dense
/// enough (~1.4 m between fixes) to tell a 20 m/8 m pinned pair apart from
/// the old, far coarser 80 m single threshold — a plain unit test on
/// synthetic [NavUpdate]s (see `alert_policy_test.dart`) already covers the
/// exact boundary logic, but this exercises the real distances a walker's
/// GPS actually produces approaching each of this route's three turns.
Map<int, List<double>> _replayAlerts(RoutingProfile profile) {
  final xml = File('test/nav/fixtures/nominal.gpx').readAsStringSync();
  final points = parseGpx(xml);
  final follower = RouteFollower(buildReferenceRoute());
  final policy = AlertPolicy(profile: profile);
  final alerts = <int, List<double>>{};
  for (final p in points) {
    final update = follower.update(p.lat, p.lon, p.time);
    if (policy.shouldAlert(update)) {
      alerts
          .putIfAbsent(update.maneuverIndex, () => [])
          .add(update.distanceToManeuverM);
    }
  }
  return alerts;
}

void main() {
  group('AlertPolicy against the nominal GPX fixture (Task 2e item 3)', () {
    test('walk profile: each turn gets a ~20 m alert then a ~8 m confirmation, '
        'never the old ~80 m distance', () {
      final alerts = _replayAlerts(RoutingProfile.walk);

      // The reference route's three turns (maneuverIndex 1, 2, 3 — index 0
      // is never published, index 4 is the arrival maneuver and goes
      // through AlertPolicy's separate `arrived` branch instead — see
      // make_fixtures.dart's own doc comment on the route's shape).
      for (final maneuverIndex in [1, 2, 3]) {
        final distances = alerts[maneuverIndex];
        expect(
          distances,
          isNotNull,
          reason: 'maneuver $maneuverIndex should have alerted at all',
        );
        expect(
          distances,
          hasLength(2),
          reason:
              'maneuver $maneuverIndex should fire exactly the 20 m alert '
              'plus the 8 m confirmation, not the old single ~80 m alert',
        );
        final [alertDistance, confirmDistance] = distances!;
        expect(alertDistance, lessThanOrEqualTo(kWalkAlertThresholdM));
        // Comfortably clear of the old 80 m threshold — pins the fix, not
        // just the exact boundary.
        expect(alertDistance, lessThan(30));
        expect(confirmDistance, lessThanOrEqualTo(kWalkConfirmThresholdM));
        expect(confirmDistance, lessThan(alertDistance));
      }

      // Arrival alerts once too, via its own branch — not counted above.
      expect(alerts[4], isNotEmpty);
    });

    test('bike profile: each turn gets exactly one alert, at the unchanged '
        '200 m distance — no confirmation stage', () {
      final alerts = _replayAlerts(RoutingProfile.bike);

      for (final maneuverIndex in [1, 2, 3]) {
        final distances = alerts[maneuverIndex];
        expect(
          distances,
          isNotNull,
          reason: 'maneuver $maneuverIndex should have alerted at all',
        );
        expect(
          distances,
          hasLength(1),
          reason:
              'bike keeps its single pre-existing alert, unchanged by '
              'the walking-only Task 2e fix',
        );
        expect(distances!.single, lessThanOrEqualTo(kBikeAlertThresholdM));
      }

      expect(alerts[4], isNotEmpty);
    });
  });
}
