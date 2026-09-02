import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/map/geocoding.dart';
import 'package:randomwalk/map/plan_mode.dart';
import 'package:randomwalk/map/route_controller.dart'
    show geocodingServiceProvider;
import 'package:randomwalk/map/wizard_destination_flow.dart';
import 'package:randomwalk/tracking/permissions.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/trip/trip_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/trip_fakes.dart';

class _FakeGeocodingService implements GeocodingService {
  List<GeocodeResult> results = const [];

  @override
  Future<List<GeocodeResult>> search(
    String query, {
    double? nearLat,
    double? nearLon,
  }) async => results;
}

void main() {
  late FakeTripTracker tracker;
  late MemoryRouteStore routes;
  late _FakeGeocodingService geocoding;
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

  late TripController trip;

  Future<void> pumpSearch(WidgetTester tester) async {
    trip = buildTrip();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripControllerProvider.overrideWith((ref) => trip),
          geocodingServiceProvider.overrideWithValue(geocoding),
        ],
        child: MaterialApp(
          home: WizardDestinationSearchScreen(
            onEnterMap: ([h]) => entered.add(h),
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
    geocoding = _FakeGeocodingService();
    entered = [];
  });

  testWidgets('autofocuses the search field', (tester) async {
    await pumpSearch(tester);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autofocus, isTrue);
  });

  testWidgets('typing shows results and selecting one opens the constraint '
      'screen', (tester) async {
    geocoding.results = const [
      GeocodeResult(label: 'Cathédrale de Lausanne', lat: 46.52, lon: 6.63),
    ];
    await pumpSearch(tester);

    await tester.enterText(find.byType(TextField), 'Lausanne');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(find.text('Cathédrale de Lausanne'), findsOneWidget);

    await tester.tap(find.text('Cathédrale de Lausanne'));
    await tester.pumpAndSettle();

    expect(find.byType(WizardConstraintScreen), findsOneWidget);
    expect(entered, isEmpty); // still mid-flow.
  });

  group('WizardConstraintScreen', () {
    Future<void> pumpConstraint(WidgetTester tester) async {
      trip = buildTrip();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [tripControllerProvider.overrideWith((ref) => trip)],
          child: MaterialApp(
            home: WizardConstraintScreen(
              destination: (46.52, 6.63),
              destinationLabel: 'Cathédrale de Lausanne',
              onEnterMap: ([h]) => entered.add(h),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('no constraint plans a direct itinerary', (tester) async {
      await pumpConstraint(tester);

      await tester.tap(find.text("Planifier l'itinéraire"));
      await tester.pump();
      await tester.pump();

      expect(entered, hasLength(1));
      final handoff = entered.single!;
      expect(handoff.loopTargetKm, isNull);
      expect(handoff.durationTarget, isNull);
      expect(trip.activeRoute?.destination, (46.52, 6.63));
      expect(await PlanModeStore().load(), PlanMode.itinerary);
    });

    testWidgets('a distance constraint plans a fixed-target loop', (
      tester,
    ) async {
      await pumpConstraint(tester);

      await tester.tap(find.text('Distance'));
      await tester.pump();
      await tester.tap(find.text('8 km'));
      await tester.pump();
      await tester.tap(find.text('Proposer'));
      await tester.pump();
      await tester.pump();

      expect(entered, hasLength(1));
      final handoff = entered.single!;
      expect(handoff.loopTargetKm, 8.0);
      expect(trip.activeRoute?.destination, (46.52, 6.63));
      expect(await PlanModeStore().load(), PlanMode.loop);
    });

    testWidgets('a duration constraint plans a fixed-target duration loop', (
      tester,
    ) async {
      await pumpConstraint(tester);

      await tester.tap(find.text('Durée'));
      await tester.pump();
      await tester.tap(find.text('30 min'));
      await tester.pump();
      await tester.tap(find.text('Proposer'));
      await tester.pump();
      await tester.pump();

      expect(entered, hasLength(1));
      final handoff = entered.single!;
      expect(handoff.durationTarget, const Duration(minutes: 30));
      expect(await PlanModeStore().load(), PlanMode.duration);
    });
  });
}
