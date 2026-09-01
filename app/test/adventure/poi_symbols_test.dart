import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/adventure/poi_symbols.dart';
import 'package:randomwalk/game/pois.dart';

void main() {
  const center = (46.20, 6.14);

  GamePoi poi(String id, PoiKind kind, double latOffset, double lonOffset) =>
      GamePoi(
        id: id,
        kind: kind,
        lat: center.$1 + latOffset,
        lon: center.$2 + lonOffset,
      );

  group('poiIconId', () {
    test('distinct ids per kind and visited state', () {
      final ids = {
        for (final kind in PoiKind.values)
          for (final visited in [true, false]) poiIconId(kind, visited: visited),
      };
      expect(ids, hasLength(PoiKind.values.length * 2));
    });

    test('is stable for the same inputs', () {
      expect(poiIconId(PoiKind.reveal, visited: true),
          poiIconId(PoiKind.reveal, visited: true));
    });
  });

  group('nearestPois', () {
    test('sorts nearest-first', () {
      final far = poi('far', PoiKind.reveal, 0.01, 0.01);
      final near = poi('near', PoiKind.reveal, 0.0001, 0.0001);
      final result = nearestPois([far, near], center.$1, center.$2);
      expect(result.map((p) => p.id), ['near', 'far']);
    });

    test('caps at the given limit', () {
      final pois = [
        for (var i = 0; i < 10; i++) poi('p$i', PoiKind.reveal, i * 0.001, 0),
      ];
      final result = nearestPois(pois, center.$1, center.$2, cap: 3);
      expect(result, hasLength(3));
      expect(result.map((p) => p.id), ['p0', 'p1', 'p2']);
    });

    test('defaults to the 200 cap', () {
      final pois = [
        for (var i = 0; i < 250; i++) poi('p$i', PoiKind.reveal, i * 0.0001, 0),
      ];
      expect(nearestPois(pois, center.$1, center.$2), hasLength(200));
    });

    test('an input shorter than the cap is returned unchanged (length-wise)', () {
      final pois = [poi('a', PoiKind.reveal, 0, 0)];
      expect(nearestPois(pois, center.$1, center.$2, cap: 200), hasLength(1));
    });
  });

  group('buildPoiSymbolSpecs', () {
    test('resolves the visited flag from the visitedPoiIds set, by bare poiId', () {
      final pois = [
        poi('visited-1', PoiKind.coins, 0, 0),
        poi('unvisited-1', PoiKind.energy, 0.001, 0),
      ];
      final specs = buildPoiSymbolSpecs(pois, {'visited-1'});

      final visitedSpec = specs.firstWhere((s) => s.poi.id == 'visited-1');
      final unvisitedSpec = specs.firstWhere((s) => s.poi.id == 'unvisited-1');
      expect(visitedSpec.visited, isTrue);
      expect(visitedSpec.iconId, poiIconId(PoiKind.coins, visited: true));
      expect(unvisitedSpec.visited, isFalse);
      expect(unvisitedSpec.iconId, poiIconId(PoiKind.energy, visited: false));
    });

    test('an empty POI list yields an empty spec list', () {
      expect(buildPoiSymbolSpecs(const [], {}), isEmpty);
    });
  });
}
