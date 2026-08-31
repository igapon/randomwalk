import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/events.dart';

void main() {
  GameEvent event({
    String id = 'e1',
    DateTime? ts,
    String type = GameEventTypes.coinsEarned,
    Map<String, dynamic> payload = const {'amount': 10},
  }) =>
      GameEvent(id: id, ts: ts ?? DateTime.utc(2026, 1, 1, 12), type: type, payload: payload);

  group('GameEvent JSON round-trip', () {
    test('toJson/fromJson preserves id, ts, type, payload', () {
      final e = event(
        id: 'abc-123',
        ts: DateTime.utc(2026, 3, 4, 5, 6, 7),
        type: GameEventTypes.landmarkVisited,
        payload: {'poiId': 'p1', 'kind': 'coins'},
      );
      final decoded = GameEvent.fromJson(e.toJson());
      expect(decoded.id, 'abc-123');
      expect(decoded.ts, DateTime.utc(2026, 3, 4, 5, 6, 7));
      expect(decoded.type, GameEventTypes.landmarkVisited);
      expect(decoded.payload, {'poiId': 'p1', 'kind': 'coins'});
    });

    test('missing payload key decodes to an empty map', () {
      final json = {
        'id': 'x',
        'ts': DateTime.utc(2026, 1, 1).toIso8601String(),
        'type': GameEventTypes.cellRevealed,
      };
      final decoded = GameEvent.fromJson(json);
      expect(decoded.payload, isEmpty);
    });
  });

  group('GameJournal', () {
    test('readAll on a missing file returns empty list', () async {
      final dir = await Directory.systemTemp.createTemp('journal');
      final journal = GameJournal(dir);
      expect(await journal.readAll(), isEmpty);
      expect(journal.skippedLines, 0);
    });

    test('append then readAll round-trips a single event', () async {
      final dir = await Directory.systemTemp.createTemp('journal');
      final journal = GameJournal(dir);
      final e = event(id: 'only-one');
      await journal.append(e);

      final events = await journal.readAll();
      expect(events, hasLength(1));
      expect(events.single.id, 'only-one');
      expect(events.single.type, GameEventTypes.coinsEarned);
      expect(events.single.payload, {'amount': 10});
    });

    test('preserves append order across multiple events', () async {
      final dir = await Directory.systemTemp.createTemp('journal');
      final journal = GameJournal(dir);
      await journal.append(event(id: 'first', ts: DateTime.utc(2026, 1, 1)));
      await journal.append(event(id: 'second', ts: DateTime.utc(2026, 1, 2)));
      await journal.append(event(id: 'third', ts: DateTime.utc(2026, 1, 3)));

      final events = await journal.readAll();
      expect(events.map((e) => e.id).toList(), ['first', 'second', 'third']);
    });

    test('creates the journal directory lazily on first append', () async {
      final root = await Directory.systemTemp.createTemp('journal');
      final nested = Directory('${root.path}/nested/dir');
      expect(await nested.exists(), isFalse);
      final journal = GameJournal(nested);
      await journal.append(event());
      expect(await nested.exists(), isTrue);
      expect(await journal.readAll(), hasLength(1));
    });

    test('an empty file (created but never written to) reads back as []',
        () async {
      final dir = await Directory.systemTemp.createTemp('journal');
      await File('${dir.path}/game_events.jsonl').create(recursive: true);
      final journal = GameJournal(dir);
      expect(await journal.readAll(), isEmpty);
    });

    test('skips corrupt lines, counts them, and still returns the good ones',
        () async {
      final dir = await Directory.systemTemp.createTemp('journal');
      final journal = GameJournal(dir);
      await journal.append(event(id: 'good-1'));
      // Simulate a crash mid-write: append a truncated JSON line directly.
      final file = File('${dir.path}/game_events.jsonl');
      await file.writeAsString('{"id": "trunc", "ty\n', mode: FileMode.append);
      // A line that IS valid JSON but not a valid event (missing required
      // fields) must also be tolerated, not thrown from fromJson.
      await file.writeAsString('{"not":"an event"}\n', mode: FileMode.append);
      // A stray blank line must not count as corrupt.
      await file.writeAsString('\n', mode: FileMode.append);
      await journal.append(event(id: 'good-2'));

      final events = await journal.readAll();
      expect(events.map((e) => e.id).toList(), ['good-1', 'good-2']);
      expect(journal.skippedLines, 2);
    });

    test('skippedLines reflects only the most recent readAll call', () async {
      final dir = await Directory.systemTemp.createTemp('journal');
      final journal = GameJournal(dir);
      final file = File('${dir.path}/game_events.jsonl');
      await file.writeAsString('not json at all\n');
      await journal.readAll();
      expect(journal.skippedLines, 1);

      // Overwrite with a genuinely clean file and confirm the counter resets.
      await file.writeAsString(
          '{"id":"clean","ts":"2026-01-01T00:00:00.000Z","type":"coins_earned","payload":{}}\n');
      await journal.readAll();
      expect(journal.skippedLines, 0);
    });

    test('round-trips every declared event type', () async {
      final dir = await Directory.systemTemp.createTemp('journal');
      final journal = GameJournal(dir);
      final types = [
        GameEventTypes.edgeCoveredBatch,
        GameEventTypes.cellRevealed,
        GameEventTypes.landmarkVisited,
        GameEventTypes.coinsEarned,
        GameEventTypes.coinsSpent,
        GameEventTypes.energyChanged,
        GameEventTypes.xpEarned,
        GameEventTypes.badgeUnlocked,
        GameEventTypes.streakUpdated,
      ];
      for (final t in types) {
        await journal.append(event(id: t, type: t, payload: {'k': 'v'}));
      }
      final events = await journal.readAll();
      expect(events.map((e) => e.type).toList(), types);
    });
  });
}
