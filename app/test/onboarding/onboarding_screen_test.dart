// Task 2b brief item 2c: first launch shows onboarding (not the map);
// tapping "C'est parti" runs the existing permission flow then shows the
// map; a later launch with the flag already set goes straight to the map;
// the flag is only set after the flow, not at build time.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/onboarding/onboarding_screen.dart';
import 'package:randomwalk/onboarding/onboarding_store.dart';
import 'package:randomwalk/theme/theme.dart';
import 'package:randomwalk/tracking/permissions.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/trip/trip_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/trip_fakes.dart';

void main() {
  late FakeTripTracker tracker;
  late int ensurePermissionsCalls;
  late TripPermissionOutcome ensurePermissionsOutcome;

  TripController buildTrip() => TripController(
    tracker: tracker,
    routeStore: MemoryRouteStore(),
    totalStore: FakeTotalDistanceStore(),
    finalisedTrips: MemoryFinalisedTripMemory(),
    ensurePermissions: () async {
      ensurePermissionsCalls++;
      return TripPermissions(outcome: ensurePermissionsOutcome);
    },
    createStepCounter: (seed) =>
        SessionStepCounter(FakeStepSensor(), seed: seed),
    persistProfile: (_) async {},
    loadProfile: () async => null,
  );

  Future<TripController> pumpGate(
    WidgetTester tester, {
    required bool onboarded,
  }) async {
    final trip = buildTrip();
    await trip.restore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tripControllerProvider.overrideWith((ref) => trip)],
        child: MaterialApp(
          title: 'RandomWalk Test',
          theme: AppTheme.light,
          home: OnboardingGate(
            onboarded: onboarded,
            child: const Scaffold(body: Center(child: Text('CarteMarker'))),
          ),
        ),
      ),
    );
    return trip;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tracker = FakeTripTracker();
    ensurePermissionsCalls = 0;
    ensurePermissionsOutcome = TripPermissionOutcome.ready;
  });

  testWidgets('first launch shows onboarding, not the map', (tester) async {
    await pumpGate(tester, onboarded: false);

    expect(find.text('RandomWalk'), findsOneWidget);
    expect(find.text('C\'est parti'), findsOneWidget);
    expect(find.text('CarteMarker'), findsNothing);
    expect(ensurePermissionsCalls, 0);
  });

  testWidgets(
    'tapping "C\'est parti" runs the permission flow then shows the map',
    (tester) async {
      await pumpGate(tester, onboarded: false);

      await tester.tap(find.text('C\'est parti'));
      await tester.pumpAndSettle();

      expect(ensurePermissionsCalls, 1);
      expect(find.text('CarteMarker'), findsOneWidget);
      expect(find.text('C\'est parti'), findsNothing);
    },
  );

  testWidgets(
    'a refused/openedSettings permission outcome still reaches the map',
    (tester) async {
      ensurePermissionsOutcome = TripPermissionOutcome.openedSettings;
      await pumpGate(tester, onboarded: false);

      await tester.tap(find.text('C\'est parti'));
      await tester.pumpAndSettle();

      expect(find.text('CarteMarker'), findsOneWidget);
    },
  );

  testWidgets('the onboarded flag is only set after the flow completes', (
    tester,
  ) async {
    await pumpGate(tester, onboarded: false);
    expect(await isOnboarded(), isFalse);

    await tester.tap(find.text('C\'est parti'));
    await tester.pumpAndSettle();

    expect(await isOnboarded(), isTrue);
  });

  testWidgets(
    'a later launch with the flag already set goes straight to the map',
    (tester) async {
      await pumpGate(tester, onboarded: true);

      expect(find.text('CarteMarker'), findsOneWidget);
      expect(find.text('C\'est parti'), findsNothing);
      expect(ensurePermissionsCalls, 0);
    },
  );
}
