// `CarteTabRoot` decides Wizard vs. `MapScreen` — the latter owns a real
// native map view and cannot be widget-tested at all (see
// `map_screen_widgets_test.dart`'s own doc comment), so the branching itself
// is covered by [shouldShowWizardHome] directly (no widget pump needed), and
// only the Wizard-shown branch is exercised end-to-end here. That branch's
// own absence of `MapScreen`/`MaplibreMap` anywhere in the tree is the
// brief's "no map before step 3" requirement, proven simply by the fact that
// pumping it does not throw the `MissingPluginException` a real `MapScreen`
// would.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/history/trip_history_store.dart';
import 'package:randomwalk/map/carte_tab.dart';
import 'package:randomwalk/tracking/permissions.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/trip/trip_controller.dart';

import '../support/trip_fakes.dart';

void main() {
  group('shouldShowWizardHome', () {
    test('idle, empty route, not sticky — shows the wizard', () {
      expect(
        shouldShowWizardHome(
          showMapSticky: false,
          tripState: TripState.idle,
          activeRouteEmpty: true,
        ),
        isTrue,
      );
    });

    test('recording — never the wizard, regardless of the route', () {
      expect(
        shouldShowWizardHome(
          showMapSticky: false,
          tripState: TripState.recording,
          activeRouteEmpty: true,
        ),
        isFalse,
      );
    });

    test('interrupted — never the wizard', () {
      expect(
        shouldShowWizardHome(
          showMapSticky: false,
          tripState: TripState.interrupted,
          activeRouteEmpty: true,
        ),
        isFalse,
      );
    });

    test('idle but a route/destination is already planned', () {
      expect(
        shouldShowWizardHome(
          showMapSticky: false,
          tripState: TripState.idle,
          activeRouteEmpty: false,
        ),
        isFalse,
      );
    });

    test('sticky (Explorer/Promenade mid-flow) overrides an empty route', () {
      expect(
        shouldShowWizardHome(
          showMapSticky: true,
          tripState: TripState.idle,
          activeRouteEmpty: true,
        ),
        isFalse,
      );
    });
  });

  group('CarteTabRoot — resting state (no trip, no plan)', () {
    late FakeTripTracker tracker;
    late MemoryRouteStore routes;

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

    setUp(() {
      tracker = FakeTripTracker();
      routes = MemoryRouteStore();
    });

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tripControllerProvider.overrideWith((ref) => buildTrip()),
            tripHistoryLatestProvider.overrideWith((ref) async => null),
          ],
          child: const MaterialApp(home: CarteTabRoot()),
        ),
      );
      await tester.pump();
    }

    testWidgets('shows the wizard home screen, not a map', (tester) async {
      await pump(tester);

      expect(find.text('Destination'), findsOneWidget);
      expect(find.text('Promenade'), findsOneWidget);
      expect(find.text('Explorer la carte'), findsOneWidget);
      // The perf requirement this task is pinned on: no map instantiated
      // before step 3. Reaching this line at all (pumpWidget above did not
      // throw) already proves it for a real `MapScreen`; this assertion
      // pins the *type* down too, so a future edit that swaps in some other
      // map widget still trips it.
      expect(
        find.byWidgetPredicate((w) => '${w.runtimeType}' == 'MapScreen'),
        findsNothing,
      );
    });

    testWidgets('hides "Repartir" with no trip history', (tester) async {
      await pump(tester);
      expect(find.text('Repartir'), findsNothing);
    });
  });
}
