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

  group('isGpsSilent', () {
    final since = DateTime.utc(2026, 8, 30, 10, 0);

    test('a fix a moment ago is not silence', () {
      expect(
        isGpsSilent(
            now: DateTime.utc(2026, 8, 30, 10, 5),
            lastFixAt: DateTime.utc(2026, 8, 30, 10, 4, 30),
            recordingSince: since),
        isFalse,
      );
    });

    test('a minute without a single fix is silence', () {
      expect(
        isGpsSilent(
            now: DateTime.utc(2026, 8, 30, 10, 5),
            lastFixAt: DateTime.utc(2026, 8, 30, 10, 3, 30),
            recordingSince: since),
        isTrue,
      );
    });

    test('before the first fix the clock runs from the trip start', () {
      // The failure this exists for — geolocator not working in the service
      // isolate — never produces a first fix at all, so a null lastFixAt
      // must not read as "fine".
      expect(
        isGpsSilent(
            now: DateTime.utc(2026, 8, 30, 10, 0, 30),
            lastFixAt: null,
            recordingSince: since),
        isFalse,
      );
      expect(
        isGpsSilent(
            now: DateTime.utc(2026, 8, 30, 10, 2),
            lastFixAt: null,
            recordingSince: since),
        isTrue,
      );
    });

    test('a fix arriving after a silent spell clears it', () {
      expect(
        isGpsSilent(
            now: DateTime.utc(2026, 8, 30, 10, 10),
            lastFixAt: DateTime.utc(2026, 8, 30, 10, 9, 59),
            recordingSince: since),
        isFalse,
      );
    });

    test('the threshold is the documented one minute', () {
      expect(kGpsSilenceThreshold, const Duration(seconds: 60));
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
