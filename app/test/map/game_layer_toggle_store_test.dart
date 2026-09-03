import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/map/game_layer_toggle_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('GameLayerToggleStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to ON (the game layer is the product identity) when '
        'nothing was ever saved', () async {
      final store = GameLayerToggleStore();
      expect(await store.load(), isTrue);
      expect(kGameLayerEnabledDefault, isTrue);
    });

    test('round-trips a saved OFF choice', () async {
      final store = GameLayerToggleStore();
      await store.save(false);
      expect(await store.load(), isFalse);
    });

    test('round-trips a saved ON choice explicitly', () async {
      final store = GameLayerToggleStore();
      await store.save(false);
      await store.save(true);
      expect(await store.load(), isTrue);
    });

    test('persists across separate store instances (a cold start reads the '
        'same SharedPreferences-backed value)', () async {
      await GameLayerToggleStore().save(false);
      expect(await GameLayerToggleStore().load(), isFalse);
    });
  });
}
