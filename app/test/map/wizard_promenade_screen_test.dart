import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/map/plan_mode.dart';
import 'package:randomwalk/map/wizard_defaults_store.dart';
import 'package:randomwalk/map/wizard_promenade_screen.dart';
import 'package:randomwalk/tracking/permissions.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/trip/trip_controller.dart';
import 'package:randomwalk/valhalla/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/trip_fakes.dart';

void main() {
  late FakeTripTracker tracker;
  late MemoryRouteStore routes;
  late List<WizardHandoff?> entered;

  TripController buildTrip() => TripController(
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

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tripControllerProvider.overrideWith((ref) => buildTrip())],
        child: MaterialApp(
          home: WizardPromenadeScreen(onEnterMap: ([h]) => entered.add(h)),
        ),
      ),
    );
    await tester.pump(); // let `_loadDefaults` resolve.
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tracker = FakeTripTracker();
    routes = MemoryRouteStore();
    entered = [];
  });

  testWidgets('defaults to Distance with the walk default target', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Proposer'), findsOneWidget);
    // The walk profile's own default loop target (plan_mode.dart).
    final expected = defaultLoopTargetKm(
      RoutingProfile.walk,
    ).toStringAsFixed(1).replaceAll('.', ',');
    expect(find.textContaining('$expected km'), findsWidgets);
  });

  testWidgets('preloads the memorized constraint kind and target', (
    tester,
  ) async {
    await WizardDefaultsStore().saveMode(PlanMode.duration);
    await WizardDefaultsStore().saveDurationTarget(const Duration(minutes: 45));
    await pump(tester);

    expect(find.textContaining('45 min'), findsWidgets);
  });

  testWidgets('switching to Durée shows the duration picker', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Durée'));
    await tester.pump();

    expect(find.textContaining('min'), findsWidgets);
  });

  testWidgets('picking a distance chip updates the slider label', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('8 km'));
    await tester.pump();

    expect(find.text('8,0 km'), findsWidgets);
  });

  testWidgets('Proposer commits the plan and hands off to the map', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Vélo'));
    await tester.pump();
    await tester.tap(find.text('12 km'));
    await tester.pump();

    await tester.tap(find.text('Proposer'));
    await tester.pump();
    await tester.pump();

    expect(entered, hasLength(1));
    final handoff = entered.single!;
    expect(handoff.loopTargetKm, 12.0);
    expect(handoff.durationTarget, isNull);
    expect(handoff.autoAcceptBestCandidate, isFalse);
    expect(await PlanModeStore().load(), PlanMode.loop);
  });
}
