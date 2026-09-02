import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/game/game_state_provider.dart';
import 'package:randomwalk/settings/local_purge.dart';
import 'package:randomwalk/tracking/permissions.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/trip/trip_controller.dart';
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

  Future<TripController> buildTrip({bool recording = false}) async {
    final trip = TripController(
      tracker: FakeTripTracker(),
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
    if (recording) await trip.startTrip();
    return trip;
  }

  List<Override> overridesFor(TripController trip) => [
    gameJournalProvider.overrideWith(
      (ref) async => GameJournal(Directory('${tempDir.path}/journal')),
    ),
    tripControllerProvider.overrideWith((ref) => trip),
  ];

  Future<void> tapAndWait(
    WidgetTester tester,
    String text, {
    Duration wait = const Duration(milliseconds: 100),
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

      // Fix the underlying problem, then retry. Same generous real-time
      // budget account_screen_test.dart's equivalent purge tap needs — this
      // one tap's `_retry` runs the exact same `runLocalPurge` call (now
      // seven real I/O steps: journal/checkpoint/edges/trip-history/
      // trip-snapshot/track/sync-state) before its own trailing `setState`
      // (which is what actually hides this tile) ever fires; the default
      // 100 ms isn't reliably enough real time for all of that to land
      // before `pumpAndSettle` stops finding new frames to pump.
      await tester.runAsync(() => edgesFile.delete());
      await tapAndWait(
        tester,
        'Réessayer la suppression des données locales',
        wait: const Duration(milliseconds: 1000),
      );

      expect(find.text('Données locales supprimées.'), findsOneWidget);
      expect(await PurgeRetryState().isIncomplete(), isFalse);
      // The tile hides itself again now that nothing is pending.
      expect(
        find.text('Réessayer la suppression des données locales'),
        findsNothing,
      );
    });
  });
}
