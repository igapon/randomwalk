import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/history/trip_history_store.dart';
import 'package:randomwalk/map/plan_mode.dart';
import 'package:randomwalk/map/wizard_defaults_store.dart';
import 'package:randomwalk/map/wizard_destination_flow.dart';
import 'package:randomwalk/map/wizard_home_screen.dart';
import 'package:randomwalk/map/wizard_promenade_screen.dart';
import 'package:randomwalk/theme/theme.dart';
import 'package:randomwalk/theme/tokens.dart';
import 'package:randomwalk/theme/waymark_glyph.dart';
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

  Future<void> pump(
    WidgetTester tester, {
    TripHistoryEntry? latestTrip,
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripControllerProvider.overrideWith((ref) => buildTrip()),
          tripHistoryLatestProvider.overrideWith((ref) async => latestTrip),
        ],
        child: MaterialApp(
          theme: theme,
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

    // Review fix round 1 (Important #2): the Destination card's icon used to
    // hardcode `AppColors.ink`, near-invisible on dark theme's
    // `primaryContainer` (`yellowPaleDark`). Two separate `testWidgets` —
    // matching this project's own established pattern for light/dark
    // assertions (see `map_screen_widgets_test.dart`'s `NavArrivedCard`/
    // `RecenterButton` groups) — rather than two `pumpWidget` calls inside
    // one test, which does not reliably re-resolve `Theme.of(context)`
    // through this widget tree's `ConsumerWidget`/`ProviderScope` layering.
    WaymarkDiamond destinationIcon(WidgetTester tester) => tester
        .widgetList<WaymarkDiamond>(find.byType(WaymarkDiamond))
        .firstWhere((w) => w.size == 28);

    testWidgets('light theme: icon color resolves from onPrimaryContainer', (
      tester,
    ) async {
      await pump(tester, theme: AppTheme.light);
      expect(
        destinationIcon(tester).color,
        AppTheme.light.colorScheme.onPrimaryContainer,
      );
    });

    testWidgets(
      'dark theme: icon color resolves from onPrimaryContainer, not the '
      'hardcoded AppColors.ink regression',
      (tester) async {
        await pump(tester, theme: AppTheme.dark);
        final color = destinationIcon(tester).color;
        expect(color, AppTheme.dark.colorScheme.onPrimaryContainer);
        // The specific regression this pins: `AppColors.ink` (near-black) is
        // what the hardcoded color used to be, sitting on dark theme's
        // brown-gold `primaryContainer` at near-invisible contrast.
        expect(color, isNot(equals(AppColors.ink)));
      },
    );

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
