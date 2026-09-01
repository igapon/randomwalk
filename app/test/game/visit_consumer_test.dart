import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/game/grid.dart';
import 'package:randomwalk/game/reducers.dart';
import 'package:randomwalk/game/visit_consumer.dart';
import 'package:randomwalk/tracking/trip_snapshot.dart';

/// The first [count] cell keys (row-major) of the 8x8 quartier rooted at
/// [topLeft] — mirrors `exploration_recorder_test.dart`'s own helper of the
/// same shape.
List<String> _quartierCells(CellId topLeft, int count) {
  final keys = <String>[];
  for (var dx = 0; dx < 8 && keys.length < count; dx++) {
    for (var dy = 0; dy < 8 && keys.length < count; dy++) {
      keys.add(CellId(topLeft.x + dx, topLeft.y + dy).key);
    }
  }
  return keys;
}

void main() {
  late Directory tempDir;
  late GameJournal journal;
  late int idCounter;
  late List<String> alerts;

  GameVisitConsumer buildConsumer({bool withNotify = true}) =>
      GameVisitConsumer(
        journal: journal,
        notify: withNotify ? (text) async => alerts.add(text) : null,
        newId: () => 'evt-${idCounter++}',
      );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('visit_consumer_test');
    journal = GameJournal(Directory('${tempDir.path}/journal'));
    idCounter = 0;
    alerts = [];
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);

  // GameState starts at energy 100 (>= 60 -> x1.5 XP multiplier). Most tests
  // below care about the *shape* of the reward, not about re-deriving that
  // multiplier by hand, so they drain energy into the neutral [20, 60) band
  // (x1.0) first — a landmark visit's own reducer effects (if any) are
  // applied to this same state before its `xp_earned` companion event is
  // evaluated (the plan's binding event order — see GameVisitConsumer's doc
  // comment), so the amount drained is chosen per test to land back under
  // 60 even after that landmark's own energy bump, where applicable.
  Future<void> drainEnergyTo(double delta) => journal.append(
    GameEvent(
      id: 'seed-energy',
      ts: t0.subtract(const Duration(minutes: 1)),
      type: GameEventTypes.energyChanged,
      payload: {'delta': delta},
    ),
  );

  PendingVisit reveal({
    String poiId = 'node/reveal',
    String? name = 'Église Saint-Pierre',
    double lat = 46.52,
    double lon = 6.63,
    DateTime? ts,
  }) => PendingVisit(
    poiId: poiId,
    kind: 'reveal',
    name: name,
    lat: lat,
    lon: lon,
    ts: ts ?? t0,
  );

  PendingVisit coins({
    String poiId = 'node/bank',
    String? name = 'Banque Cantonale',
    DateTime? ts,
  }) => PendingVisit(
    poiId: poiId,
    kind: 'coins',
    name: name,
    lat: 46.5,
    lon: 6.6,
    ts: ts ?? t0,
  );

  PendingVisit energy({
    String poiId = 'node/cafe',
    String? name = 'Café Central',
    String? subkind = 'cafe',
    DateTime? ts,
  }) => PendingVisit(
    poiId: poiId,
    kind: 'energy',
    subkind: subkind,
    name: name,
    lat: 46.5,
    lon: 6.6,
    ts: ts ?? t0,
  );

  group('first-visit reveal landmark', () {
    test('emits landmark_visited, cell_revealed, quartier_25 (crossed by this '
        'disc), then xp_earned, in order', () async {
      final consumer = buildConsumer();
      await consumer.consume([reveal()]);

      final events = await journal.readAll();
      expect(events.map((e) => e.type).toList(), [
        GameEventTypes.landmarkVisited,
        GameEventTypes.cellRevealed,
        GameEventTypes.badgeUnlocked,
        GameEventTypes.xpEarned,
      ]);
      expect(events[0].payload, {'poiId': 'node/reveal', 'kind': 'reveal'});
      expect(events[0].ts, t0);
      expect((events[1].payload['cells'] as List), isNotEmpty);
      expect(events[2].payload, {'badge': GameBadges.quartier25});
      // The emitted payload is always the flat +25, regardless of the
      // reducer's own energy multiplier applied when it lands (see
      // `drainEnergyTo`'s doc comment) — that multiplier changes the
      // *credited* xp, never what this class puts on the wire.
      expect(events[3].payload, {'amount': 25, 'preMultiplied': false});
    });

    test('alerts with the landmark name and +25 XP', () async {
      await drainEnergyTo(-50); // 100 -> 50: neutral x1.0 multiplier band.
      final consumer = buildConsumer();
      await consumer.consume([reveal(name: 'Château de Chillon')]);

      expect(alerts, hasLength(1));
      expect(alerts.single, '⚑ Château de Chillon — +25 XP');
    });

    test('an unnamed landmark falls back to a generic label', () async {
      final consumer = buildConsumer();
      await consumer.consume([reveal(name: null)]);
      expect(alerts.single, contains('Point de repère'));
    });

    test('a revisit to the same reveal landmark (no new cells, no xp) stays '
        'silent', () async {
      final consumer = buildConsumer();
      await consumer.consume([reveal(ts: t0)]);
      alerts.clear();

      // Same place, later: already visited (no xp), disc already fully
      // revealed (no new cells) -> no reward at all.
      await consumer.consume([reveal(ts: t0.add(const Duration(hours: 1)))]);

      final events = await journal.readAll();
      // Exactly one more landmark_visited, nothing else.
      expect(
        events.where((e) => e.type == GameEventTypes.landmarkVisited).length,
        2,
      );
      expect(events.where((e) => e.type == GameEventTypes.xpEarned).length, 1);
      expect(alerts, isEmpty);
    });
  });

  group('first-visit coins landmark', () {
    test('emits landmark_visited then xp_earned (no cell_revealed)', () async {
      await drainEnergyTo(-50); // neutral x1.0 multiplier band.
      final consumer = buildConsumer();
      await consumer.consume([coins()]);

      final events = await journal.readAll();
      expect(events.map((e) => e.type).toList(), [
        GameEventTypes.energyChanged, // the seed above.
        GameEventTypes.landmarkVisited,
        GameEventTypes.xpEarned,
      ]);

      final state = reduceAll(events);
      expect(state.coins, 100); // first-ever yield at this place.
      expect(state.xp, 25);
    });

    test('alerts with coins and XP', () async {
      await drainEnergyTo(-50);
      final consumer = buildConsumer();
      await consumer.consume([coins(name: 'Banque Cantonale')]);
      expect(alerts.single, '⚑ Banque Cantonale — +100 pièces · +25 XP');
    });

    test('a same-place revisit within the 24h cooldown earns nothing and '
        'stays silent', () async {
      final consumer = buildConsumer();
      await consumer.consume([coins(ts: t0)]);
      alerts.clear();

      await consumer.consume([coins(ts: t0.add(const Duration(hours: 2)))]);

      final state = reduceAll(await journal.readAll());
      expect(state.coins, 100); // unchanged: cooldown blocked the second.
      expect(alerts, isEmpty);
    });

    test('a revisit after the cooldown earns the diminished yield but NOT a '
        'second XP, and alerts coins-only', () async {
      await drainEnergyTo(-50);
      final consumer = buildConsumer();
      await consumer.consume([coins(ts: t0)]);
      alerts.clear();

      await consumer.consume([coins(ts: t0.add(const Duration(hours: 25)))]);

      final state = reduceAll(await journal.readAll());
      expect(state.coins, 150); // 100 (first) + 50 (second yield).
      expect(state.xp, 25); // unchanged: not a first visit anymore.
      expect(alerts, hasLength(1));
      expect(alerts.single, '⚑ Banque Cantonale — +50 pièces');
    });
  });

  group('first-visit energy landmark', () {
    test(
      'landmark_visited carries the subkind; energy/xp both applied',
      () async {
        // Drained further than the coins/reveal tests: this landmark's OWN
        // +25 (cafe) is applied by `landmark_visited` BEFORE its `xp_earned`
        // companion (the plan's binding event order), so the multiplier band
        // must still hold true *after* that +25 lands, not just before it —
        // 100 - 75 = 25, +25 (cafe) = 50, still under the x1.5 threshold (60).
        await drainEnergyTo(-75);

        final consumer = buildConsumer();
        await consumer.consume([energy()]);

        final events = await journal.readAll();
        final visited = events.firstWhere(
          (e) => e.type == GameEventTypes.landmarkVisited,
        );
        expect(visited.payload, {
          'poiId': 'node/cafe',
          'kind': 'energy',
          'subkind': 'cafe',
        });

        final state = reduceAll(events);
        expect(state.energy, 50); // 25 + 25 (cafe).
        expect(state.xp, 25);
        expect(alerts.single, '⚑ Café Central — +25 énergie · +25 XP');
      },
    );

    test('an unrecognized subkind earns no energy but still earns the '
        'first-visit XP', () async {
      await drainEnergyTo(-50); // unaffected by the unknown subkind itself.
      final consumer = buildConsumer();
      await consumer.consume([energy(subkind: 'unknown_kind')]);

      final state = reduceAll(await journal.readAll());
      expect(state.energy, 50); // unchanged: unknown subkind = 0 amount.
      expect(state.xp, 25);
      expect(alerts.single, '⚑ Café Central — +25 XP');
    });
  });

  group('null subkind on a malformed energy POI (fix round 1, Task 5 review, '
      'item 1)', () {
    test('a null-subkind visit is recorded once, earns no energy, and still '
        'earns the first-visit XP (the payload always carries a subkind '
        'key, even if empty, so the reducer never has to throw)', () async {
      await drainEnergyTo(-50);
      final consumer = buildConsumer();
      await consumer.consume([energy(subkind: null)]);

      final events = await journal.readAll();
      final visited = events.firstWhere(
        (e) => e.type == GameEventTypes.landmarkVisited,
      );
      // Always present, per the fix — never omitted just because the POI's
      // own subkind was null.
      expect(visited.payload, {
        'poiId': 'node/cafe',
        'kind': 'energy',
        'subkind': '',
      });

      final state = reduceAll(events);
      expect(state.energy, 50); // no reward.
      expect(state.xp, 25); // first-visit XP still granted.
      expect(state.visitedPoiIds, contains('node/cafe'));
      expect(alerts.single, '⚑ Café Central — +25 XP');
    });

    test(
      'the exploit this closes: a second "visit" to the same broken POI '
      '(a later trip, so a different ts and NOT caught by the (poiId, ts) '
      'dedup) earns no second XP — before the fix, the missing subkind '
      'made the reducer discard the whole first event, so visitedPoiIds '
      'never stuck and every later visit minted another +25 forever',
      () async {
        await drainEnergyTo(
          -50,
        ); // neutral x1.0 multiplier band, for clean xp math.
        final consumer = buildConsumer();
        await consumer.consume([energy(subkind: null, ts: t0)]);
        await consumer.consume([
          energy(subkind: null, ts: t0.add(const Duration(days: 30))),
        ]);

        final state = reduceAll(await journal.readAll());
        expect(state.xp, 25); // NOT 50 — only the first visit ever counted.
        expect(state.energy, 50); // never touched: unknown subkind both times.
        expect(state.landmarksVisited, 1); // still one distinct place, not two.
      },
    );
  });

  group('dedup by (poiId, ts)', () {
    test(
      'the exact same PendingVisit processed twice appends only once',
      () async {
        final consumer = buildConsumer();
        final visit = coins();
        await consumer.consume([visit]);
        await consumer.consume([visit]); // e.g. the next snapshot tick.

        final events = await journal.readAll();
        expect(
          events.where((e) => e.type == GameEventTypes.landmarkVisited).length,
          1,
        );
        expect(alerts, hasLength(1));
      },
    );

    test(
      'reprocessing an already-applied visit after the in-memory seen '
      'set is lost is still safe (idempotent via ts + reducer state)',
      () async {
        await drainEnergyTo(-50);
        final visit = coins();
        await buildConsumer().consume([visit]); // consumer #1 (process died).
        alerts.clear();

        // A fresh consumer (e.g. after a restart) reprocesses the same stale
        // pendingVisits entry — no in-memory seen-set survives that.
        await buildConsumer().consume([visit]);

        final state = reduceAll(await journal.readAll());
        // Cooldown check sees ts.difference(lastRewardedTs) == 0, so no second
        // coin reward; visitedPoiIds already true, so no second xp either.
        expect(state.coins, 100);
        expect(state.xp, 25);
        expect(alerts, isEmpty);
      },
    );
  });

  group('quartier_25 badge', () {
    test('a landmark reveal crossing the threshold unlocks it', () async {
      final consumer = buildConsumer();
      // Empirically, a single 400m disc reveal covers well over 25% of its
      // home quartier (see grid.dart's cell size), so an empty journal is
      // enough to cross it via one reveal-kind visit.
      await consumer.consume([reveal()]);

      final state = reduceAll(await journal.readAll());
      expect(state.badges, contains(GameBadges.quartier25));
    });

    test('never unlocked twice', () async {
      final consumer = buildConsumer();
      await consumer.consume([reveal(poiId: 'a')]);
      await consumer.consume([
        reveal(poiId: 'b', ts: t0.add(const Duration(seconds: 1))),
      ]);

      final events = await journal.readAll();
      expect(
        events.where(
          (e) =>
              e.type == GameEventTypes.badgeUnlocked &&
              e.payload['badge'] == GameBadges.quartier25,
        ),
        hasLength(1),
      );
    });

    test('cell_revealed from a landmark can complete a quartier seeded by '
        'prior corridor reveals', () async {
      const topLeft = CellId(100, 100);
      final target = CellId(102, 102);
      // 15 of 64 cells already revealed (under threshold), matching what a
      // prior trip's corridor might have left behind.
      await journal.append(
        GameEvent(
          id: 'seed',
          ts: t0.subtract(const Duration(days: 1)),
          type: GameEventTypes.cellRevealed,
          payload: {'cells': _quartierCells(topLeft, 15)},
        ),
      );

      final bounds = cellBoundsLatLon(target);
      final lat = (bounds.sw.$1 + bounds.ne.$1) / 2;
      final lon = (bounds.sw.$2 + bounds.ne.$2) / 2;

      final consumer = buildConsumer();
      await consumer.consume([
        reveal(poiId: 'landmark-in-quartier', lat: lat, lon: lon),
      ]);

      final state = reduceAll(await journal.readAll());
      expect(state.badges, contains(GameBadges.quartier25));
    });
  });

  group('batch folding within one consume() call (fix round 1, item 2)', () {
    test('two distinct-poi visits in ONE batch both apply correctly, '
        'without needing a second journal read between them', () async {
      // Drained enough that the second (energy) visit's own +25 cafe bump
      // still lands under the x1.5 multiplier threshold (60) — same
      // reasoning as the "first-visit energy landmark" group above.
      await drainEnergyTo(-75);
      final consumer = buildConsumer();
      await consumer.consume([
        coins(poiId: 'bank-a', ts: t0),
        energy(poiId: 'cafe-b', ts: t0.add(const Duration(seconds: 1))),
      ]);

      final state = reduceAll(await journal.readAll());
      expect(state.coins, 100);
      expect(state.energy, 50); // 25 + 25 cafe.
      expect(state.xp, 50); // two distinct first-visit XPs, x1.0 each.
      expect(alerts, hasLength(2));
    });

    test(
      'a cooldown-passing revisit to the SAME poiId, in the SAME batch as '
      'its first visit, sees the first visit\'s own effect (state threads '
      'through the batch, not just across separate consume() calls)',
      () async {
        final consumer = buildConsumer();
        await consumer.consume([
          coins(ts: t0),
          coins(ts: t0.add(const Duration(hours: 25))), // cooldown passed.
        ]);

        final state = reduceAll(await journal.readAll());
        expect(state.coins, 150); // 100 (first) + 50 (diminished second).
        // Only the first visit's first-visit XP — the second sees
        // visitedPoiIds already true from folding the first visit's own
        // effect, entirely within this one batch.
        final xpEvents = (await journal.readAll()).where(
          (e) => e.type == GameEventTypes.xpEarned,
        );
        expect(xpEvents.length, 1);
      },
    );
  });

  group('resilience', () {
    test('a throwing notify callback never stops the journal write', () async {
      final consumer = GameVisitConsumer(
        journal: journal,
        notify: (text) async => throw StateError('notification plugin down'),
        newId: () => 'evt-${idCounter++}',
      );
      await consumer.consume([coins()]);

      final state = reduceAll(await journal.readAll());
      expect(state.coins, 100);
    });

    test('no notify callback at all is fine (no alert, no throw)', () async {
      final consumer = buildConsumer(withNotify: false);
      await expectLater(consumer.consume([coins()]), completes);
      final state = reduceAll(await journal.readAll());
      expect(state.coins, 100);
    });

    test('a broken visit in a batch does not stop the rest', () async {
      final consumer = buildConsumer();
      // A reveal-kind visit with a NaN position: `discCells`'s floor() on
      // NaN throws, which must cost only this one visit, not the batch.
      final broken = PendingVisit(
        poiId: 'broken',
        kind: 'reveal',
        lat: double.nan,
        lon: 6.6,
        ts: t0,
      );
      await consumer.consume([broken, coins(poiId: 'node/other', ts: t0)]);

      final state = reduceAll(await journal.readAll());
      expect(state.visitedPoiIds, contains('node/other'));
    });

    test('onJournalChanged fires once per processed visit', () async {
      var calls = 0;
      final consumer = GameVisitConsumer(
        journal: journal,
        onJournalChanged: () => calls++,
        newId: () => 'evt-${idCounter++}',
      );
      await consumer.consume([
        coins(poiId: 'node/a', ts: t0),
        coins(poiId: 'node/b', ts: t0),
      ]);
      expect(calls, 2);
    });

    test('a throwing onJournalChanged never stops the journal write', () async {
      final consumer = GameVisitConsumer(
        journal: journal,
        onJournalChanged: () => throw StateError('boom'),
        newId: () => 'evt-${idCounter++}',
      );
      await expectLater(consumer.consume([coins()]), completes);
      final state = reduceAll(await journal.readAll());
      expect(state.coins, 100);
    });
  });
}
