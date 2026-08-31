import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/nav/alert_policy.dart';
import 'package:randomwalk/nav/route_follower.dart';
import 'package:randomwalk/valhalla/models.dart';

/// A [NavUpdate] with only the fields [AlertPolicy] actually reads varied;
/// the rest are fixed, uninteresting values.
NavUpdate update({
  int maneuverIndex = 0,
  String instruction = 'Tournez à gauche',
  double distanceToManeuverM = 300,
  bool offRoute = false,
  bool arrived = false,
}) =>
    NavUpdate(
      snappedLat: 46.52,
      snappedLon: 6.63,
      alongKm: 0,
      remainingKm: 1,
      crossTrackM: 0,
      maneuverIndex: maneuverIndex,
      instruction: instruction,
      distanceToManeuverM: distanceToManeuverM,
      offRoute: offRoute,
      arrived: arrived,
    );

void main() {
  group('AlertPolicy — maneuver-approach crossing', () {
    test('does not alert while well short of the threshold', () {
      final policy = AlertPolicy(profile: RoutingProfile.walk);
      expect(policy.shouldAlert(update(distanceToManeuverM: 300)), isFalse);
      expect(policy.shouldAlert(update(distanceToManeuverM: 150)), isFalse);
    });

    test('walk profile alerts at 80 m', () {
      final policy = AlertPolicy(profile: RoutingProfile.walk);
      expect(policy.shouldAlert(update(distanceToManeuverM: 300)), isFalse);
      expect(policy.shouldAlert(update(distanceToManeuverM: 90)), isFalse);
      expect(policy.shouldAlert(update(distanceToManeuverM: 80)), isTrue);
    });

    test('bike profile alerts at 200 m, not at 90 m', () {
      final policy = AlertPolicy(profile: RoutingProfile.bike);
      expect(policy.shouldAlert(update(distanceToManeuverM: 300)), isFalse);
      // Within the bike threshold but would still be outside the walk one —
      // this is what actually distinguishes the two profiles.
      expect(policy.shouldAlert(update(distanceToManeuverM: 150)), isTrue);
    });

    test('a fix already inside the threshold alerts immediately', () {
      // The first-ever observation for a maneuver is itself the crossing:
      // there is no earlier fix to have been above threshold.
      final policy = AlertPolicy(profile: RoutingProfile.walk);
      expect(policy.shouldAlert(update(distanceToManeuverM: 40)), isTrue);
    });

    test('fires once per maneuver, not on every fix under threshold', () {
      final policy = AlertPolicy(profile: RoutingProfile.walk);
      expect(policy.shouldAlert(update(distanceToManeuverM: 70)), isTrue);
      expect(policy.shouldAlert(update(distanceToManeuverM: 60)), isFalse);
      expect(policy.shouldAlert(update(distanceToManeuverM: 20)), isFalse);
      // Even a GPS wobble pushing the distance back above threshold must not
      // re-arm the same maneuver.
      expect(policy.shouldAlert(update(distanceToManeuverM: 95)), isFalse);
    });

    test('re-arms once the maneuver index advances', () {
      final policy = AlertPolicy(profile: RoutingProfile.walk);
      expect(
          policy.shouldAlert(
              update(maneuverIndex: 0, distanceToManeuverM: 70)),
          isTrue);
      expect(
          policy.shouldAlert(
              update(maneuverIndex: 0, distanceToManeuverM: 10)),
          isFalse);

      // New maneuver, still under its own threshold from the first fix seen
      // for it.
      expect(
          policy.shouldAlert(
              update(maneuverIndex: 1, distanceToManeuverM: 75)),
          isTrue);
      expect(
          policy.shouldAlert(
              update(maneuverIndex: 1, distanceToManeuverM: 5)),
          isFalse);
    });
  });

  group('AlertPolicy — off-route', () {
    test('alerts once on the transition into off-route', () {
      final policy = AlertPolicy(profile: RoutingProfile.walk);
      expect(policy.shouldAlert(update(offRoute: false)), isFalse);
      expect(policy.shouldAlert(update(offRoute: true)), isTrue);
      // Still off-route on the next fix: no repeat.
      expect(policy.shouldAlert(update(offRoute: true)), isFalse);
    });

    test('re-alerts on a second, separate excursion off the route', () {
      final policy = AlertPolicy(profile: RoutingProfile.walk);
      expect(policy.shouldAlert(update(offRoute: true)), isTrue);
      expect(policy.shouldAlert(update(offRoute: false)), isFalse);
      expect(policy.shouldAlert(update(offRoute: true)), isTrue);
    });

    test('while off-route, a maneuver crossing underneath it does not also fire',
        () {
      final policy = AlertPolicy(profile: RoutingProfile.walk);
      expect(
          policy.shouldAlert(update(offRoute: true, distanceToManeuverM: 40)),
          isTrue);
      // The off-route alert already fired for this excursion; a maneuver
      // distance that would otherwise cross the threshold must not sneak a
      // second alert in on top of it.
      expect(
          policy.shouldAlert(update(offRoute: true, distanceToManeuverM: 10)),
          isFalse);
    });
  });

  group('AlertPolicy — arrival', () {
    test('alerts once on the transition into arrived', () {
      final policy = AlertPolicy(profile: RoutingProfile.walk);
      expect(policy.shouldAlert(update(arrived: false)), isFalse);
      expect(policy.shouldAlert(update(arrived: true)), isTrue);
      expect(policy.shouldAlert(update(arrived: true)), isFalse);
    });

    test('arrival outranks everything: no further alerts after it', () {
      final policy = AlertPolicy(profile: RoutingProfile.walk);
      expect(policy.shouldAlert(update(arrived: true)), isTrue);
      // Even if the walker now reads as off-route, or a new maneuver index
      // shows up (both odd once arrived, but not impossible), arrival has
      // already said everything there is to say.
      expect(
          policy.shouldAlert(update(
              arrived: true, offRoute: true, maneuverIndex: 1, distanceToManeuverM: 5)),
          isFalse);
    });
  });
}
