import 'dart:convert';

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

  group('fogGeoJson', () {
    // A small viewport whose cells we can reason about precisely.
    const sw = (46.2000, 6.1400);
    const ne = (46.2030, 6.1460);

    test(
      'is a well-formed FeatureCollection with one MultiPolygon feature',
      () {
        final json = fogGeoJson(sw: sw, ne: ne, revealed: {});
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['type'], 'FeatureCollection');
        final features = decoded['features'] as List;
        expect(features, hasLength(1));
        final geometry = features[0]['geometry'] as Map<String, dynamic>;
        expect(geometry['type'], 'MultiPolygon');
      },
    );

    test('a fully-revealed viewport yields an empty geometry', () {
      // Reveal every cell in a generous bounding box around the viewport.
      final revealed = <CellId>{};
      final swCell = cellIdFor(sw.$1, sw.$2);
      final neCell = cellIdFor(ne.$1, ne.$2);
      for (var y = swCell.y - 1; y <= neCell.y + 1; y++) {
        for (var x = swCell.x - 5; x <= neCell.x + 5; x++) {
          revealed.add(CellId(x, y));
        }
      }
      final json = fogGeoJson(sw: sw, ne: ne, revealed: revealed);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final geometry =
          (decoded['features'] as List)[0]['geometry'] as Map<String, dynamic>;
      expect(geometry['coordinates'], isEmpty);
    });

    test('a fully-fogged viewport yields at most one polygon per row', () {
      final json = fogGeoJson(sw: sw, ne: ne, revealed: {});
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final geometry =
          (decoded['features'] as List)[0]['geometry'] as Map<String, dynamic>;
      final polygons = geometry['coordinates'] as List;

      final swCell = cellIdFor(sw.$1, sw.$2);
      final neCell = cellIdFor(ne.$1, ne.$2);
      final rows = neCell.y - swCell.y + 1;

      expect(polygons, isNotEmpty);
      expect(polygons.length, lessThanOrEqualTo(rows));
    });

    test(
      'revealing a strip in the middle of a row splits it into two runs',
      () {
        final swCell = cellIdFor(sw.$1, sw.$2);
        final neCell = cellIdFor(ne.$1, ne.$2);
        final y = swCell.y;
        final xs = <int>[for (var x = swCell.x; x <= neCell.x; x++) x];
        expect(
          xs.length,
          greaterThanOrEqualTo(3),
          reason: 'viewport too narrow for this test; widen sw/ne',
        );
        final midX = xs[xs.length ~/ 2];

        final withoutGap = fogGeoJson(sw: sw, ne: ne, revealed: {});
        final withGap = fogGeoJson(sw: sw, ne: ne, revealed: {CellId(midX, y)});

        final polysWithoutGap =
            (jsonDecode(withoutGap)
                    as Map<
                      String,
                      dynamic
                    >)['features'][0]['geometry']['coordinates']
                as List;
        final polysWithGap =
            (jsonDecode(withGap)
                    as Map<
                      String,
                      dynamic
                    >)['features'][0]['geometry']['coordinates']
                as List;

        expect(polysWithGap.length, greaterThan(polysWithoutGap.length));
      },
    );

    test(
      'coordinates are [lon, lat] pairs forming closed rectangular rings',
      () {
        final json = fogGeoJson(sw: sw, ne: ne, revealed: {});
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        final polygons =
            (decoded['features'] as List)[0]['geometry']['coordinates'] as List;
        final firstPolygon = polygons.first as List;
        final ring = firstPolygon.first as List;
        // Closed ring: first and last coordinate identical.
        expect(ring.first, ring.last);
        // Every coordinate is within a plausible lon/lat range near the
        // viewport (sanity check against swapped lon/lat order).
        for (final coord in ring) {
          final lon = (coord as List)[0] as num;
          final lat = coord[1] as num;
          expect(lon, inInclusiveRange(6.0, 6.2));
          expect(lat, inInclusiveRange(46.0, 46.3));
        }
      },
    );
  });
}
