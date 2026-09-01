import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/game/reducers.dart';
import 'package:randomwalk/sync/backend.dart';
import 'package:randomwalk/sync/sync_engine.dart';
import 'package:randomwalk/sync/sync_state_store.dart';

import '../support/fake_sync_backend.dart';

/// In-memory [SyncStateStore] — a real device would use
/// [PrefsSyncStateStore] (see sync_state_store_test.dart for its own
/// coverage); tests use this so each simulated device's checkpoint is
/// trivially isolated from every other's, with no shared-prefs plumbing.
class _MemoryStateStore implements SyncStateStore {
  SyncCursorState _state = const SyncCursorState();

  @override
  Future<SyncCursorState> read() async => _state;

  @override
  Future<void> write(SyncCursorState state) async => _state = state;
}

void main() {
  late Directory tempDir;
  var seq = 0;

  GameEvent ev(
    String type,
    DateTime ts,
    Map<String, dynamic> payload, {
    String? id,
  }) {
    seq++;
    return GameEvent(
      id: id ?? 'e${seq}_${identityHashCode(ts)}_$type',
      ts: ts,
      type: type,
      payload: payload,
    );
  }

  setUp(() async {
    seq = 0;
    tempDir = await Directory.systemTemp.createTemp('sync_engine_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  GameJournal newJournal(String name) =>
      GameJournal(Directory('${tempDir.path}/$name'));

  final t0 = DateTime.utc(2026, 9, 1, 12);

  group('push', () {
    test('pushes every local event on a fresh journal, once', () async {
      final journal = newJournal('a');
      await journal.appendAll([
        ev(GameEventTypes.coinsEarned, t0, {'amount': 10}),
        ev(GameEventTypes.coinsEarned, t0, {'amount': 5}),
      ]);
      final backend = FakeSyncBackend();
      final engine = SyncEngine(
        journal: journal,
        backend: backend,
        stateStore: _MemoryStateStore(),
      );

      final report = await engine.sync();

      expect(report.pushedCount, 2);
      expect(backend.pushCallCount, 1);
      expect(backend.serverEvents, hasLength(2));
    });

    test('a second sync() with nothing new locally does not call pushEvents '
        'again', () async {
      final journal = newJournal('a');
      await journal.append(ev(GameEventTypes.coinsEarned, t0, {'amount': 10}));
      final backend = FakeSyncBackend();
      final store = _MemoryStateStore();
      final engine = SyncEngine(
        journal: journal,
        backend: backend,
        stateStore: store,
      );

      await engine.sync();
      expect(backend.pushCallCount, 1);
      await engine.sync();
      expect(backend.pushCallCount, 1); // no redundant push
    });

    test('a newly-appended local event after a prior sync is pushed on the '
        'next sync only', () async {
      final journal = newJournal('a');
      await journal.append(ev(GameEventTypes.coinsEarned, t0, {'amount': 10}));
      final backend = FakeSyncBackend();
      final engine = SyncEngine(
        journal: journal,
        backend: backend,
        stateStore: _MemoryStateStore(),
      );
      await engine.sync();
      expect(backend.serverEvents, hasLength(1));

      await journal.append(ev(GameEventTypes.coinsEarned, t0, {'amount': 20}));
      final report = await engine.sync();
      expect(report.pushedCount, 1);
      expect(backend.serverEvents, hasLength(2));
    });

    test('crash recovery: a push whose success response is lost (the backend '
        'committed but threw) is safely re-pushed next sync, never lost, '
        'never duplicated server-side', () async {
      final journal = newJournal('a');
      await journal.append(
        ev(GameEventTypes.coinsEarned, t0, {'amount': 10}, id: 'ev-1'),
      );
      final backend = FakeSyncBackend()
        ..pushError = const SyncNetworkError('response lost')
        ..pushErrorPersistsEvents = true;
      final store = _MemoryStateStore();
      final engine = SyncEngine(
        journal: journal,
        backend: backend,
        stateStore: store,
      );

      await expectLater(engine.sync(), throwsA(isA<SyncNetworkError>()));
      // Server actually has it (the "response was lost" simulation), but
      // the engine doesn't know that yet — its checkpoint is unchanged.
      expect(backend.serverEvents, hasLength(1));
      expect((await store.read()).pushedIndex, 0);

      // Next sync retries the same event; the server dedupes it rather
      // than duplicating it (ON CONFLICT DO NOTHING).
      backend.pushError = null;
      final report = await engine.sync();
      expect(report.pushedCount, 1);
      expect(backend.serverEvents, hasLength(1)); // still just one
      expect((await store.read()).pushedIndex, 1);
    });

    test('a push failure aborts the whole sync() call before any pull is '
        'attempted', () async {
      final journal = newJournal('a');
      await journal.append(ev(GameEventTypes.coinsEarned, t0, {'amount': 10}));
      final backend = FakeSyncBackend()
        ..pushError = const SyncNetworkError('offline');
      final engine = SyncEngine(
        journal: journal,
        backend: backend,
        stateStore: _MemoryStateStore(),
      );

      await expectLater(engine.sync(), throwsA(isA<SyncNetworkError>()));
      expect(backend.pullCallCount, 0);
    });

    test('a pull failure after a successful push still keeps the push '
        "checkpoint durable — the sync() call throws, but the push isn't "
        'redone next time', () async {
      final journal = newJournal('a');
      await journal.append(ev(GameEventTypes.coinsEarned, t0, {'amount': 10}));
      final backend = FakeSyncBackend()
        ..pullError = const SyncNetworkError('offline mid-pull');
      final store = _MemoryStateStore();
      final engine = SyncEngine(
        journal: journal,
        backend: backend,
        stateStore: store,
      );

      await expectLater(engine.sync(), throwsA(isA<SyncNetworkError>()));
      expect(backend.pushCallCount, 1);
      expect((await store.read()).pushedIndex, 1); // push was persisted

      backend.pullError = null;
      final report = await engine.sync();
      expect(backend.pushCallCount, 1); // not re-pushed
      expect(report.pushedCount, 0);
    });
  });

  group('pull + merge', () {
    test(
      'merges remote events with unknown ids into the local journal',
      () async {
        final journal = newJournal('a');
        final backend = FakeSyncBackend()
          ..seedServer([
            ev(GameEventTypes.coinsEarned, t0, {'amount': 40}, id: 'r-1'),
          ]);
        final engine = SyncEngine(
          journal: journal,
          backend: backend,
          stateStore: _MemoryStateStore(),
        );

        final report = await engine.sync();

        expect(report.pulledCount, 1);
        final events = await journal.readAll();
        expect(events.map((e) => e.id), ['r-1']);
        expect(reduceAll(events).coins, 40);
      },
    );

    test('an already-known id pulled back (e.g. our own echoed push) is never '
        'appended twice', () async {
      final journal = newJournal('a');
      await journal.append(
        ev(GameEventTypes.coinsEarned, t0, {'amount': 10}, id: 'ev-1'),
      );
      final backend = FakeSyncBackend();
      final store = _MemoryStateStore();
      final engine = SyncEngine(
        journal: journal,
        backend: backend,
        stateStore: store,
      );
      await engine.sync(); // pushes ev-1; server now has it too

      // A later sync pulls the same event back (as any real account-wide
      // pull would echo this device's own previously-pushed events).
      final report = await engine.sync();
      expect(report.pulledCount, 0);
      expect(await journal.readAll(), hasLength(1));
    });

    test('never mutates existing journal lines — only appends', () async {
      final journal = newJournal('a');
      final original = ev(GameEventTypes.coinsEarned, t0, {
        'amount': 10,
      }, id: 'local-1');
      await journal.append(original);
      final backend = FakeSyncBackend()
        ..seedServer([
          ev(GameEventTypes.coinsEarned, t0, {'amount': 5}, id: 'remote-1'),
        ]);
      final engine = SyncEngine(
        journal: journal,
        backend: backend,
        stateStore: _MemoryStateStore(),
      );

      await engine.sync();

      final events = await journal.readAll();
      expect(events.first.id, 'local-1');
      expect(events.first.payload['amount'], 10); // untouched
      expect(events.last.id, 'remote-1');
    });

    test(
      'paginates through multiple pages until the server is exhausted',
      () async {
        final journal = newJournal('a');
        final backend = FakeSyncBackend(pageSize: 2)
          ..seedServer([
            for (var i = 0; i < 5; i++)
              ev(GameEventTypes.coinsEarned, t0, {'amount': 1}, id: 'r-$i'),
          ]);
        final engine = SyncEngine(
          journal: journal,
          backend: backend,
          stateStore: _MemoryStateStore(),
        );

        final report = await engine.sync();

        expect(report.pulledCount, 5);
        expect(backend.pullCallCount, 4); // 2 + 2 + 1 + empty
        expect(await journal.readAll(), hasLength(5));
      },
    );

    test('onRecompute fires once when something was pulled, never when '
        'only a push happened', () async {
      final journalPushOnly = newJournal('push-only');
      await journalPushOnly.append(
        ev(GameEventTypes.coinsEarned, t0, {'amount': 10}),
      );
      var recomputed = 0;
      final engine1 = SyncEngine(
        journal: journalPushOnly,
        backend: FakeSyncBackend(),
        stateStore: _MemoryStateStore(),
        onRecompute: () => recomputed++,
      );
      await engine1.sync();
      expect(recomputed, 0);

      final journalPull = newJournal('pull');
      final backend2 = FakeSyncBackend()
        ..seedServer([
          ev(GameEventTypes.coinsEarned, t0, {'amount': 10}, id: 'r-1'),
        ]);
      final engine2 = SyncEngine(
        journal: journalPull,
        backend: backend2,
        stateStore: _MemoryStateStore(),
        onRecompute: () => recomputed++,
      );
      await engine2.sync();
      expect(recomputed, 1);
    });
  });

  group('push marker: catch-up set', () {
    test(
      'merged remote ids past the pushed prefix are never re-uploaded, and '
      'compact back into the prefix once a pending local event is pushed',
      () async {
        final journal = newJournal('a');
        final localA = ev(GameEventTypes.coinsEarned, t0, {
          'amount': 1,
        }, id: 'local-a');
        final remoteX = ev(GameEventTypes.coinsEarned, t0, {
          'amount': 2,
        }, id: 'remote-x');
        final remoteY = ev(GameEventTypes.coinsEarned, t0, {
          'amount': 3,
        }, id: 'remote-y');
        // Journal order: an unpushed local event, THEN two events a prior
        // merge already appended (already known server-side) — the exact
        // shape a concurrent local write racing a merge produces: the
        // catch-up set is what lets push skip remoteX/remoteY even though
        // they're not at a contiguous prefix from pushedIndex.
        await journal.appendAll([localA, remoteX, remoteY]);
        final store = _MemoryStateStore();
        await store.write(
          SyncCursorState(
            pushedIndex: 0,
            pushedCatchupIds: {'remote-x', 'remote-y'},
          ),
        );
        final backend = FakeSyncBackend();
        // The fake's own bookkeeping doesn't know about remoteX/remoteY
        // (a real backend would, since another device pushed them) — that
        // doesn't matter for this test, which only asserts what THIS
        // engine chooses to upload.
        final engine = SyncEngine(
          journal: journal,
          backend: backend,
          stateStore: store,
        );

        final report = await engine.sync();

        expect(report.pushedCount, 1);
        expect(backend.serverEvents.map((e) => e.id), ['local-a']);

        final finalState = await store.read();
        expect(finalState.pushedIndex, 3); // fully compacted
        expect(finalState.pushedCatchupIds, isEmpty);
      },
    );
  });

  group('multi-device convergence', () {
    test('two journals, same reducers, cross-synced via one shared fake '
        'backend, converge on an identical GameState', () async {
      final journalA = newJournal('device-a');
      final journalB = newJournal('device-b');
      final sharedBackend = FakeSyncBackend();
      final engineA = SyncEngine(
        journal: journalA,
        backend: sharedBackend,
        stateStore: _MemoryStateStore(),
      );
      final engineB = SyncEngine(
        journal: journalB,
        backend: sharedBackend,
        stateStore: _MemoryStateStore(),
      );

      // Device A: an early trip.
      await journalA.appendAll([
        ev(GameEventTypes.edgeCoveredBatch, t0, {'km': 3.0}, id: 'a-trip'),
        ev(GameEventTypes.landmarkVisited, t0, {
          'poiId': 'bank-1',
          'kind': 'coins',
        }, id: 'a-visit'),
      ]);
      await engineA.sync(); // pushes A's events

      // Device B: a later trip, plus a second (cooldown-passing) visit to
      // the SAME landmark A already visited — chronologically 25h after
      // A's visit, so once merged this must be rewarded, not blocked.
      final bVisitTs = t0.add(const Duration(hours: 25));
      await journalB.appendAll([
        ev(GameEventTypes.edgeCoveredBatch, bVisitTs, {
          'km': 2.0,
        }, id: 'b-trip'),
        ev(GameEventTypes.landmarkVisited, bVisitTs, {
          'poiId': 'bank-1',
          'kind': 'coins',
        }, id: 'b-visit'),
      ]);
      await engineB.sync(); // pushes B's events, pulls+merges A's

      // Device A syncs again, pulling+merging B's events.
      await engineA.sync();

      final stateA = reduceAll(await journalA.readAll());
      final stateB = reduceAll(await journalB.readAll());

      expect(stateA, stateB);
      expect(stateA.totalKm, 5.0);
      expect(stateA.coins, 150); // 100 (a-visit) + 50 (b-visit, 25h later)
      expect(stateA.landmarksVisited, 1); // same poiId both times
    });
  });
}
