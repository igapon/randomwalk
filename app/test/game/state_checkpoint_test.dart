import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/game/reducers.dart';
import 'package:randomwalk/game/state_checkpoint.dart';

import '../support/temp_dir.dart';

const _allTypes = [
  GameEventTypes.edgeCoveredBatch,
  GameEventTypes.cellRevealed,
  GameEventTypes.landmarkVisited,
  GameEventTypes.coinsEarned,
  GameEventTypes.coinsSpent,
  GameEventTypes.energyChanged,
  GameEventTypes.xpEarned,
  GameEventTypes.badgeUnlocked,
  GameEventTypes.streakUpdated,
  GameEventTypes.loopCompleted,
];

const _poiIds = ['poi-a', 'poi-b', 'poi-c', 'poi-d', 'poi-e'];
const _kinds = ['coins', 'energy', 'reveal'];
const _subkinds = ['restaurant', 'cafe', 'fast_food', 'unknown'];

String _formatDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Map<String, dynamic> _payloadFor(String type, Random rnd, DateTime ts) {
  switch (type) {
    case GameEventTypes.edgeCoveredBatch:
      return {'km': rnd.nextDouble() * 5};
    case GameEventTypes.cellRevealed:
      return {
        'cells': [
          for (var i = 0; i < rnd.nextInt(3) + 1; i++)
            'x:${rnd.nextInt(200)},y:${rnd.nextInt(200)}',
        ],
      };
    case GameEventTypes.landmarkVisited:
      final kind = _kinds[rnd.nextInt(_kinds.length)];
      return {
        'poiId': _poiIds[rnd.nextInt(_poiIds.length)],
        'kind': kind,
        if (kind == 'energy')
          'subkind': _subkinds[rnd.nextInt(_subkinds.length)],
      };
    case GameEventTypes.coinsEarned:
      return {'amount': rnd.nextInt(50) + 1};
    case GameEventTypes.coinsSpent:
      return {'amount': rnd.nextInt(30) + 1};
    case GameEventTypes.energyChanged:
      return {'delta': (rnd.nextInt(21) - 10).toDouble()};
    case GameEventTypes.xpEarned:
      return {'amount': rnd.nextInt(40) + 1, 'preMultiplied': rnd.nextBool()};
    case GameEventTypes.badgeUnlocked:
      return {'badge': 'badge-${rnd.nextInt(5)}'};
    case GameEventTypes.streakUpdated:
      final day = ts.add(Duration(days: rnd.nextInt(5) - 2));
      return {'day': _formatDay(day)};
    default: // loopCompleted
      return {};
  }
}

int _idCounter = 0;

GameEvent _randomEvent(Random rnd, DateTime ts) {
  final type = _allTypes[rnd.nextInt(_allTypes.length)];
  return GameEvent(
    id: 'evt-${_idCounter++}',
    ts: ts,
    type: type,
    payload: _payloadFor(type, rnd, ts),
  );
}

