import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/history/trip_history_store.dart';
import 'package:randomwalk/map/plan_mode.dart';
import 'package:randomwalk/map/wizard_defaults_store.dart';
import 'package:randomwalk/map/wizard_destination_flow.dart';
import 'package:randomwalk/map/wizard_home_screen.dart';
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

  Future<void> pump(WidgetTester tester, {TripHistoryEntry? latestTrip}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripControllerProvider.overrideWith((ref) => buildTrip()),
          tripHistoryLatestProvider.overrideWith((ref) async => latestTrip),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: WizardHomeScreen(onEnterMap: ([h]) => entered.add(h)),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tracker = FakeTripTracker();
    routes = MemoryRouteStore();
    entered = [];
  });

  group('WizardHomeScreen — layout', () {
    testWidgets('shows the two big cards and Explorer, no Repartir', (
      tester,
    ) async {
      await pump(tester);

      expect(find.text('Destination'), findsOneWidget);
      expect(find.text('Promenade'), findsOneWidget);
      expect(find.text('Explorer la carte'), findsOneWidget);
      expect(find.text('Repartir'), findsNothing);
    });

    testWidgets('shows Repartir with the last trip\'s own summary', (
      tester,
    ) async {
      await pump(
        tester,
        latestTrip: TripHistoryEntry(
          id: 1,
          startedAt: DateTime(2026, 8, 30, 9),
          endedAt: DateTime(2026, 8, 30, 10),
          profile: RoutingProfile.walk,
          distanceKm: 5.2,
          duration: const Duration(minutes: 60),
          avgSpeedKmh: 5.2,
        ),
      );

      expect(find.text('Repartir'), findsOneWidget);
      expect(find.textContaining('5,20 km'), findsOneWidget);
      expect(find.textContaining('Marche'), findsOneWidget);
    });
  });

  group('WizardHomeScreen — navigation', () {
    testWidgets('Destination pushes the fullscreen address search', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.text('Destination'));
      await tester.pumpAndSettle();

      expect(find.byType(WizardDestinationSearchScreen), findsOneWidget);
      expect(entered, isEmpty); // no hand-off yet — still mid-flow.
    });

    testWidgets('Promenade pushes the promenade config screen', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Promenade'));
      await tester.pumpAndSettle();

      expect(find.byType(WizardPromenadeScreen), findsOneWidget);
      expect(entered, isEmpty);
    });

    testWidgets('Explorer la carte hands off immediately, with no handoff', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.text('Explorer la carte'));
      await tester.pump();

      expect(entered, [null]);
    });
  });

  group('WizardHomeScreen — Repartir (2-tap quick start)', () {
    testWidgets(
      'commits the memorized promenade defaults and auto-accepts the best '
      'candidate',
      (tester) async {
        await WizardDefaultsStore().saveMode(PlanMode.duration);
        await WizardDefaultsStore().saveDurationTarget(
          const Duration(minutes: 45),
        );
        await pump(
          tester,
          latestTrip: TripHistoryEntry(
            id: 1,
            startedAt: DateTime(2026, 8, 30, 9),
            endedAt: DateTime(2026, 8, 30, 10),
            profile: RoutingProfile.walk,
            distanceKm: 3.1,
            duration: const Duration(minutes: 45),
            avgSpeedKmh: 4.1,
          ),
        );

        await tester.tap(find.text('Repartir'));
        await tester.pump();
        await tester.pump();

        expect(entered, hasLength(1));
        final handoff = entered.single!;
        expect(handoff.durationTarget, const Duration(minutes: 45));
        expect(handoff.loopTargetKm, isNull);
        // Brief point 4: "2 taps total" — Repartir must skip the fullscreen
        // candidate row entirely.
        expect(handoff.autoAcceptBestCandidate, isTrue);
        expect(await PlanModeStore().load(), PlanMode.duration);
      },
    );
  });
}
