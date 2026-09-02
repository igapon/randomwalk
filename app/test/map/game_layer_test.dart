// `GameLayer`'s own map-facing methods (`install`/`refresh`/`setVisible`)
// need a real `MapLibreMapController` (a native platform view) and cannot be
// unit-tested directly — same story as `FogLayer` itself and every screen
// that owns a `MapLibreMap`. What IS unit-testable, and Task 2j's own new
// surface, is [parseRevealedCells] — the pure conversion `GameLayer.refresh`
// (and, before this task, `AdventureScreen._parseRevealedCells`) feeds into
// `FogLayer.update`.

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/grid.dart';
import 'package:randomwalk/game/reducers.dart';
import 'package:randomwalk/map/game_layer.dart';

void main() {
  group('parseRevealedCells', () {
    test('an empty GameState yields an empty set', () {
      expect(parseRevealedCells(const GameState()), isEmpty);
    });

    test('parses every valid key into its CellId', () {
      final state = const GameState(
        revealedCellKeys: {'3_4', '-1_2', '0_0'},
      );

      expect(
        parseRevealedCells(state),
        equals({const CellId(3, 4), const CellId(-1, 2), const CellId(0, 0)}),
      );
    });

    test('silently drops a malformed key rather than throwing', () {
      final state = const GameState(
        revealedCellKeys: {'3_4', 'not-a-key', '1_2_3', ''},
      );

      expect(parseRevealedCells(state), equals({const CellId(3, 4)}));
    });
  });
}
