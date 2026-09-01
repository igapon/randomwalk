// Integration-level coverage for M5's two automatic sync trigger points
// wired in main.dart: launch (HomeShell.initState -> restoreAccountAndAuto
// Sync) and post-trip (_onSessionEnded -> runAutoSync). auto_sync_test.dart
// already covers the underlying functions in isolation; this file proves
// main.dart actually calls them at the right moments.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/game/game_state_provider.dart';
import 'package:randomwalk/main.dart';
import 'package:randomwalk/sync/account_state.dart';
import 'package:randomwalk/sync/backend.dart';
import 'package:randomwalk/sync/providers.dart';
import 'package:randomwalk/theme/theme.dart';
import 'package:randomwalk/tracking/permissions.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/tracking/trip_snapshot.dart';
import 'package:randomwalk/trip/trip_controller.dart';
import 'package:randomwalk/valhalla/models.dart';

import 'support/fake_sync_backend.dart';
import 'support/trip_fakes.dart';

void main() {
  late FakeTripTracker tracker;
  late FakeTotalDistanceStore totals;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tracker = FakeTripTracker();
    totals = FakeTotalDistanceStore();
    tempDir = await Directory.systemTemp.createTemp('main_sync_wiring_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

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

  Future<FakeSyncBackend> pumpSignedInShell(WidgetTester tester) async {
    final trip = buildTrip();
    await trip.restore();
    // Seeded as signedOut with a restorable session — this is what makes
    // HomeShell.initState's restoreAccountAndAutoSync() call actually do
    // something: it starts from signedOut, discovers the session via
    // currentUser(), transitions to signedIn, THEN auto-syncs. Seeding
    // straight to signedIn would skip restoreAccountAndAutoSync entirely
    // (its own guard only fires from signedOut — see auto_sync.dart).
    final backend = FakeSyncBackend()
      ..currentUserAnswers = const [AuthUser(uid: 'u1', email: 'a@b.ch')];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripControllerProvider.overrideWith((ref) => trip),
          syncBackendProvider.overrideWithValue(backend),
          accountStateProvider.overrideWith(
            (ref) => const AccountState.signedOut(),
          ),
          gameJournalProvider.overrideWith(
            (ref) async => GameJournal(Directory('${tempDir.path}/journal')),
          ),
        ],
        child: MaterialApp(
          title: 'RandomWalk Test',
          theme: AppTheme.light,
          home: const HomeShell(
            screensOverride: [
              SizedBox.shrink(),
              SizedBox.shrink(),
              SizedBox.shrink(),
            ],
          ),
        ),
      ),
    );
    return backend;
  }

  testWidgets('launch triggers an auto-sync pull when already signedIn (via '
      'HomeShell.initState -> restoreAccountAndAutoSync)', (tester) async {
    final backend = await pumpSignedInShell(tester);

    // restoreAccountAndAutoSync/runAutoSync were kicked off unawaited
    // from initState — see _pumpUntil's own doc comment for why driving
    // that real dart:io work to completion needs both runAsync and pump.
    await _pumpUntil(tester, () => backend.pullCallCount > 0);

    expect(backend.pullCallCount, greaterThan(0));
  });

  testWidgets(
    'finishing an interrupted trip triggers a post-trip auto-sync (via '
    '_onSessionEnded -> runAutoSync), without blocking the Terminer flow',
    (tester) async {
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

      final backend = await pumpSignedInShell(tester);
      // Let the launch auto-sync above settle first so its pull count
      // doesn't get conflated with the post-trip one below.
      await _pumpUntil(tester, () => backend.pullCallCount > 0);
      final pullsAfterLaunch = backend.pullCallCount;

      await tester.tap(find.text('Terminer'));
      await _pumpUntil(tester, () => backend.pullCallCount > pullsAfterLaunch);

      expect(totals.total, closeTo(2.4, 1e-9)); // trip flow itself unaffected
      expect(backend.pullCallCount, greaterThan(pullsAfterLaunch));
    },
  );
}

/// Waits for [condition] to become true, bounded so a genuine regression
/// fails fast instead of hanging.
///
/// Needs BOTH halves, alternating: the work being waited on
/// (`restoreAccountAndAutoSync`/`runAutoSync`, kicked off unawaited from
/// widget code, i.e. inside `testWidgets`' own FakeAsync test zone) does
/// real `dart:io` journal I/O — `tester.pump()` alone never lets that
/// really progress (FakeAsync doesn't grant real wall-clock time to the
/// OS), and `tester.runAsync()` alone lets real time pass but can't drain
/// the FakeAsync zone's own microtask queue that the awaited continuation
/// is queued on once the real I/O completes. So: `runAsync` a short real
/// sleep (lets the pending real I/O actually make progress), then `pump()`
/// (drains whatever of that progress is now ready into the test zone),
/// repeated until [condition] holds.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}
