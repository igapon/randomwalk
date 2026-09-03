import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/map/plan_mode.dart';
import 'package:randomwalk/map/wizard_actions.dart';
import 'package:randomwalk/map/wizard_defaults_store.dart';
import 'package:randomwalk/tracking/permissions.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/trip/trip_controller.dart';
import 'package:randomwalk/valhalla/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/trip_fakes.dart';

void main() {
  late FakeTripTracker tracker;
  late MemoryRouteStore routes;
  late TripController trip;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tracker = FakeTripTracker();
    routes = MemoryRouteStore();
    trip = TripController(
      tracker: tracker,
      routeStore: routes,
      totalStore: FakeTotalDistanceStore(),
      finalisedTrips: MemoryFinalisedTripMemory(),
      speedHistory: FakeSpeedHistoryStore(),
      ensurePermissions: () async => const TripPermissions(
        outcome: TripPermissionOutcome.ready,
        mode: TrackingMode.background,
        stepsAvailable: true,
      ),
      createStepCounter: (seed) =>
          SessionStepCounter(FakeStepSensor(), seed: seed),
    );
  });

  group('commitPromenadePlan', () {
    test(
      'sets the profile, drops any prior destination, saves the mode',
      () async {
        routes.current = fakeActiveRoute(); // a leftover A→B pin.

        final handoff = await commitPromenadePlan(
          trip,
          mode: PlanMode.loop,
          loopTargetKm: 8.0,
          durationTarget: const Duration(minutes: 40),
          profile: RoutingProfile.bike,
        );

        expect(trip.profile, RoutingProfile.bike);
        expect(trip.activeRoute?.destination, isNull);
        expect(trip.activeRoute?.route, isNull);
        expect(await PlanModeStore().load(), PlanMode.loop);
        expect(handoff.loopTargetKm, 8.0);
        expect(handoff.durationTarget, isNull);
        expect(handoff.autoAcceptBestCandidate, isFalse);
      },
    );

    test('persists the memorized wizard defaults', () async {
      await commitPromenadePlan(
        trip,
        mode: PlanMode.duration,
        loopTargetKm: 6.0,
        durationTarget: const Duration(minutes: 55),
        profile: RoutingProfile.walk,
      );

      final defaults = await WizardDefaultsStore().load(RoutingProfile.walk);
      expect(defaults.mode, PlanMode.duration);
      // 55 min snaps to the nearest 15-min step (clampDurationTarget) — 60.
      expect(defaults.durationTarget, const Duration(minutes: 60));
    });

    test('autoAcceptBestCandidate is threaded through for Repartir', () async {
      final handoff = await commitPromenadePlan(
        trip,
        mode: PlanMode.loop,
        loopTargetKm: 5.0,
        durationTarget: const Duration(minutes: 60),
        profile: RoutingProfile.walk,
        autoAcceptBestCandidate: true,
      );
      expect(handoff.autoAcceptBestCandidate, isTrue);
    });
  });

  group('commitDestinationPlan', () {
    test('no constraint saves the destination as a plain itinerary', () async {
      final handoff = await commitDestinationPlan(
        trip,
        destination: (46.5, 6.6),
      );

      expect(trip.activeRoute?.destination, (46.5, 6.6));
      expect(await PlanModeStore().load(), PlanMode.itinerary);
      expect(handoff.loopTargetKm, isNull);
      expect(handoff.durationTarget, isNull);
    });

    test('a distance constraint saves PlanMode.loop and the target', () async {
      final handoff = await commitDestinationPlan(
        trip,
        destination: (46.5, 6.6),
        constraintMode: PlanMode.loop,
        loopTargetKm: 12.0,
      );

      expect(await PlanModeStore().load(), PlanMode.loop);
      expect(handoff.loopTargetKm, 12.0);
      final defaults = await WizardDefaultsStore().load(RoutingProfile.walk);
      expect(defaults.loopTargetKm, 12.0);
    });

    test(
      'a duration constraint saves PlanMode.duration and the target',
      () async {
        final handoff = await commitDestinationPlan(
          trip,
          destination: (46.5, 6.6),
          constraintMode: PlanMode.duration,
          durationTarget: const Duration(minutes: 30),
        );

        expect(await PlanModeStore().load(), PlanMode.duration);
        expect(handoff.durationTarget, const Duration(minutes: 30));
      },
    );

    test('keeps the current routing profile', () async {
      await trip.setProfile(RoutingProfile.bike);

      await commitDestinationPlan(trip, destination: (46.5, 6.6));

      expect(trip.profile, RoutingProfile.bike);
    });
  });
}
