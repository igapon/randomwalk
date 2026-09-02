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
  Future<void> close() async {}
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late File trackFile;
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
    Future<void> Function(FinishedTrip trip)? inner,
    TripHistoryStore? storeOverride,
  }) => TripHistoryRecorder(
    store: storeOverride ?? store,
    journal: journal,
    trackFile: trackFile,
    inner:
        inner ??
        (t) async {
          innerCalls++;
          innerReceived = t;
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

  test('XP earned is the GameState delta across inner\'s own call', () async {
    // Simulate what the real ExplorationRecorder does: append the trip's
    // own xp_earned events as part of `inner`.
    // `preMultiplied: true` so the reducer's own energy-multiplier math
    // (`reducers.dart`'s private `_energyMultiplier`, out of scope here)
    // never enters the picture — this test is only about the before/after
    // diffing this class does, not about how much XP a given event is
    // ultimately worth.
    final recorder = build(
      inner: (t) async {
        await journal.appendAll([
          GameEvent(
            id: '1',
            ts: t.startedAt!,
            type: GameEventTypes.xpEarned,
            payload: const {'amount': 32, 'preMultiplied': true},
          ),
          GameEvent(
            id: '2',
            ts: t.startedAt!,
            type: GameEventTypes.xpEarned,
            payload: const {'amount': 5, 'preMultiplied': true},
          ),
        ]);
      },
    );

    await recorder.process(trip);

    final entry = (await store.list()).single;
    expect(entry.xpEarned, closeTo(37, 1e-9));
  });

  test('XP earned before this trip is not counted twice', () async {
    // A previous trip already banked 100 XP.
    await journal.append(
      GameEvent(
        id: 'prev',
        ts: DateTime.utc(2026, 8, 29),
        type: GameEventTypes.xpEarned,
        payload: const {'amount': 100, 'preMultiplied': true},
      ),
    );
    final recorder = build(
      inner: (t) async {
        await journal.append(
          GameEvent(
            id: 'this-trip',
            ts: t.startedAt!,
            type: GameEventTypes.xpEarned,
            payload: const {'amount': 10, 'preMultiplied': true},
          ),
        );
      },
    );

    await recorder.process(trip);

    expect((await store.list()).single.xpEarned, closeTo(10, 1e-9));
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
      },
    );

    await recorder.process(trip);

    expect(innerSawFile, isTrue, reason: 'inner must still see the file');
    final entry = (await store.list()).single;
    expect(entry.track, [(46.2, 6.1), (46.21, 6.11)]);
    expect(await trackFile.exists(), isFalse);
  });

  test('a missing track file records an empty track, not a failure', () async {
    final recorder = build();
    await recorder.process(trip);
    expect((await store.list()).single.track, isEmpty);
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
