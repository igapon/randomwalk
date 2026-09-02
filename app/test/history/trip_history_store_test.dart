import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/history/trip_history_store.dart';
import 'package:randomwalk/valhalla/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late String dbPath;
  late TripHistoryStore store;

  setUp(() async {
    // A real file path, not `inMemoryDatabasePath`: the corruption test
    // below needs a second handle onto the *same* database, which
    // `sqflite_common_ffi` only shares for a real path — it opens a fresh,
    // independent in-memory database on every `inMemoryDatabasePath` call
    // (see `edges_store_test.dart`'s own comment on this).
    tempDir = await Directory.systemTemp.createTemp('trip_history_test');
    dbPath = '${tempDir.path}/history.db';
    store = await TripHistoryStore.open(dbPath);
  });

  tearDown(() async {
    try {
      await store.close();
    } catch (_) {}
    await tempDir.delete(recursive: true);
  });

  TripHistoryEntry entry({
    DateTime? startedAt,
    double distanceKm = 2.5,
    double? xpEarned,
    List<(double, double)> track = const [(46.2, 6.1), (46.21, 6.11)],
    RoutingProfile profile = RoutingProfile.walk,
  }) {
    final start = startedAt ?? DateTime.utc(2026, 8, 30, 9, 0, 0);
    return TripHistoryEntry(
      startedAt: start,
      endedAt: start.add(const Duration(minutes: 30)),
      profile: profile,
      distanceKm: distanceKm,
      duration: const Duration(minutes: 30),
      avgSpeedKmh: distanceKm / 0.5,
      xpEarned: xpEarned,
      track: track,
    );
  }

  test('a brand-new store has no trips', () async {
    expect(await store.list(), isEmpty);
    expect(await store.latest(), isNull);
  });

  test(
    'record then list round-trips every field, including the track',
    () async {
      await store.record(entry(xpEarned: 35));
      final entries = await store.list();
      expect(entries, hasLength(1));
      final got = entries.single;
      expect(got.id, isNotNull);
      expect(got.startedAt, DateTime.utc(2026, 8, 30, 9, 0, 0));
      expect(got.endedAt, DateTime.utc(2026, 8, 30, 9, 30, 0));
      expect(got.profile, RoutingProfile.walk);
      expect(got.distanceKm, closeTo(2.5, 1e-9));
      expect(got.duration, const Duration(minutes: 30));
      expect(got.avgSpeedKmh, closeTo(5.0, 1e-9));
      expect(got.xpEarned, closeTo(35, 1e-9));
      expect(got.track, [(46.2, 6.1), (46.21, 6.11)]);
    },
  );

  test('a trip with no XP source records a null xpEarned', () async {
    await store.record(entry(xpEarned: null));
    expect((await store.list()).single.xpEarned, isNull);
  });

  test('a bike trip round-trips its profile', () async {
    await store.record(entry(profile: RoutingProfile.bike));
    expect((await store.list()).single.profile, RoutingProfile.bike);
  });

  test('list returns every trip antichronologically (newest first)', () async {
    final t1 = DateTime.utc(2026, 8, 28);
    final t2 = DateTime.utc(2026, 8, 29);
    final t3 = DateTime.utc(2026, 8, 30);
    // Deliberately recorded out of chronological order — the ordering must
    // come from `started_at`, not insertion order.
    await store.record(entry(startedAt: t2));
    await store.record(entry(startedAt: t1));
    await store.record(entry(startedAt: t3));

    final entries = await store.list();
    expect(entries.map((e) => e.startedAt), [t3, t2, t1]);
  });

  test('latest returns the most recently started trip', () async {
    await store.record(entry(startedAt: DateTime.utc(2026, 8, 28)));
    await store.record(entry(startedAt: DateTime.utc(2026, 8, 30)));
    await store.record(entry(startedAt: DateTime.utc(2026, 8, 29)));

    expect((await store.latest())?.startedAt, DateTime.utc(2026, 8, 30));
  });

  test(
    'a corrupt row (bad JSON track / unparsable date) is skipped, not fatal',
    () async {
      await store.record(entry(startedAt: DateTime.utc(2026, 8, 1)));

      // A second handle on the *same* file-backed database — see the
      // `setUp` comment above for why this only works with a real path.
      // Deliberately never closed: it shares the same underlying connection
      // as `store` (ref-counted by path), and closing this handle closes
      // that connection out from under `store` too. `tearDown`'s
      // `tempDir.delete` cleans it up regardless.
      final raw = await openDatabase(dbPath);
      await raw.insert('trip_history', {
        'started_at': 'not-a-date',
        'ended_at': 'not-a-date',
        'profile': 'walk',
        'distance_km': 1.0,
        'duration_s': 10,
        'avg_speed_kmh': 1.0,
        'xp_earned': null,
        'track': '{not valid json',
      });

      final entries = await store.list();
      expect(entries, hasLength(1));
      expect(entries.single.startedAt, DateTime.utc(2026, 8, 1));
    },
  );

  test('an entry with an empty track round-trips as an empty list', () async {
    await store.record(entry(track: const []));
    expect((await store.list()).single.track, isEmpty);
  });
}
