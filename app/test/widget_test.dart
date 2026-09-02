// Shell-level tests: the three-tab navigation, the fact that screens stay
// mounted across tab switches (IndexedStack), and the « Trajet interrompu »
// recovery banner that a cold start after a process kill puts up.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:randomwalk/adventure/adventure_screen.dart';
import 'package:randomwalk/main.dart';
import 'package:randomwalk/map/carte_tab.dart';
import 'package:randomwalk/theme/theme.dart';
import 'package:randomwalk/tracking/permissions.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/tracking/trip_snapshot.dart';
import 'package:randomwalk/trip/trip_controller.dart';
import 'package:randomwalk/valhalla/models.dart';

import 'support/trip_fakes.dart';

void main() {
  late FakeTripTracker tracker;
  late FakeTotalDistanceStore totals;

  TripController buildTrip() => TripController(
    tracker: tracker,
    routeStore: MemoryRouteStore(),
    totalStore: totals,
    finalisedTrips: MemoryFinalisedTripMemory(),
    ensurePermissions: () async => const TripPermissions(
      outcome: TripPermissionOutcome.ready,
      mode: TrackingMode.background,
    ),
    createStepCounter: (seed) =>
        SessionStepCounter(FakeStepSensor(), seed: seed),
    persistProfile: (_) async {},
    loadProfile: () async => null,
  );

  Future<TripController> pumpShell(
    WidgetTester tester, {
    List<Widget>? screens,
  }) async {
    final trip = buildTrip();
    await trip.restore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tripControllerProvider.overrideWith((ref) => trip)],
        child: MaterialApp(
          title: 'RandomWalk Test',
          theme: AppTheme.light,
          home: HomeShell(screensOverride: screens),
        ),
      ),
    );
    return trip;
  }

  setUp(() {
    tracker = FakeTripTracker();
    totals = FakeTotalDistanceStore();
  });

  test('HomeShell.defaultScreens wiring is correct', () {
    expect(HomeShell.defaultScreens, hasLength(4));
    // Task 2i: the Carte tab's resting content is now `CarteTabRoot` — the
    // wizard-or-map router — rather than `MapScreen` directly; see
    // `carte_tab.dart`.
    expect(HomeShell.defaultScreens[0], isA<CarteTabRoot>());
    expect(HomeShell.defaultScreens[3], isA<AdventureScreen>());
  });

  testWidgets('RandomWalkApp shows the four-tab shell', (tester) async {
    await pumpShell(
      tester,
      screens: <Widget>[
        const Center(child: Text('Tab0Marker')),
        const Center(child: Text('Tab1Marker')),
        const Center(child: Text('Tab2Marker')),
        const Center(child: Text('Tab3Marker')),
      ],
    );

    // IndexedStack keeps every screen in the tree; only the selected one is
    // painted, so visibility — not existence — is what identifies the tab.
    expect(find.text('Tab0Marker', skipOffstage: true), findsOneWidget);
    expect(find.text('Tab1Marker', skipOffstage: true), findsNothing);
    expect(find.text('Tab2Marker', skipOffstage: true), findsNothing);
    expect(find.text('Tab3Marker', skipOffstage: true), findsNothing);

    expect(find.text('Carte'), findsOneWidget);
    expect(find.text('Session'), findsOneWidget);
    expect(find.text('Classement'), findsOneWidget);
    expect(find.text('Aventure'), findsOneWidget);

    await tester.tap(find.text('Session'));
    await tester.pumpAndSettle();
    expect(find.text('Tab1Marker', skipOffstage: true), findsOneWidget);
    expect(find.text('Tab0Marker', skipOffstage: true), findsNothing);

    await tester.tap(find.text('Classement'));
    await tester.pumpAndSettle();
    expect(find.text('Tab2Marker', skipOffstage: true), findsOneWidget);

    await tester.tap(find.text('Aventure'));
    await tester.pumpAndSettle();
    expect(find.text('Tab3Marker', skipOffstage: true), findsOneWidget);

    await tester.tap(find.text('Carte'));
    await tester.pumpAndSettle();
    expect(find.text('Tab0Marker', skipOffstage: true), findsOneWidget);
  });

  testWidgets('screens are kept alive across tab switches', (tester) async {
    await pumpShell(
      tester,
      screens: const <Widget>[
        _CountingScreen(label: 'Carte'),
        Center(child: Text('Session')),
        Center(child: Text('Classement')),
        Center(child: Text('Aventure')),
      ],
    );
    expect(_CountingScreen.initCount, 1);

    await tester.tap(find.text('Session'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Carte').last);
    await tester.pumpAndSettle();

    // The whole point of IndexedStack here: the map is not rebuilt from
    // scratch (and its native surface not recreated) on every glance at
    // another tab.
    expect(_CountingScreen.initCount, 1);
  });

  testWidgets('a silent GPS raises a banner while recording', (tester) async {
    TripSnapshot recording({bool gpsSilent = false}) => TripSnapshot(
      status: TripStatus.recording,
      distanceKm: 1.2,
      steps: 1500,
      startedAt: DateTime.utc(2026, 8, 30, 9, 30),
      updatedAt: DateTime.utc(2026, 8, 30, 9, 58),
      profile: RoutingProfile.walk,
      routeBound: false,
      gpsSilent: gpsSilent,
    );

    tracker
      ..persisted = recording()
      ..running = true;

    final trip = await pumpShell(
      tester,
      screens: const [SizedBox.shrink(), SizedBox.shrink(), SizedBox.shrink()],
    );
    expect(find.textContaining('GPS silencieux'), findsNothing);

    tracker.emit(recording(gpsSilent: true));
    // Two pumps: one to deliver the stream event to the controller, one to
    // rebuild on the notification riverpod raises from it.
    await tester.pump();
    await tester.pump();
    expect(trip.gpsSilent, isTrue, reason: 'controller state');
    expect(find.textContaining('GPS silencieux'), findsOneWidget);

    tracker.emit(recording());
    await tester.pump();
    await tester.pump();
    expect(trip.gpsSilent, isFalse, reason: 'controller state');
    expect(find.textContaining('GPS silencieux'), findsNothing);
  });

  testWidgets('a service already silent at cold start warns immediately', (
    tester,
  ) async {
    tracker
      ..persisted = TripSnapshot(
        status: TripStatus.recording,
        distanceKm: 1.2,
        steps: 1500,
        startedAt: DateTime.utc(2026, 8, 30, 9, 30),
        updatedAt: DateTime.utc(2026, 8, 30, 9, 58),
        profile: RoutingProfile.walk,
        routeBound: false,
        gpsSilent: true,
      )
      ..running = true;

    await pumpShell(
      tester,
      screens: const [SizedBox.shrink(), SizedBox.shrink(), SizedBox.shrink()],
    );

    // No transition to observe — the service went quiet while this process
    // did not exist.
    expect(find.textContaining('GPS silencieux'), findsOneWidget);
  });

  group('interrupted trip banner', () {
    setUp(() {
      tracker
        ..persisted = TripSnapshot(
          status: TripStatus.recording,
          distanceKm: 2.4,
          steps: 3100,
          startedAt: DateTime.utc(2026, 8, 30, 9, 30),
          updatedAt: DateTime.utc(2026, 8, 30, 9, 58),
          profile: RoutingProfile.walk,
          routeBound: false,
        )
        ..running = false;
    });

    testWidgets('offers Reprendre / Terminer after a process kill', (
      tester,
    ) async {
      await pumpShell(
        tester,
        screens: const [
          SizedBox.shrink(),
          SizedBox.shrink(),
          SizedBox.shrink(),
        ],
      );

      expect(find.text('Trajet interrompu'), findsOneWidget);
      expect(find.text('2,40 km enregistrés'), findsOneWidget);
      expect(find.text('Reprendre'), findsOneWidget);
      expect(find.text('Terminer'), findsOneWidget);
    });

    testWidgets('Reprendre restarts the service with the saved distance', (
      tester,
    ) async {
      await pumpShell(
        tester,
        screens: const [
          SizedBox.shrink(),
          SizedBox.shrink(),
          SizedBox.shrink(),
        ],
      );

      await tester.tap(find.text('Reprendre'));
      await tester.pumpAndSettle();

      expect(tracker.startedWith.single.distanceKm, closeTo(2.4, 1e-9));
      expect(tracker.startedWith.single.steps, 3100);
      expect(find.text('Trajet interrompu'), findsNothing);
    });

    testWidgets('Terminer banks the distance and dismisses the banner', (
      tester,
    ) async {
      await pumpShell(
        tester,
        screens: const [
          SizedBox.shrink(),
          SizedBox.shrink(),
          SizedBox.shrink(),
        ],
      );

      await tester.tap(find.text('Terminer'));
      await tester.pumpAndSettle();

      expect(totals.total, closeTo(2.4, 1e-9));
      expect(find.text('Trajet interrompu'), findsNothing);
    });

    testWidgets('no banner when nothing was interrupted', (tester) async {
      tracker.persisted = null;
      await pumpShell(
        tester,
        screens: const [
          SizedBox.shrink(),
          SizedBox.shrink(),
          SizedBox.shrink(),
        ],
      );
      expect(find.text('Trajet interrompu'), findsNothing);
    });
  });
}

/// Counts how many times it was built from scratch, to prove the shell
/// keeps screens mounted.
class _CountingScreen extends StatefulWidget {
  const _CountingScreen({required this.label});
  final String label;
  static int initCount = 0;

  @override
  State<_CountingScreen> createState() => _CountingScreenState();
}

class _CountingScreenState extends State<_CountingScreen> {
  @override
  void initState() {
    super.initState();
    _CountingScreen.initCount++;
  }

  @override
  Widget build(BuildContext context) => Center(child: Text(widget.label));
}
