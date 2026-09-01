import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/game/game_state_provider.dart';

void main() {
  late Directory tempDir;
  late GameJournal journal;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('game_state_provider_test');
    journal = GameJournal(Directory('${tempDir.path}/journal'));
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [gameJournalProvider.overrideWith((ref) async => journal)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'no journal file at all: resolves to the zero GameState, never throws',
    () async {
      final container = buildContainer();
      final state = await container.read(gameStateProvider.future);
      expect(state.coins, 0);
      expect(state.energy, 100);
      expect(state.xp, 0);
    },
  );

  test('replays whatever is already in the journal', () async {
    await journal.append(
      GameEvent(
        id: 'e1',
        ts: DateTime.utc(2026, 8, 30),
        type: GameEventTypes.coinsEarned,
        payload: const {'amount': 50},
      ),
    );
    final container = buildContainer();
    final state = await container.read(gameStateProvider.future);
    expect(state.coins, 50);
  });

  test(
    'a broken gameJournalProvider still resolves to the zero GameState',
    () async {
      final container = ProviderContainer(
        overrides: [
          gameJournalProvider.overrideWith(
            (ref) async => throw Exception('boom'),
          ),
        ],
      );
      addTearDown(container.dispose);

      final state = await container.read(gameStateProvider.future);
      expect(state.coins, 0);
      expect(state.xp, 0);
    },
  );

  test('GameJournalSignal.bump() invalidates gameStateProvider so a later '
      'read sees newly-appended events', () async {
    final container = buildContainer();
    expect((await container.read(gameStateProvider.future)).coins, 0);

    await journal.append(
      GameEvent(
        id: 'e1',
        ts: DateTime.utc(2026, 8, 30),
        type: GameEventTypes.coinsEarned,
        payload: const {'amount': 25},
      ),
    );
    GameJournalSignal.instance.bump();
    // Let the epoch stream's event propagate to gameJournalEpochProvider's
    // listeners before re-reading.
    await Future<void>.delayed(Duration.zero);

    expect((await container.read(gameStateProvider.future)).coins, 25);
  });

  test(
    'ref.invalidate(gameStateProvider) also forces a fresh replay',
    () async {
      final container = buildContainer();
      expect((await container.read(gameStateProvider.future)).coins, 0);

      await journal.append(
        GameEvent(
          id: 'e1',
          ts: DateTime.utc(2026, 8, 30),
          type: GameEventTypes.coinsEarned,
          payload: const {'amount': 10},
        ),
      );
      container.invalidate(gameStateProvider);

      expect((await container.read(gameStateProvider.future)).coins, 10);
    },
  );
}
