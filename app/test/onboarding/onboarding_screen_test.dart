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
  // Task 2c: what the coordinator's fresh, non-prompting re-check
  // (`currentTrackingMode`, plumbed through as `readTrackingMode`) reports.
  // Mutable so a test can simulate the user granting "Autoriser tout le
  // temps" from Android settings between two reads.
  late TrackingMode currentTrackingMode;
  late int openSettingsCalls;

  TripController buildTrip() => TripController(
    tracker: tracker,
    routeStore: MemoryRouteStore(),
    totalStore: FakeTotalDistanceStore(),
    finalisedTrips: MemoryFinalisedTripMemory(),
    ensurePermissions: () async {
      ensurePermissionsCalls++;
      return TripPermissions(outcome: ensurePermissionsOutcome);
    },
    readTrackingMode: () async => currentTrackingMode,
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
            openSettings: () async {
              openSettingsCalls++;
            },
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
    currentTrackingMode = TrackingMode.background;
    openSettingsCalls = 0;
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

  // Task 2c: "quand tu demandes les permissions au debut, assure toi bien de
  // la permission de location tout le temps" — the owner's direct request.
  // After the flow above, the gate re-checks `readTrackingMode` (the
  // coordinator's `currentTrackingMode`, plumbed straight through — see
  // OnboardingGate's class doc comment) instead of trusting whatever
  // `TripPermissions.mode` the flow itself returned.
  group('task 2c — background-location insistence step', () {
    testWidgets('background granted: no insistence step, straight to the map', (
      tester,
    ) async {
      currentTrackingMode = TrackingMode.background;
      await pumpGate(tester, onboarded: false);

      await tester.tap(find.text('C\'est parti'));
      await tester.pumpAndSettle();

      expect(find.text('CarteMarker'), findsOneWidget);
      expect(
        find.text('Un dernier réglage pour un suivi fiable'),
        findsNothing,
      );
      expect(await isOnboarded(), isTrue);
    });

    testWidgets(
      'foregroundOnly: the insistence step is shown instead of the map',
      (tester) async {
        currentTrackingMode = TrackingMode.foregroundOnly;
        await pumpGate(tester, onboarded: false);

        await tester.tap(find.text('C\'est parti'));
        await tester.pumpAndSettle();

        expect(find.text('CarteMarker'), findsNothing);
        expect(
          find.text('Un dernier réglage pour un suivi fiable'),
          findsOneWidget,
        );
        expect(find.text('Ouvrir les réglages'), findsOneWidget);
        expect(find.text('Continuer sans'), findsOneWidget);
        // Brief item 3: the flag is not set while the insistence step is
        // still showing — a kill here shows onboarding again next launch.
        expect(await isOnboarded(), isFalse);
        // A SafeArea wraps the step's content (recurring bottom-inset
        // defect) — see android-system-nav-bar.md.
        expect(
          find.ancestor(
            of: find.text('Ouvrir les réglages'),
            matching: find.byType(SafeArea),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('"Ouvrir les réglages" calls openSettings', (tester) async {
      currentTrackingMode = TrackingMode.foregroundOnly;
      await pumpGate(tester, onboarded: false);
      await tester.tap(find.text('C\'est parti'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Ouvrir les réglages'));
      await tester.pumpAndSettle();

      expect(openSettingsCalls, 1);
      // Non-blocking: opening settings does not by itself finish onboarding
      // or reach the map — only the resume re-check or "Continuer sans" do.
      expect(find.text('CarteMarker'), findsNothing);
      expect(await isOnboarded(), isFalse);
    });

    testWidgets('resuming with background now granted advances automatically', (
      tester,
    ) async {
      currentTrackingMode = TrackingMode.foregroundOnly;
      await pumpGate(tester, onboarded: false);
      await tester.tap(find.text('C\'est parti'));
      await tester.pumpAndSettle();
      expect(find.text('Ouvrir les réglages'), findsOneWidget);

      await tester.tap(find.text('Ouvrir les réglages'));
      await tester.pumpAndSettle();

      // The user granted it in Android settings; the coordinator's next
      // read reflects that.
      currentTrackingMode = TrackingMode.background;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('CarteMarker'), findsOneWidget);
      expect(await isOnboarded(), isTrue);
    });

    testWidgets(
      'resuming with background still refused stays on the insistence step',
      (tester) async {
        currentTrackingMode = TrackingMode.foregroundOnly;
        await pumpGate(tester, onboarded: false);
        await tester.tap(find.text('C\'est parti'));
        await tester.pumpAndSettle();

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Un dernier réglage pour un suivi fiable'),
          findsOneWidget,
        );
        expect(find.text('CarteMarker'), findsNothing);
        expect(await isOnboarded(), isFalse);
      },
    );

    testWidgets('"Continuer sans" reaches the map without background', (
      tester,
    ) async {
      currentTrackingMode = TrackingMode.foregroundOnly;
      await pumpGate(tester, onboarded: false);
      await tester.tap(find.text('C\'est parti'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Continuer sans'));
      await tester.pumpAndSettle();

      expect(find.text('CarteMarker'), findsOneWidget);
      expect(await isOnboarded(), isTrue);
    });
  });
}
