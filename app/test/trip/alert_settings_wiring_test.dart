import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:randomwalk/settings/alert_settings.dart';
import 'package:randomwalk/tracking/permissions.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/trip/trip_controller.dart';

import '../support/trip_fakes.dart';

/// [TripController.setTtsEnabled]/[setHapticsEnabled] have two jobs: persist
/// the toggle (so the next trip's seed picks it up) and, while a trip is
/// already recording, push it straight into the running service (see
/// `TripTracker.updateAlertSettings`) rather than making the walker wait for
/// the trip to end. Both are exercised here without a real service.
void main() {
  late FakeTripTracker tracker;
  late TripController trip;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tracker = FakeTripTracker();
    trip = TripController(
      tracker: tracker,
      routeStore: MemoryRouteStore(),
      totalStore: FakeTotalDistanceStore(),
      finalisedTrips: MemoryFinalisedTripMemory(),
      ensurePermissions: () async => const TripPermissions(
          outcome: TripPermissionOutcome.ready,
          mode: TrackingMode.background,
          stepsAvailable: true),
      createStepCounter: (seed) =>
          SessionStepCounter(FakeStepSensor(), seed: seed),
      persistProfile: (_) async {},
      loadProfile: () async => null,
    );
  });

  test('setTtsEnabled persists and forwards both current values', () async {
    await trip.setHapticsEnabled(false);
    tracker.alertSettingsUpdates.clear();

    await trip.setTtsEnabled(false);

    final store = AlertSettingsStore();
    expect(await store.ttsEnabled(), isFalse);
    // The haptics value set earlier must not be clobbered by a call that
    // only meant to change tts.
    expect(await store.hapticsEnabled(), isFalse);
    expect(tracker.alertSettingsUpdates.single,
        (ttsEnabled: false, hapticsEnabled: false));
  });

  test('setHapticsEnabled persists and forwards both current values',
      () async {
    await trip.setTtsEnabled(false);
    tracker.alertSettingsUpdates.clear();

    await trip.setHapticsEnabled(false);

    final store = AlertSettingsStore();
    expect(await store.hapticsEnabled(), isFalse);
    expect(await store.ttsEnabled(), isFalse);
    expect(tracker.alertSettingsUpdates.single,
        (ttsEnabled: false, hapticsEnabled: false));
  });
}
