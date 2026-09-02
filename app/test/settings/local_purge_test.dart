import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:randomwalk/exploration/edges_store.dart';
import 'package:randomwalk/settings/local_purge.dart';
import 'package:randomwalk/sync/sync_state_store.dart';
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
  });
}
