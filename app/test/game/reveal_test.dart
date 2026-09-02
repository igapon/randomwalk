import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/grid.dart';
import 'package:randomwalk/game/reveal.dart';

void main() {
  group('RevealState', () {
    test('cells passed to the constructor are already revealed', () {
      final state = RevealState({const CellId(1, 1)});
      expect(state.isRevealed(const CellId(1, 1)), isTrue);
    });

    test('a cell not yet added is not revealed', () {
      final state = RevealState({});
      expect(state.isRevealed(const CellId(1, 1)), isFalse);
    });

    test('addAll returns exactly the newly revealed subset', () {
      final state = RevealState({const CellId(0, 0)});
      final newly = state.addAll([
        const CellId(0, 0),
        const CellId(1, 0),
        const CellId(2, 0),
      ]);
      expect(newly, {const CellId(1, 0), const CellId(2, 0)});
    });

    test('addAll marks the newly revealed cells as revealed afterwards', () {
      final state = RevealState({});
      state.addAll([const CellId(5, 5)]);
      expect(state.isRevealed(const CellId(5, 5)), isTrue);
    });

    test('addAll called twice with the same cells returns empty the second '
        'time', () {
      final state = RevealState({});
      state.addAll([const CellId(1, 1)]);
      final second = state.addAll([const CellId(1, 1)]);
      expect(second, isEmpty);
    });

    test('addAll with duplicate entries in the same call still returns each '
        'newly revealed cell once', () {
      final state = RevealState({});
      final newly = state.addAll([const CellId(1, 1), const CellId(1, 1)]);
      expect(newly, {const CellId(1, 1)});
    });
  });
}
