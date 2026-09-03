import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/game/game_state_provider.dart';
import 'package:randomwalk/settings/local_purge.dart';
import 'package:randomwalk/tracking/permissions.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/tracking/trip_snapshot.dart';
import 'package:randomwalk/trip/trip_controller.dart';
import 'package:randomwalk/valhalla/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/temp_dir.dart';
import '../support/trip_fakes.dart';

/// Drives [runLocalPurge] directly from a tap — a minimal stand-in for
/// `AccountScreen`/`PurgeRetryTile`'s own call sites, letting these tests
/// exercise `runLocalPurge`'s refuse-guard and `PurgeRetryState` bookkeeping
/// without the rest of either screen.
class _Probe extends ConsumerWidget {
  const _Probe({required this.onResult, this.uid});
  final void Function(PurgeRunOutcome) onResult;
  final String? uid;

  @override
  Widget build(BuildContext context, WidgetRef ref) => GestureDetector(
    onTap: () async {
      final outcome = await runLocalPurge(ref, uid: uid);
      onResult(outcome);
    },
    child: const Text('go'),
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('purge_retry_test');
  });

  tearDown(() => deleteTempDirRetrying(tempDir));

  Future<TripController> buildTrip({
    bool recording = false,
    bool interrupted = false,
  }) async {
    final tracker = FakeTripTracker();
    final trip = TripController(
      tracker: tracker,
      routeStore: MemoryRouteStore(),
      totalStore: FakeTotalDistanceStore(),
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
    if (recording) {
      await trip.startTrip();
    } else if (interrupted) {
      // Same path TripController.restore takes for a trip whose process
      // died mid-recording: a persisted still-recording snapshot, but the
      // service itself is no longer running.
      tracker.persisted = TripSnapshot.starting(
        startedAt: DateTime.utc(2026, 8, 30, 9),
        profile: RoutingProfile.walk,
        routeBound: false,
      );
      tracker.running = false;
      await trip.restore();
    }
    return trip;
  }

  List<Override> overridesFor(TripController trip) => [
    gameJournalProvider.overrideWith(
      (ref) async => GameJournal(Directory('${tempDir.path}/journal')),
    ),
    tripControllerProvider.overrideWith((ref) => trip),
  ];

  /// Default `wait` is generous (not the usual 100 ms other test files use
  /// for lighter taps) because every real `runLocalPurge` call in this file
  /// now runs the full, heavier purge chain (journal/checkpoint/edges/
  /// trip-history/trip-snapshot/track/sync-state — seven real I/O steps).
  /// CI caught this directly: `a fully successful purge clears any prior
  /// incomplete flag` flaked with a null `result` (the tap's `_Probe`
  /// callback hadn't fired yet) under CI disk load with the old 100 ms
  /// default — bumping the default here, rather than only the call sites
  /// already known to need it, covers every current and future test in this
  /// file against the same class of flake.
  Future<void> tapAndWait(
    WidgetTester tester,
    String text, {
    Duration wait = const Duration(milliseconds: 1000),
  }) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(text));
      await Future<void>.delayed(wait);
    });
    await tester.pumpAndSettle();
  }

  group('runLocalPurge', () {
    testWidgets(
      'refuses while a trip is recording, and never touches PurgeRetryState '
      '(Task 6 review round 1, I1)',
      (tester) async {
        final trip = await buildTrip(recording: true);
        PurgeRunOutcome? result;
        await tester.pumpWidget(
          ProviderScope(
            overrides: overridesFor(trip),
            child: MaterialApp(home: _Probe(onResult: (o) => result = o)),
          ),
        );

        await tapAndWait(tester, 'go');

        expect(result!.refusedTripActive, isTrue);
        expect(await PurgeRetryState().isIncomplete(), isFalse);
      },
    );

    testWidgets(
      'refuses while a trip is merely interrupted too (Task 6 review round '
      '2) — resuming-and-finishing it afterward would write the pre-purge '
      'trip straight back into the just-emptied stores',
      (tester) async {
        final trip = await buildTrip(interrupted: true);
        expect(trip.isInterrupted, isTrue);
        PurgeRunOutcome? result;
        await tester.pumpWidget(
          ProviderScope(
            overrides: overridesFor(trip),
            child: MaterialApp(home: _Probe(onResult: (o) => result = o)),
          ),
        );

        await tapAndWait(tester, 'go');

        expect(result!.refusedTripActive, isTrue);
        expect(await PurgeRetryState().isIncomplete(), isFalse);
      },
    );

    testWidgets('a fully successful purge clears any prior incomplete flag', (
      tester,
    ) async {
      await PurgeRetryState().markIncomplete('stale-uid');
      final trip = await buildTrip();
      PurgeRunOutcome? result;
      await tester.pumpWidget(
        ProviderScope(
          overrides: overridesFor(trip),
          child: MaterialApp(home: _Probe(onResult: (o) => result = o)),
        ),
      );

      await tapAndWait(tester, 'go');

      expect(result!.isFullSuccess, isTrue);
      expect(await PurgeRetryState().isIncomplete(), isFalse);
    });

    testWidgets(
      'one failing item lists it (French) and marks the flag incomplete '
      'with the uid (Task 6 review round 1, I2)',
      (tester) async {
        // Force the 'edges' step to fail. Real dart:io — must run inside
        // runAsync, or the bare await never completes (see
        // export_data_tile_test.dart's note on this exact trap).
        final edgesFile = File('${tempDir.path}/covered_edges.db');
        await tester.runAsync(() async {
          await edgesFile.parent.create(recursive: true);
          await edgesFile.writeAsString('not a real sqlite file');
        });

        final trip = await buildTrip();
        PurgeRunOutcome? result;
        await tester.pumpWidget(
          ProviderScope(
            overrides: overridesFor(trip),
            child: MaterialApp(
              home: _Probe(uid: 'u1', onResult: (o) => result = o),
            ),
          ),
        );

        await tapAndWait(tester, 'go');

        expect(result!.failures, contains('edges'));
        expect(
          frenchPurgeLabels(result!.failures),
          contains('zones explorées'),
        );
        expect(await PurgeRetryState().isIncomplete(), isTrue);
        expect(await PurgeRetryState().pendingUid(), 'u1');
      },
    );
  });

  group('PurgeRetryTile', () {
    testWidgets('invisible when nothing is pending', (tester) async {
      final trip = await buildTrip();
      await tester.pumpWidget(
        ProviderScope(
          overrides: overridesFor(trip),
          child: const MaterialApp(home: Scaffold(body: PurgeRetryTile())),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Réessayer la suppression des données locales'),
        findsNothing,
      );
    });

    testWidgets('visible when a purge was left incomplete; retrying after the '
        'underlying problem is fixed succeeds and clears the flag (Task 6 '
        'review round 1, I2)', (tester) async {
      // Same forced failure as above, left in place when the flag was set.
      final edgesFile = File('${tempDir.path}/covered_edges.db');
      await tester.runAsync(() async {
        await edgesFile.parent.create(recursive: true);
        await edgesFile.writeAsString('not a real sqlite file');
      });
      await PurgeRetryState().markIncomplete('u1');

      final trip = await buildTrip();
      await tester.pumpWidget(
        ProviderScope(
          overrides: overridesFor(trip),
          child: const MaterialApp(home: Scaffold(body: PurgeRetryTile())),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Réessayer la suppression des données locales'),
        findsOneWidget,
      );

      // Fix the underlying problem, then retry — tapAndWait's default wait
      // (see its own doc comment) already budgets enough real time for this
      // tap's `_retry` to run the full `runLocalPurge` chain before its
      // trailing `setState` (which is what actually hides this tile) fires.
      await tester.runAsync(() => edgesFile.delete());
      await tapAndWait(tester, 'Réessayer la suppression des données locales');

      expect(find.text('Données locales supprimées.'), findsOneWidget);
      expect(await PurgeRetryState().isIncomplete(), isFalse);
      // The tile hides itself again now that nothing is pending.
      expect(
        find.text('Réessayer la suppression des données locales'),
        findsNothing,
      );
    });

    testWidgets('retrying while a trip is interrupted refuses with the shared '
        'message and leaves the incomplete flag set (Task 6 review round 2)', (
      tester,
    ) async {
      await PurgeRetryState().markIncomplete('u1');
      final trip = await buildTrip(interrupted: true);
      expect(trip.isInterrupted, isTrue);

      await tester.pumpWidget(
        ProviderScope(
          overrides: overridesFor(trip),
          child: const MaterialApp(home: Scaffold(body: PurgeRetryTile())),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Réessayer la suppression des données locales'),
        findsOneWidget,
      );

      await tapAndWait(tester, 'Réessayer la suppression des données locales');

      expect(find.text(kPurgeRefusedTripActiveMessage), findsOneWidget);
      expect(await PurgeRetryState().isIncomplete(), isTrue);
      // Still pending — the tile stays visible for a later retry.
      expect(
        find.text('Réessayer la suppression des données locales'),
        findsOneWidget,
      );
    });
  });
}
