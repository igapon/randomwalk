import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/exploration/edges_store.dart';
import 'package:randomwalk/exploration/exploration_recorder.dart';
import 'package:randomwalk/exploration/track_sampler.dart' show kTrackMaxPoints;
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/game/grid.dart';
import 'package:randomwalk/game/reducers.dart';
import 'package:randomwalk/valhalla/engine.dart';
import 'package:randomwalk/valhalla/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeTraceEngine implements RoutingEngine {
  String? reply;
  Object? failure;
  int calls = 0;
  String? lastRequestJson;

  @override
  Future<void> init(String tileDirPath) async {}

  @override
  Future<RouteResult> route(RouteRequest request) =>
      throw UnimplementedError();

  @override
  Future<RouteResult> routeMulti(MultiPointRouteRequest request) =>
      throw UnimplementedError();

  @override
  Future<String> trace(String requestJson) async {
    calls++;
    lastRequestJson = requestJson;
    final f = failure;
    if (f != null) throw f;
    return reply ?? jsonEncode({'edges': <dynamic>[]});
  }
}

/// A [GameJournal] whose [appendAll] always throws — proves
/// [ExplorationRecorder.process] never lets a journal failure escape.
class ThrowingJournal extends GameJournal {
  ThrowingJournal(super.dir);

  @override
  Future<void> appendAll(List<GameEvent> events) async {
    throw StateError('disk full');
  }
}

(double, double) _centerOf(CellId c) {
  final bounds = cellBoundsLatLon(c);
  return ((bounds.sw.$1 + bounds.ne.$1) / 2, (bounds.sw.$2 + bounds.ne.$2) / 2);
}

