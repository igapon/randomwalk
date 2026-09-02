import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:randomwalk/exploration/edges_store.dart';
import 'package:randomwalk/history/trip_history_store.dart';
import 'package:randomwalk/settings/local_purge.dart';
import 'package:randomwalk/sync/sync_state_store.dart';
import 'package:randomwalk/valhalla/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/temp_dir.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('local_purge_test');
  });

  tearDown(() => deleteTempDirRetrying(dir));

  Future<File> writeFile(String relativePath, [String content = 'x']) async {
    final file = File('${dir.path}/$relativePath');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return file;
  }

  group('purge()', () {
    test('deletes game_events.jsonl', () async {
      final journal = await writeFile('game/game_events.jsonl');
      await LocalDataPurge(dir).purge();
      expect(await journal.exists(), isFalse);
    });

    test('deletes game_state_checkpoint.json', () async {
      final checkpoint = await writeFile('game/game_state_checkpoint.json');
      await LocalDataPurge(dir).purge();
      expect(await checkpoint.exists(), isFalse);
    });

    test('deletes active_track.jsonl', () async {
      final track = await writeFile('active_track.jsonl');
      await LocalDataPurge(dir).purge();
      expect(await track.exists(), isFalse);
    });

    test(
      'clears the covered-edges store rather than deleting its file — '
      'see EdgesStore.clear\'s dartdoc on why (a live handle elsewhere in '
      'the process could otherwise be left holding a stale connection)',
      () async {
        final store = await EdgesStore.open('${dir.path}/covered_edges.db');
        await store.upsertAll(['1', '2'], DateTime.utc(2026, 8, 30));
        await store.close();

        await LocalDataPurge(dir).purge();

        final reopened = await EdgesStore.open('${dir.path}/covered_edges.db');
        expect(await reopened.totalCount, 0);
        await reopened.close();
        // The file itself is still there — it was cleared, not deleted.
        expect(await File('${dir.path}/covered_edges.db').exists(), isTrue);
      },
    );

    test('is a no-op, not a failure, when none of the files exist yet '
        '(a brand-new install with nothing played)', () async {
      final failures = await LocalDataPurge(dir).purge();
      expect(failures, isEmpty);
    });

    test('when uid is given, also deletes that account\'s sync-state prefs '
        'keys', () async {
      await PrefsSyncStateStore(
        'uid-a',
      ).write(const SyncCursorState(pushedIndex: 7, pullCursor: 'c1'));

      await LocalDataPurge(dir).purge(uid: 'uid-a');

      final state = await PrefsSyncStateStore('uid-a').read();
      expect(state.pushedIndex, 0);
      expect(state.pullCursor, isNull);
    });

    test('when uid is null, leaves every sync-state key untouched', () async {
      await PrefsSyncStateStore(
        'uid-a',
      ).write(const SyncCursorState(pushedIndex: 7));

      await LocalDataPurge(dir).purge();

      final state = await PrefsSyncStateStore('uid-a').read();
      expect(state.pushedIndex, 7);
    });

    test('one step failing never stops the others from running — e.g. an '
        'unreadable covered_edges.db still lets the journal/checkpoint/'
        'track files get deleted', () async {
      final journal = await writeFile('game/game_events.jsonl');
      final checkpoint = await writeFile('game/game_state_checkpoint.json');
      // Not valid sqlite — EdgesStore.open will fail against it.
      await writeFile('covered_edges.db', 'not a real sqlite file');

      final failures = await LocalDataPurge(dir).purge();

      expect(failures, contains('edges'));
      expect(await journal.exists(), isFalse);
      expect(await checkpoint.exists(), isFalse);
    });

    group('trip history (Task 6 review round 1, Critical)', () {
      test('clears every row AND deletes the trip_history.db file itself — '
          'the confirmation dialog promises "parcours" are removed from '
          'disk, not just emptied', () async {
        final path = '${dir.path}/trip_history.db';
        final store = await TripHistoryStore.open(path);
        await store.record(
          TripHistoryEntry(
            startedAt: DateTime.utc(2026, 8, 30, 9),
            endedAt: DateTime.utc(2026, 8, 30, 9, 30),
            profile: RoutingProfile.walk,
            distanceKm: 2.5,
            duration: const Duration(minutes: 30),
            avgSpeedKmh: 5,
          ),
        );
        await store.close();

        final failures = await LocalDataPurge(dir).purge();

        expect(failures, isEmpty);
        expect(await File(path).exists(), isFalse);
        final reopened = await TripHistoryStore.open(path);
        expect(await reopened.list(), isEmpty);
        await reopened.close();
      });

      test(
        'is a no-op, not a failure, when no trip was ever recorded',
        () async {
          final failures = await LocalDataPurge(dir).purge();
          expect(failures, isEmpty);
          expect(await File('${dir.path}/trip_history.db').exists(), isFalse);
        },
      );
    });

    group('trip snapshot (Task 6 review round 1, Important I1)', () {
      test(
        'deletes trip_snapshot.json — same category as active_track.jsonl',
        () async {
          final snapshot = await writeFile('trip_snapshot.json', '{}');
          await LocalDataPurge(dir).purge();
          expect(await snapshot.exists(), isFalse);
        },
      );

      test('is a no-op when no trip snapshot exists', () async {
        final failures = await LocalDataPurge(dir).purge();
        expect(failures, isEmpty);
      });
    });
  });

  group('frenchPurgeLabels', () {
    test('renders known failure labels in French', () {
      expect(
        frenchPurgeLabels(['edges', 'trip-history']),
        'zones explorées, historique des parcours',
      );
    });

    test('falls back to the raw label for an unrecognized one', () {
      expect(frenchPurgeLabels(['mystery-step']), 'mystery-step');
    });

    test('is empty for no failures', () {
      expect(frenchPurgeLabels(const []), '');
    });
  });

  group('PurgeRetryState (Task 6 review round 1, Important I2)', () {
    test('starts incomplete: false, with no pending uid', () async {
      final state = PurgeRetryState();
      expect(await state.isIncomplete(), isFalse);
      expect(await state.pendingUid(), isNull);
    });

    test('markIncomplete then isIncomplete/pendingUid round-trip', () async {
      final state = PurgeRetryState();
      await state.markIncomplete('u1');
      expect(await state.isIncomplete(), isTrue);
      expect(await state.pendingUid(), 'u1');
    });

    test(
      'markIncomplete with a null uid clears any previously-pending one',
      () async {
        final state = PurgeRetryState();
        await state.markIncomplete('u1');
        await state.markIncomplete(null);
        expect(await state.isIncomplete(), isTrue);
        expect(await state.pendingUid(), isNull);
      },
    );

    test('clear() resets both isIncomplete and pendingUid', () async {
      final state = PurgeRetryState();
      await state.markIncomplete('u1');
      await state.clear();
      expect(await state.isIncomplete(), isFalse);
      expect(await state.pendingUid(), isNull);
    });
  });
}
