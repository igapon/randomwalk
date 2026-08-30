import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/tracking/tracking_service.dart';
import 'package:randomwalk/tracking/trip_snapshot.dart';
import 'package:randomwalk/valhalla/models.dart';

TripSnapshot snapshot({
  TripStatus status = TripStatus.recording,
  double distanceKm = 2.4,
  int steps = 3100,
  int elapsedMinutes = 32,
}) =>
    TripSnapshot(
      status: status,
      distanceKm: distanceKm,
      steps: steps,
      startedAt: DateTime.utc(2026, 8, 30, 10, 0),
      updatedAt: DateTime.utc(2026, 8, 30, 10, 0).add(Duration(minutes: elapsedMinutes)),
      profile: RoutingProfile.walk,
      routeBound: false,
    );

void main() {
  group('notification text', () {
    test('reads as a sober one-liner in French formatting', () {
      expect(
        tripNotificationText(snapshot(), DateTime.utc(2026, 8, 30, 10, 32)),
        '2,4 km · 32 min',
      );
    });

    test('starts at zero rather than blank', () {
      expect(
        tripNotificationText(snapshot(distanceKm: 0),
            DateTime.utc(2026, 8, 30, 10, 0)),
        '0,0 km · 0 min',
      );
    });
  });

  group('resumePoint', () {
    test('a restarted service picks up the persisted progress, not the seed',
        () {
      // Android restarted the service mid-trip (allowAutoRestart): resuming
      // from the seed would reset 2.4 km to 0.
      final resumed = resumePoint(snapshot(distanceKm: 2.4),
          snapshot(distanceKm: 0, steps: 0, elapsedMinutes: 0));
      expect(resumed!.distanceKm, closeTo(2.4, 1e-9));
      expect(resumed.steps, 3100);
    });

    test('a first start with nothing on disk uses the seed', () {
      final seed = snapshot(distanceKm: 0, steps: 0);
      expect(resumePoint(null, seed), same(seed));
    });

    test('a finished trip left on disk does not resurrect itself', () {
      final seed = snapshot(distanceKm: 0, steps: 0);
      expect(resumePoint(snapshot(status: TripStatus.idle), seed), same(seed));
    });

    test('nothing to resume from at all yields nothing', () {
      expect(resumePoint(null, null), isNull);
    });
  });
}