/// The first [count] cell keys (in row-major order) of the 8x8 quartier
/// rooted at [topLeft], skipping [exclude] — used to pre-fill "everything
/// but one cell" of a quartier for the badge-threshold tests, regardless of
/// where [exclude] happens to sit within the block.
List<String> _quartierCellsExcluding(CellId topLeft, CellId exclude, int count) {
  final keys = <String>[];
  for (var dx = 0; dx < 8 && keys.length < count; dx++) {
    for (var dy = 0; dy < 8 && keys.length < count; dy++) {
      final c = CellId(topLeft.x + dx, topLeft.y + dy);
      if (c == exclude) continue;
      keys.add(c.key);
    }
  }
  return keys;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late File trackFile;
  late GameJournal journal;
  late EdgesStore edgesStore;
  late FakeTraceEngine engine;
  late int idCounter;
  final now = DateTime.utc(2026, 8, 30, 12, 0, 0);

  ExplorationRecorder buildRecorder({
    Future<RoutingEngine?> Function()? engineProvider,
    GameJournal? journalOverride,
    void Function()? onJournalChanged,
  }) =>
      ExplorationRecorder(
        engineProvider: engineProvider ?? (() async => engine),
        edgesStore: edgesStore,
        journal: journalOverride ?? journal,
        trackFile: trackFile,
        onJournalChanged: onJournalChanged,
        newId: () => 'evt-${idCounter++}',
        clock: () => now,
      );

  Future<void> writeTrack(List<(double, double)> points) async {
    final buffer = StringBuffer();
    for (final (lat, lon) in points) {
      buffer.writeln(jsonEncode({'lat': lat, 'lon': lon}));
    }
    await trackFile.parent.create(recursive: true);
    await trackFile.writeAsString(buffer.toString());
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('exploration_recorder_test');
    trackFile = File('${tempDir.path}/active_track.jsonl');
    journal = GameJournal(Directory('${tempDir.path}/journal'));
    edgesStore = await EdgesStore.open(inMemoryDatabasePath);
    engine = FakeTraceEngine();
    idCounter = 0;
  });

  tearDown(() async {
    await edgesStore.close();
    await tempDir.delete(recursive: true);
  });

  group('event order (Task 1 contract)', () {
    test(
        'edge_covered_batch, cell_revealed, xp_earned(km), xp_earned(cells), '
        'xp_earned(loop), loop_completed, energy_changed — in that order',
        () async {
      // A short walk near a single cell's center: enough to reveal at least
      // that one cell, never enough to cross any quartier's 25% threshold
      // from an empty journal.
      final target = const CellId(40, -20);
      final (lat, lon) = _centerOf(target);
      await writeTrack([(lat, lon), (lat + 0.0002, lon)]);
      engine.reply = jsonEncode({
        'edges': [
          {'way_id': 111, 'length': 0.5},
          {'way_id': 222, 'length': 0.7},
        ],
      });

      final recorder = buildRecorder();
      await recorder.process(
          const FinishedTrip(km: 2.5, isLoop: true, navArrived: true));

      final events = await journal.readAll();
      final types = events.map((e) => e.type).toList();

      expect(
          types,
          [
            GameEventTypes.edgeCoveredBatch,
            GameEventTypes.cellRevealed,
            GameEventTypes.xpEarned, // km
            GameEventTypes.xpEarned, // cells
            GameEventTypes.xpEarned, // loop
            GameEventTypes.loopCompleted,
            GameEventTypes.energyChanged,
          ],
          reason: 'events: $types');

      expect(events[0].payload['km'], 2.5);

      final cellEvent = events[1];
      final cells = (cellEvent.payload['cells'] as List).cast<String>();
      expect(cells, contains(target.key));

      expect(events[2].payload['amount'], closeTo(25.0, 1e-9)); // 10 * 2.5
      expect(events[2].payload['preMultiplied'], false);

      expect(events[3].payload['amount'], closeTo(5.0 * cells.length, 1e-9));
      expect(events[3].payload['preMultiplied'], false);

      expect(events[4].payload['amount'], 50);
      expect(events[4].payload['preMultiplied'], false);

      expect(events[5].payload, isEmpty);

      expect(events[6].payload['delta'], closeTo(-10.0, 1e-9)); // -4 * 2.5
    });

    test('no badge_unlocked from an ordinary reveal starting from an empty '
        'journal', () async {
      final target = const CellId(5, 5);
      final (lat, lon) = _centerOf(target);
      await writeTrack([(lat, lon), (lat + 0.0002, lon)]);

      final recorder = buildRecorder();
      await recorder.process(const FinishedTrip(km: 1.0));

      final events = await journal.readAll();
      expect(events.any((e) => e.type == GameEventTypes.badgeUnlocked), isFalse);
    });

    test('a non-loop trip emits no loop-related events at all', () async {
      await writeTrack(const []);
      final recorder = buildRecorder();
      await recorder.process(const FinishedTrip(km: 1.0));

      final events = await journal.readAll();
      final types = events.map((e) => e.type).toSet();
      expect(types, {
        GameEventTypes.edgeCoveredBatch,
        GameEventTypes.xpEarned,
        GameEventTypes.energyChanged,
      });
    });

    test('a loop that did not arrive emits no loop_completed and no loop XP',
        () async {
      await writeTrack(const []);
      final recorder = buildRecorder();
      await recorder.process(
          const FinishedTrip(km: 1.0, isLoop: true, navArrived: false));

      final events = await journal.readAll();
      expect(events.any((e) => e.type == GameEventTypes.loopCompleted), isFalse);
      // Only one xp_earned (km) since no cells were revealed (empty shape)
      // and no loop bonus.
      expect(
          events.where((e) => e.type == GameEventTypes.xpEarned).length, 1);
    });
  });

  group('quartier_25 badge', () {
    test('crosses the threshold and unlocks exactly once', () async {
      const quartierTopLeft = CellId(0, 0);
      // Sanity: our target cell really is inside this quartier.
      final target = const CellId(2, 3);
      expect(quartierOf(target), (quartierTopLeft, 8));

      // Pre-fill exactly 15 of the quartier's 64 cells, `target` excluded —
      // 15/64 = 0.234, under the threshold.
      final prefilled = _quartierCellsExcluding(quartierTopLeft, target, 15);
      expect(prefilled.length, 15);
      await journal.append(GameEvent(
        id: 'seed',
        ts: now,
        type: GameEventTypes.cellRevealed,
        payload: {'cells': prefilled},
      ));

      final (lat, lon) = _centerOf(target);
      await writeTrack([(lat, lon), (lat + 0.0002, lon)]);

      final recorder = buildRecorder();
      await recorder.process(const FinishedTrip(km: 0.5));

      final events = await journal.readAll();
      final badgeEvents = events
          .where((e) => e.type == GameEventTypes.badgeUnlocked)
          .toList();
      expect(badgeEvents, hasLength(1));
      expect(badgeEvents.single.payload['badge'], GameBadges.quartier25);

      final state = reduceAll(events);
      expect(state.badges, contains(GameBadges.quartier25));
    });

    test('never fires twice for the same quartier once already unlocked',
        () async {
      const quartierTopLeft = CellId(0, 0);
      final target = const CellId(2, 3);
      final prefilled = _quartierCellsExcluding(quartierTopLeft, target, 15);
      await journal.append(GameEvent(
          id: 'seed',
          ts: now,
          type: GameEventTypes.cellRevealed,
          payload: {'cells': prefilled}));
      final (lat, lon) = _centerOf(target);
      await writeTrack([(lat, lon), (lat + 0.0002, lon)]);
      await buildRecorder().process(const FinishedTrip(km: 0.5));

      // A second trip touching a fresh cell in the SAME quartier must not
      // unlock the badge again.
      final other = const CellId(3, 3);
      expect(quartierOf(other), (quartierTopLeft, 8));
      final (lat2, lon2) = _centerOf(other);
      await writeTrack([(lat2, lon2), (lat2 + 0.0002, lon2)]);
      await buildRecorder().process(const FinishedTrip(km: 0.5));

      final events = await journal.readAll();
      expect(
          events.where((e) => e.type == GameEventTypes.badgeUnlocked).length,
          1);
    });
  });

  group('edge/way persistence', () {
    test('a successful match stores the matched way ids in EdgesStore',
        () async {
      await writeTrack([(46.52, 6.63), (46.5202, 6.63)]);
      engine.reply = jsonEncode({
        'edges': [
          {'way_id': 555, 'length': 0.1},
          {'way_id': 556, 'length': 0.2},
        ],
      });

      await buildRecorder().process(const FinishedTrip(km: 0.3));

      expect(await edgesStore.contains('555'), isTrue);
      expect(await edgesStore.contains('556'), isTrue);
      expect(await edgesStore.totalCount, 2);
    });
  });

  group('game never blocks — best-effort failure handling', () {
    test('no track file at all still emits km/energy events, no cell reveal',
        () async {
      // trackFile was never written.
      final recorder = buildRecorder();
      await recorder.process(const FinishedTrip(km: 2.0));

      final events = await journal.readAll();
      expect(events.map((e) => e.type), [
        GameEventTypes.edgeCoveredBatch,
        GameEventTypes.xpEarned,
        GameEventTypes.energyChanged,
      ]);
    });

    test('a shape with fewer than 2 points skips reveal/matching entirely',
        () async {
      await writeTrack([(46.52, 6.63)]);
      final recorder = buildRecorder();
      await recorder.process(const FinishedTrip(km: 1.0));

      expect(await edgesStore.totalCount, 0);
      final events = await journal.readAll();
      expect(events.any((e) => e.type == GameEventTypes.cellRevealed), isFalse);
    });

    test('a null engineProvider (no tiles resolved) skips matching but still '
        'reveals cells from the raw shape', () async {
      final target = const CellId(9, 9);
      final (lat, lon) = _centerOf(target);
      await writeTrack([(lat, lon), (lat + 0.0002, lon)]);

      final recorder = buildRecorder(engineProvider: () async => null);
      await recorder.process(const FinishedTrip(km: 1.0));

      expect(await edgesStore.totalCount, 0);
      final events = await journal.readAll();
      final cellEvent =
          events.firstWhere((e) => e.type == GameEventTypes.cellRevealed);
      expect((cellEvent.payload['cells'] as List), contains(target.key));
    });

    test('an engine that throws on trace() never stops the trip\'s exploration '
        'processing', () async {
      final target = const CellId(11, 11);
      final (lat, lon) = _centerOf(target);
      await writeTrack([(lat, lon), (lat + 0.0002, lon)]);
      engine.failure = const RoutingException('no tiles');

      final recorder = buildRecorder();
      await recorder.process(const FinishedTrip(km: 1.0));

      expect(await edgesStore.totalCount, 0);
      final events = await journal.readAll();
      expect(events.any((e) => e.type == GameEventTypes.cellRevealed), isTrue);
      expect(events.any((e) => e.type == GameEventTypes.edgeCoveredBatch),
          isTrue);
    });

    test('an engineProvider that itself throws never escapes process()',
        () async {
      final recorder = buildRecorder(
          engineProvider: () async => throw StateError('boom'));
      await writeTrack([(46.52, 6.63), (46.5202, 6.63)]);

      await expectLater(
          recorder.process(const FinishedTrip(km: 1.0)), completes);

      final events = await journal.readAll();
      expect(events.any((e) => e.type == GameEventTypes.edgeCoveredBatch),
          isTrue);
    });

    test('a journal that throws on appendAll never escapes process()',
        () async {
      final throwingJournal = ThrowingJournal(Directory('${tempDir.path}/j2'));
      final recorder = buildRecorder(journalOverride: throwingJournal);
      await writeTrack(const []);

      await expectLater(
          recorder.process(const FinishedTrip(km: 1.0)), completes);
    });

    test('onJournalChanged fires once after a successful process() call',
        () async {
      var calls = 0;
      await writeTrack(const []);
      await buildRecorder(onJournalChanged: () => calls++)
          .process(const FinishedTrip(km: 1.0));
      expect(calls, 1);
    });

    test('a throwing onJournalChanged never escapes process()', () async {
      await writeTrack(const []);
      await expectLater(
          buildRecorder(onJournalChanged: () => throw StateError('boom'))
              .process(const FinishedTrip(km: 1.0)),
          completes);
    });

    test('a journal that throws on appendAll never fires onJournalChanged',
        () async {
      final throwingJournal = ThrowingJournal(Directory('${tempDir.path}/j3'));
      var calls = 0;
      await writeTrack(const []);
      await buildRecorder(
              journalOverride: throwingJournal,
              onJournalChanged: () => calls++)
          .process(const FinishedTrip(km: 1.0));
      expect(calls, 0);
    });

    test('the track file is deleted once read, win or lose', () async {
      await writeTrack([(46.52, 6.63), (46.5202, 6.63)]);
      await buildRecorder().process(const FinishedTrip(km: 1.0));
      expect(await trackFile.exists(), isFalse);
    });

    test(
        'an oversized on-disk track file (more than kTrackMaxPoints lines) '
        'is capped before being handed to the map-matcher — fix round 1 '
        'finding 2 (recorder-side belt-and-suspenders)', () async {
      final points = <(double, double)>[
        for (var i = 0; i < kTrackMaxPoints + 1000; i++)
          (46.5 + i * 0.00001, 6.63),
      ];
      await writeTrack(points);
      engine.reply = jsonEncode({'edges': <dynamic>[]});

      await buildRecorder().process(const FinishedTrip(km: 3.0));

      final sentShape =
          (jsonDecode(engine.lastRequestJson!) as Map)['shape'] as List;
      expect(sentShape.length, lessThanOrEqualTo(kTrackMaxPoints));
    });
  });

  group('gap handling (fix round 1: no straight line across a gap)', () {
    test(
        'a gap greater than 200 m between consecutive track points does not '
        'reveal a straight-line corridor across it', () async {
      final a = _centerOf(const CellId(30, 0));
      final b = _centerOf(const CellId(30, 4)); // ~600 m north, gap > 200 m
      const midpoint = CellId(30, 2);
      await writeTrack([a, b]);

      await buildRecorder().process(const FinishedTrip(km: 0.6));

      final events = await journal.readAll();
      final cellEvent =
          events.firstWhere((e) => e.type == GameEventTypes.cellRevealed);
      final cells = (cellEvent.payload['cells'] as List).cast<String>();
      expect(cells, isNot(contains(midpoint.key)));
      // Sanity: each endpoint's own cell IS still revealed — splitting on
      // the gap must not lose the corridor around each side of it.
      expect(cells, contains(const CellId(30, 0).key));
      expect(cells, contains(const CellId(30, 4).key));
    });
  });

  group('splitOnGaps (pure)', () {
    test('an empty shape yields no segments', () {
      expect(splitOnGaps(const []), isEmpty);
    });

    test('a single-point shape yields one segment with that point', () {
      expect(splitOnGaps(const [(46.52, 6.63)]), [
        [(46.52, 6.63)],
      ]);
    });

    test('a shape with no gap above the threshold yields one segment', () {
      const shape = [(46.52, 6.63), (46.5201, 6.63), (46.5202, 6.63)];
      expect(splitOnGaps(shape), [shape]);
    });

    test('a single gap over 200 m splits into two segments', () {
      const a = (46.52, 6.63);
      const b = (46.5205, 6.63); // ~55 m — under threshold, same segment
      final c = _centerOf(const CellId(30, 20)); // far away
      final segments = splitOnGaps([a, b, c]);
      expect(segments, [
        [a, b],
        [c],
      ]);
    });

    test('multiple gaps split into multiple segments, in order', () {
      final p1 = _centerOf(const CellId(0, 0));
      final p2 = _centerOf(const CellId(0, 10));
      final p3 = _centerOf(const CellId(0, 20));
      expect(splitOnGaps([p1, p2, p3]), [
        [p1],
        [p2],
        [p3],
      ]);
    });

    test('a custom maxGapM is honored', () {
      const a = (46.52, 6.63);
      const b = (46.5202, 6.63); // ~22 m apart
      expect(splitOnGaps(const [a, b], maxGapM: 10).length, 2);
      expect(splitOnGaps(const [a, b], maxGapM: 50).length, 1);
    });
  });
}
