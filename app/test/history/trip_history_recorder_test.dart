import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/exploration/exploration_recorder.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/history/trip_history_recorder.dart';
import 'package:randomwalk/history/trip_history_store.dart';
import 'package:randomwalk/valhalla/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A [TripHistoryStore] double that always throws on [record] — for the
/// "échec d'écriture silencieux" requirement (brief §4).
class ThrowingTripHistoryStore implements TripHistoryStore {
  @override
  Future<int> record(TripHistoryEntry entry) async {
    throw StateError('disk full');
  }

  @override
  Future<List<TripHistoryEntry>> list({int? limit}) async => const [];

  @override
  Future<TripHistoryEntry?> latest() async => null;

  @override
  Future<TripHistoryEntry?> fetchById(int id) async => null;

  @override
  Future<void> close() async {}
}

GameEvent _xpEvent(String id, DateTime ts, num amount) => GameEvent(
  id: id,
  ts: ts,
  type: GameEventTypes.xpEarned,
  payload: {'amount': amount, 'preMultiplied': true},
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late File trackFile;
  // A real journal, only used to simulate what a concurrent writer (the
  // real `ExplorationRecorder`, or — for Critical 1's regression tests — a
  // concurrent `SyncEngine` merge) does to shared state; `TripHistoryRecorder`
  // itself no longer touches a journal at all (see the review fix).
  late GameJournal journal;
  late TripHistoryStore store;
  var innerCalls = 0;
  FinishedTrip? innerReceived;

  final trip = FinishedTrip(
    km: 3.2,
    startedAt: DateTime.utc(2026, 8, 30, 9, 0, 0),
    endedAt: DateTime.utc(2026, 8, 30, 9, 40, 0),
    profile: RoutingProfile.walk,
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('trip_history_rec_test');
    trackFile = File('${tempDir.path}/active_track.jsonl');
    journal = GameJournal(Directory('${tempDir.path}/game'));
    store = await TripHistoryStore.open('${tempDir.path}/history.db');
    innerCalls = 0;
    innerReceived = null;
  });

  tearDown(() async {
    try {
      await store.close();
    } catch (_) {}
    await tempDir.delete(recursive: true);
  });

  TripHistoryRecorder build({
    Future<List<GameEvent>> Function(FinishedTrip trip)? inner,
    TripHistoryStore? storeOverride,
  }) => TripHistoryRecorder(
    store: storeOverride ?? store,
    trackFile: trackFile,
    inner:
        inner ??
        (t) async {
          innerCalls++;
          innerReceived = t;
          return const <GameEvent>[];
        },
  );

  test('a finished trip is recorded once inner completes', () async {
    final recorder = build();
    await recorder.process(trip);

    expect(innerCalls, 1);
    final entries = await store.list();
    expect(entries, hasLength(1));
    final entry = entries.single;
    expect(entry.startedAt, trip.startedAt);
    expect(entry.endedAt, trip.endedAt);
    expect(entry.profile, RoutingProfile.walk);
    expect(entry.distanceKm, closeTo(3.2, 1e-9));
    expect(entry.duration, const Duration(minutes: 40));
  });

  group('XP source (review fix round 1, Critical 1)', () {
    test('XP earned is the sum of xp_earned amounts among the events inner '
        'itself returns', () async {
      // `preMultiplied: true` so the reducer's own energy-multiplier math
      // (`reducers.dart`'s private `_energyMultiplier`, out of scope
      // here) never enters the picture — this test is only about the
      // summing this class does over inner's own return value.
      final recorder = build(
        inner: (t) async => [
          _xpEvent('1', t.startedAt!, 32),
          _xpEvent('2', t.startedAt!, 5),
        ],
      );

      await recorder.process(trip);

      final entry = (await store.list()).single;
      expect(entry.xpEarned, closeTo(37, 1e-9));
    });

    test(
      'pre-existing XP in the journal from earlier trips is never counted '
      '(requirement (b): the prior-trip no-double-count guarantee)',
      () async {
        // A previous trip's XP already sits in the journal — but nothing in
        // TripHistoryRecorder reads the journal any more, so this can no
        // longer leak into this trip's figure regardless of its value.
        await journal.append(_xpEvent('prev', DateTime.utc(2026, 8, 29), 100));
        final recorder = build(
          inner: (t) async {
            final own = _xpEvent('this-trip', t.startedAt!, 10);
            await journal.append(own);
            return [own];
          },
        );

        await recorder.process(trip);

        expect((await store.list()).single.xpEarned, closeTo(10, 1e-9));
      },
    );

    test('requirement (a): a concurrent sync merge landing during inner\'s '
        'call never pollutes this trip\'s recorded XP', () async {
      // Simulates the exact race Critical 1 described: `TripController
      // ._finalise` fires both `processTripExploration` and the post-trip
      // auto-sync trigger unawaited, and `SyncEngine.sync()` can merge
      // remote xp_earned events into the same GameJournal while `inner`
      // (the real ExplorationRecorder) is still running. `inner` here
      // appends its own event AND, mid-call, a "remote merge" event —
      // but only returns its own, exactly like the real
      // `ExplorationRecorder.process` only ever returns what it itself
      // appended.
      final recorder = build(
        inner: (t) async {
          final own = _xpEvent('own', t.startedAt!, 10);
          await journal.append(own);
          // The concurrent merge: a much larger amount, from "another
          // device", landing in the same window.
          await journal.append(_xpEvent('remote-merge', t.startedAt!, 500));
          return [own];
        },
      );

      await recorder.process(trip);

      final entry = (await store.list()).single;
      expect(entry.xpEarned, closeTo(10, 1e-9));
      expect(entry.xpEarned, isNot(closeTo(510, 1e-9)));
    });

    test('inner returning no events (a failed/degenerate run) records a null '
        'xpEarned, never zero', () async {
      final recorder = build(inner: (t) async => const []);
      await recorder.process(trip);
      expect((await store.list()).single.xpEarned, isNull);
    });

    test(
      'non-xp_earned events among inner\'s return value are ignored',
      () async {
        final recorder = build(
          inner: (t) async => [
            GameEvent(
              id: 'batch',
              ts: t.startedAt!,
              type: GameEventTypes.edgeCoveredBatch,
              payload: const {'km': 3.2},
            ),
            _xpEvent('xp', t.startedAt!, 20),
          ],
        );

        await recorder.process(trip);

        expect((await store.list()).single.xpEarned, closeTo(20, 1e-9));
      },
    );
  });

  test('the track is peeked before inner deletes it, and inner still sees '
      'the file', () async {
    await trackFile.parent.create(recursive: true);
    await trackFile.writeAsString(
      '${jsonEncode({'lat': 46.2, 'lon': 6.1})}\n'
      '${jsonEncode({'lat': 46.21, 'lon': 6.11})}\n',
    );
    var innerSawFile = false;
    final recorder = build(
      inner: (t) async {
        innerSawFile = await trackFile.exists();
        // Mirrors the real ExplorationRecorder: reads then deletes.
        await trackFile.delete();
        return const <GameEvent>[];
      },
    );

    await recorder.process(trip);

    expect(innerSawFile, isTrue, reason: 'inner must still see the file');
    // The list screen's own store method never returns a track (Critical
    // 2 — see `trip_history_store_test.dart`); fetch the full row to
    // check what was actually recorded.
    final summary = (await store.list()).single;
    final full = await store.fetchById(summary.id!);
    expect(full!.track, [(46.2, 6.1), (46.21, 6.11)]);
    expect(await trackFile.exists(), isFalse);
  });

  test('a missing track file records an empty track, not a failure', () async {
    final recorder = build();
    await recorder.process(trip);
    final summary = (await store.list()).single;
    expect((await store.fetchById(summary.id!))!.track, isEmpty);
  });

  test('a store write failure is swallowed: inner still ran, process never '
      'throws', () async {
    final recorder = build(storeOverride: ThrowingTripHistoryStore());

    await expectLater(recorder.process(trip), completes);
    expect(innerCalls, 1);
    expect(innerReceived?.km, closeTo(3.2, 1e-9));
  });

  test('a FinishedTrip missing the new fields still records a summary '
      '(defaults, no crash)', () async {
    final recorder = build();
    await recorder.process(const FinishedTrip(km: 1.1));

    final entry = (await store.list()).single;
    expect(entry.distanceKm, closeTo(1.1, 1e-9));
    expect(entry.profile, RoutingProfile.walk);
    expect(entry.duration, Duration.zero);
  });
}