/// Polls [store] until it returns a checkpoint (optionally one matching
/// [fileEventCount] exactly) or [timeout] elapses.
///
/// [loadStateFast] fires its checkpoint write off `unawaited` and
/// deliberately never lets a caller wait on it (see state_checkpoint.dart's
/// "checkpoint writes never block gameplay") — and that write is genuine
/// disk I/O, not just a chain of microtasks: `pumpEventQueue()` (which only
/// drains Dart-level microtasks/zero-duration timers) is NOT sufficient to
/// observe it land, confirmed empirically against this exact store. Tests
/// that need to see a specific checkpoint on disk poll for it here instead
/// of guessing a fixed delay.
Future<GameStateCheckpoint> _waitForCheckpoint(
  GameStateCheckpointStore store, {
  int? fileEventCount,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  GameStateCheckpoint? last;
  while (DateTime.now().isBefore(deadline)) {
    last = await store.read();
    if (last != null &&
        (fileEventCount == null || last.fileEventCount == fileEventCount)) {
      return last;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(
    'checkpoint did not reach fileEventCount=$fileEventCount within '
    '$timeout (last read: $last)',
  );
}

void main() {
  late Directory tempDir;
  late GameJournal journal;
  late GameStateCheckpointStore store;

  setUp(() async {
    _idCounter = 0;
    tempDir = await Directory.systemTemp.createTemp('state_checkpoint_test');
    journal = GameJournal(Directory('${tempDir.path}/journal'));
    store = GameStateCheckpointStore(journal.dir);
  });

  tearDown(() async {
    // loadStateFast fires its checkpoint write off deliberately unawaited
    // (see state_checkpoint.dart) — deleteTempDirRetrying tolerates that
    // write still being in flight when this runs (see its own dartdoc).
    await deleteTempDirRetrying(tempDir);
  });

  group('GameStateCheckpoint JSON round-trip', () {
    test('every field survives toJson -> fromJson', () {
      final state = reduceAll([
        GameEvent(
          id: 'e1',
          ts: DateTime.utc(2026, 1, 1),
          type: GameEventTypes.coinsEarned,
          payload: const {'amount': 40},
        ),
        GameEvent(
          id: 'e2',
          ts: DateTime.utc(2026, 1, 2),
          type: GameEventTypes.landmarkVisited,
          payload: const {'poiId': 'poi-a', 'kind': 'coins'},
        ),
        GameEvent(
          id: 'e3',
          ts: DateTime.utc(2026, 1, 3),
          type: GameEventTypes.streakUpdated,
          payload: const {'day': '2026-01-03'},
        ),
      ]);
      final checkpoint = GameStateCheckpoint(
        fileEventCount: 3,
        skippedLinesAtCheckpoint: 1,
        maxTs: DateTime.utc(2026, 1, 3),
        prefixHash: 'deadbeef',
        state: state,
      );

      final roundTripped = GameStateCheckpoint.fromJson(
        jsonDecode(jsonEncode(checkpoint.toJson())) as Map<String, dynamic>,
      );

      expect(roundTripped.fileEventCount, 3);
      expect(roundTripped.skippedLinesAtCheckpoint, 1);
      expect(roundTripped.maxTs, DateTime.utc(2026, 1, 3));
      expect(roundTripped.prefixHash, 'deadbeef');
      expect(roundTripped.state, state);
    });

    test('null maxTs and zero state round-trip too', () {
      const checkpoint = GameStateCheckpoint(
        fileEventCount: 0,
        skippedLinesAtCheckpoint: 0,
        maxTs: null,
        prefixHash: '',
        state: GameState(),
      );
      final roundTripped = GameStateCheckpoint.fromJson(
        jsonDecode(jsonEncode(checkpoint.toJson())) as Map<String, dynamic>,
      );
      expect(roundTripped.maxTs, isNull);
      expect(roundTripped.state, const GameState());
    });

    test('an unrecognized version throws (caught by the store, never by '
        'callers of loadStateFast)', () {
      final json = {
        'version': 999,
        'fileEventCount': 0,
        'skippedLinesAtCheckpoint': 0,
        'maxTs': null,
        'prefixHash': '',
        'state': const GameStateCheckpoint(
          fileEventCount: 0,
          skippedLinesAtCheckpoint: 0,
          maxTs: null,
          prefixHash: '',
          state: GameState(),
        ).toJson()['state'],
      };
      expect(() => GameStateCheckpoint.fromJson(json), throwsFormatException);
    });
  });

  group('GameStateCheckpointStore', () {
    test('read() is null when no file exists yet', () async {
      expect(await store.read(), isNull);
    });

    test('write then read round-trips', () async {
      const checkpoint = GameStateCheckpoint(
        fileEventCount: 5,
        skippedLinesAtCheckpoint: 0,
        maxTs: null,
        prefixHash: 'abc',
        state: GameState(coins: 10),
      );
      await store.write(checkpoint);
      final read = await store.read();
      expect(read, isNotNull);
      expect(read!.fileEventCount, 5);
      expect(read.state.coins, 10);
    });

    test('a garbage (non-JSON) file reads as null, never throws', () async {
      final file = File('${journal.dir.path}/game_state_checkpoint.json');
      await file.parent.create(recursive: true);
      await file.writeAsString('{not valid json[[[');
      expect(await store.read(), isNull);
    });

    test('an empty file reads as null', () async {
      final file = File('${journal.dir.path}/game_state_checkpoint.json');
      await file.parent.create(recursive: true);
      await file.writeAsString('   ');
      expect(await store.read(), isNull);
    });

    test('a well-formed JSON document with an unsupported version reads as '
        'null', () async {
      final file = File('${journal.dir.path}/game_state_checkpoint.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'version': 2,
          'fileEventCount': 1,
          'skippedLinesAtCheckpoint': 0,
          'maxTs': null,
          'prefixHash': '',
          'state': {},
        }),
      );
      expect(await store.read(), isNull);
    });
  });

  group('loadStateFast basics', () {
    test('empty journal resolves to the zero GameState, no checkpoint '
        'written', () async {
      final state = await loadStateFast(journal, store);
      expect(state, const GameState());
      // _maybeWriteCheckpoint's `events.isEmpty` guard returns before ever
      // touching disk (synchronously, before its first `await`) — so by
      // the time the `unawaited` call above has even been issued, "no
      // write will happen" is already decided; no wait needed to observe
      // it.
      expect(await store.read(), isNull);
    });

    test('with no checkpoint yet, matches a full reduceAll', () async {
      await journal.appendAll([
        GameEvent(
          id: 'e1',
          ts: DateTime.utc(2026, 1, 1),
          type: GameEventTypes.coinsEarned,
          payload: const {'amount': 25},
        ),
        GameEvent(
          id: 'e2',
          ts: DateTime.utc(2026, 1, 2),
          type: GameEventTypes.xpEarned,
          payload: const {'amount': 10, 'preMultiplied': true},
        ),
      ]);
      final fast = await loadStateFast(journal, store);
      final full = reduceAll(await journal.readAll());
      expect(fast, full);
      expect(fast.coins, 25);
      expect(fast.xp, 10);
    });

    test('a first successful load writes a checkpoint covering the whole '
        'journal at that point', () async {
      await journal.appendAll([
        GameEvent(
          id: 'e1',
          ts: DateTime.utc(2026, 1, 1),
          type: GameEventTypes.coinsEarned,
          payload: const {'amount': 25},
        ),
      ]);
      await loadStateFast(journal, store);

      final checkpoint = await _waitForCheckpoint(store, fileEventCount: 1);
      expect(checkpoint.state.coins, 25);
    });

    test('checkpoint writes stay periodic: a small addition below the '
        'interval does not move fileEventCount', () async {
      await journal.appendAll([
        for (var i = 0; i < 10; i++)
          GameEvent(
            id: 'e$i',
            ts: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
            type: GameEventTypes.coinsEarned,
            payload: const {'amount': 1},
          ),
      ]);
      await loadStateFast(journal, store, intervalEvents: 20);
      await _waitForCheckpoint(store, fileEventCount: 10);

      await journal.append(
        GameEvent(
          id: 'e10',
          ts: DateTime.utc(2026, 1, 1).add(const Duration(minutes: 10)),
          type: GameEventTypes.coinsEarned,
          payload: const {'amount': 1},
        ),
      );
      final state = await loadStateFast(journal, store, intervalEvents: 20);
      // _maybeWriteCheckpoint's `since < intervalEvents` guard (11 new
      // events total, checkpoint was at 10, interval is 20) also returns
      // synchronously before touching disk — so, as above, this is already
      // decided and needs no wait to observe.
      final second = await store.read();
      expect(second!.fileEventCount, 10);
      expect(state.coins, 11);

      // Push past the interval: now it must move.
      await journal.appendAll([
        for (var i = 11; i < 31; i++)
          GameEvent(
            id: 'e$i',
            ts: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
            type: GameEventTypes.coinsEarned,
            payload: const {'amount': 1},
          ),
      ]);
      final finalState = await loadStateFast(
        journal,
        store,
        intervalEvents: 20,
      );
      final third = await _waitForCheckpoint(store, fileEventCount: 31);
      expect(third.state.coins, 31);
      expect(finalState.coins, 31);
    });
  });

  group('invalidation', () {
    test('a shrunk journal (fewer events than the checkpoint) falls back '
        'to a full replay instead of crashing or misreporting', () async {
      await journal.appendAll([
        for (var i = 0; i < 5; i++)
          GameEvent(
            id: 'e$i',
            ts: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
            type: GameEventTypes.coinsEarned,
            payload: const {'amount': 1},
          ),
      ]);
      await loadStateFast(journal, store);
      await _waitForCheckpoint(store, fileEventCount: 5);

      // Simulate the journal being replaced by a shorter file.
      final file = File('${journal.dir.path}/game_events.jsonl');
      final lines = await file.readAsLines();
      await file.writeAsString(lines.take(2).map((l) => '$l\n').join());

      final state = await loadStateFast(journal, store);
      final full = reduceAll(await journal.readAll());
      expect(state, full);
      expect(state.coins, 2);
    });

    test('a rewritten prefix (same length, different content) is caught by '
        'the prefix hash and falls back correctly', () async {
      await journal.appendAll([
        for (var i = 0; i < 5; i++)
          GameEvent(
            id: 'e$i',
            ts: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
            type: GameEventTypes.coinsEarned,
            payload: const {'amount': 10},
          ),
      ]);
      await loadStateFast(journal, store);
      final before = await _waitForCheckpoint(store, fileEventCount: 5);
      expect(before.state.coins, 50);

      // Rewrite the whole file with different (but same-count) events —
      // same shape a hypothetical future compaction could produce.
      final file = File('${journal.dir.path}/game_events.jsonl');
      final replacement = [
        for (var i = 0; i < 5; i++)
          GameEvent(
            id: 'rewritten-$i',
            ts: DateTime.utc(2026, 2, 1).add(Duration(minutes: i)),
            type: GameEventTypes.coinsEarned,
            payload: const {'amount': 3},
          ),
      ];
      await file.writeAsString(
        replacement.map((e) => '${jsonEncode(e.toJson())}\n').join(),
      );

      final state = await loadStateFast(journal, store);
      final full = reduceAll(await journal.readAll());
      expect(state, full);
      expect(state.coins, 15);
    });

    test('a changed skippedLines count (corruption profile changed) falls '
        'back to a full replay', () async {
      await journal.appendAll([
        for (var i = 0; i < 5; i++)
          GameEvent(
            id: 'e$i',
            ts: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
            type: GameEventTypes.coinsEarned,
            payload: const {'amount': 1},
          ),
      ]);
      await loadStateFast(journal, store);
      final established = await _waitForCheckpoint(store, fileEventCount: 5);
      expect(established.skippedLinesAtCheckpoint, 0);

      // Introduce a torn/corrupt line plus a new valid event.
      final file = File('${journal.dir.path}/game_events.jsonl');
      await file.writeAsString(
        'not valid json at all\n',
        mode: FileMode.append,
        flush: true,
      );
      await journal.append(
        GameEvent(
          id: 'e5',
          ts: DateTime.utc(2026, 1, 1).add(const Duration(minutes: 5)),
          type: GameEventTypes.coinsEarned,
          payload: const {'amount': 1},
        ),
      );

      final state = await loadStateFast(journal, store);
      final events = await journal.readAll();
      expect(journal.skippedLines, 1);
      final full = reduceAll(events);
      expect(state, full);
      expect(state.coins, 6);
    });

    test('a corrupt checkpoint file never crashes loadStateFast', () async {
      await journal.appendAll([
        GameEvent(
          id: 'e1',
          ts: DateTime.utc(2026, 1, 1),
          type: GameEventTypes.coinsEarned,
          payload: const {'amount': 7},
        ),
      ]);
      final file = File('${journal.dir.path}/game_state_checkpoint.json');
      await file.parent.create(recursive: true);
      await file.writeAsString('{{{not json');

      final state = await loadStateFast(journal, store);
      expect(state.coins, 7);
    });

    test(
      'a remote-merge tail event whose ts precedes the checkpoint\'s '
      'max ts invalidates the checkpoint and still produces the correct '
      'sorted-replay result (the exact hazard the brief calls out: '
      'SyncEngine.appendAll can land an older-ts event on the tail)',
      () async {
        final t0 = DateTime.utc(2026, 1, 10, 12, 0, 0);
        final t1 = DateTime.utc(2026, 1, 10, 13, 0, 0);
        await journal.appendAll([
          GameEvent(
            id: 'local-1',
            ts: t0,
            type: GameEventTypes.xpEarned,
            payload: const {'amount': 10, 'preMultiplied': true},
          ),
          GameEvent(
            id: 'local-2',
            ts: t1,
            type: GameEventTypes.xpEarned,
            payload: const {'amount': 20, 'preMultiplied': true},
          ),
        ]);
        await loadStateFast(journal, store);
        final checkpoint = await _waitForCheckpoint(store, fileEventCount: 2);
        expect(checkpoint.maxTs, t1);

        // Simulate SyncEngine's merge step: appendAll of a remote event whose
        // own ts is BEFORE t1 (and even before t0), landing at the file tail.
        final olderRemoteTs = t0.subtract(const Duration(hours: 2));
        await journal.append(
          GameEvent(
            id: 'remote-older',
            ts: olderRemoteTs,
            type: GameEventTypes.xpEarned,
            payload: const {'amount': 5, 'preMultiplied': true},
          ),
        );

        final state = await loadStateFast(journal, store);
        final full = reduceAll(await journal.readAll());
        expect(state, full);
        // All three preMultiplied xp_earned amounts always add regardless of
        // order (10 + 20 + 5), so this also cross-checks against a
        // hand-computed expectation, not just self-consistency with reduceAll.
        expect(state.xp, 35);
      },
    );

    test('a remote-merge tail event that sorts AFTER the checkpoint stays '
        'on the fast path and is still correct (contrast case)', () async {
      final t0 = DateTime.utc(2026, 1, 10, 12, 0, 0);
      await journal.appendAll([
        GameEvent(
          id: 'local-1',
          ts: t0,
          type: GameEventTypes.xpEarned,
          payload: const {'amount': 10, 'preMultiplied': true},
        ),
      ]);
      await loadStateFast(journal, store);
      await _waitForCheckpoint(store, fileEventCount: 1);

      await journal.append(
        GameEvent(
          id: 'remote-newer',
          ts: t0.add(const Duration(hours: 1)),
          type: GameEventTypes.xpEarned,
          payload: const {'amount': 5, 'preMultiplied': true},
        ),
      );

      final state = await loadStateFast(journal, store);
      final full = reduceAll(await journal.readAll());
      expect(state, full);
      expect(state.xp, 15);
    });
  });

  group('property: checkpoint+tail equivalence to a full replay', () {
    test('random growth + out-of-order remote-merge patterns always agree '
        'with reduceAll(full journal), across many seeds', () async {
      final seeds = [1, 2, 3, 7, 42, 99, 12345, 777, 2026, 31415];
      for (final seed in seeds) {
        final rnd = Random(seed);
        final dir = await Directory.systemTemp.createTemp(
          'state_checkpoint_property',
        );
        addTearDown(() => deleteTempDirRetrying(dir));
        final propJournal = GameJournal(Directory('${dir.path}/journal'));
        final propStore = GameStateCheckpointStore(propJournal.dir);
        final interval = 5 + rnd.nextInt(20);

        var clock = DateTime.utc(2026, 1, 1);
        final rounds = 12 + rnd.nextInt(10);
        for (var round = 0; round < rounds; round++) {
          final batch = <GameEvent>[];
          final batchSize = 1 + rnd.nextInt(8);
          for (var i = 0; i < batchSize; i++) {
            clock = clock.add(Duration(minutes: 1 + rnd.nextInt(120)));
            batch.add(_randomEvent(rnd, clock));
          }
          // ~40% of rounds also simulate a SyncEngine-style merge: one or
          // more events appended to the tail with an OLDER ts than what's
          // already there — the exact pattern that can precede the
          // checkpoint's last-included sort key.
          if (rnd.nextDouble() < 0.4) {
            final mergeCount = 1 + rnd.nextInt(3);
            for (var i = 0; i < mergeCount; i++) {
              final olderTs = clock.subtract(
                Duration(minutes: rnd.nextInt(600)),
              );
              batch.add(_randomEvent(rnd, olderTs));
            }
          }
          await propJournal.appendAll(batch);

          final fast = await loadStateFast(
            propJournal,
            propStore,
            intervalEvents: interval,
          );
          // Give any unawaited checkpoint write from this round real
          // time to land before the next round's read, so later rounds
          // get a genuine chance to exercise the fast path (not just
          // always falling back because the write hadn't landed yet).
          // Not required for correctness — the assertion below must hold
          // whether or not the write has landed — only for coverage.
          await Future<void>.delayed(const Duration(milliseconds: 15));

          final groundTruth = reduceAll(await propJournal.readAll());
          expect(fast, groundTruth, reason: 'seed=$seed round=$round diverged');
        }
      }
    });
  });

  group('perf: indicative, 10k events', () {
    test('checkpoint+tail replay is comfortably faster than a full replay '
        'once a checkpoint covers most of a 10k-event journal', () async {
      final rnd = Random(20260901);
      var clock = DateTime.utc(2026, 1, 1);
      final all = <GameEvent>[];
      for (var i = 0; i < 10000; i++) {
        clock = clock.add(const Duration(minutes: 3));
        all.add(_randomEvent(rnd, clock));
      }
      await journal.appendAll(all);

      // Baseline: a full reduceAll from scratch (what every load did
      // before this task, and what loadStateFast falls back to with no
      // checkpoint yet).
      final fullStopwatch = Stopwatch()..start();
      final fullState = reduceAll(await journal.readAll());
      fullStopwatch.stop();

      // Establish a checkpoint covering the whole 10k-event journal, then
      // add a small tail — the steady-state shape loadStateFast runs in
      // during normal play (periodic checkpoints, short tails).
      await loadStateFast(journal, store, intervalEvents: 1 << 30);
      await _waitForCheckpoint(
        store,
        fileEventCount: 10000,
        timeout: const Duration(seconds: 15),
      );

      final tail = <GameEvent>[];
      for (var i = 0; i < 50; i++) {
        clock = clock.add(const Duration(minutes: 3));
        tail.add(_randomEvent(rnd, clock));
      }
      await journal.appendAll(tail);

      final fastStopwatch = Stopwatch()..start();
      final fastState = await loadStateFast(
        journal,
        store,
        intervalEvents: 1 << 30, // Don't let this call re-checkpoint.
      );
      fastStopwatch.stop();

      final expected = reduceAll(await journal.readAll());
      expect(fastState, expected);
      expect(fullState.coins, isA<int>()); // Sanity: baseline ran too.

      expect(
        fastStopwatch.elapsedMicroseconds,
        lessThan(fullStopwatch.elapsedMicroseconds),
        reason:
            'indicative perf check (Task 5): checkpoint+tail (50-event '
            'tail over a 10k-event journal) took '
            '${fastStopwatch.elapsedMicroseconds}us vs a full replay\'s '
            '${fullStopwatch.elapsedMicroseconds}us',
      );
    });
  });
}
