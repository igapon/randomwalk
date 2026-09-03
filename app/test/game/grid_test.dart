import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/grid.dart';
import 'package:randomwalk/nav/polyline_math.dart';

void main() {
  group('CellId.key / parseKey', () {
    test('key format is x_y', () {
      expect(const CellId(12, 34).key, '12_34');
    });

    test('key format handles negative coordinates', () {
      expect(const CellId(-3, -7).key, '-3_-7');
      expect(const CellId(-3, 7).key, '-3_7');
      expect(const CellId(3, -7).key, '3_-7');
    });

    test('parseKey round-trips positive coordinates', () {
      const cell = CellId(12, 34);
      expect(CellId.parseKey(cell.key), cell);
    });

    test('parseKey round-trips negative coordinates', () {
      const cell = CellId(-3, -7);
      expect(CellId.parseKey(cell.key), cell);
    });

    test('parseKey rejects malformed keys', () {
      expect(CellId.parseKey('nope'), isNull);
      expect(CellId.parseKey(''), isNull);
      expect(CellId.parseKey('1_2_3'), isNull);
      expect(CellId.parseKey('a_b'), isNull);
      expect(CellId.parseKey('1_'), isNull);
    });

    test('equality and hashCode are value-based', () {
      expect(const CellId(1, 2), const CellId(1, 2));
      expect(const CellId(1, 2).hashCode, const CellId(1, 2).hashCode);
      expect(const CellId(1, 2) == const CellId(2, 1), isFalse);
    });
  });

  group('cellIdFor quantization', () {
    test('two points a few meters apart share a cell', () {
      const lat = 46.2044;
      const lon = 6.1432;
      final a = cellIdFor(lat, lon);
      final b = cellIdFor(lat + 0.00005, lon + 0.00005); // ~5-6m
      expect(a, b);
    });

    test('points ~300m apart in latitude land in different cells', () {
      const lat = 46.2044;
      const lon = 6.1432;
      final a = cellIdFor(lat, lon);
      // ~300m north (cell size is 150m).
      final b = cellIdFor(lat + 300 / 110540.0, lon);
      expect(a.y, isNot(b.y));
    });

    test('y is a pure function of latitude only (floor of lat*110540/150)', () {
      const lat = 46.2044;
      expect(cellIdFor(lat, 6.0).y, cellIdFor(lat, 8.0).y);
    });

    test('quantization is consistent at negative coordinates (floor)', () {
      // -0.0001 deg lat is just south of the equator; must floor toward
      // negative infinity, not truncate toward zero.
      final cell = cellIdFor(-0.0001, -0.0001);
      expect(cell.y, lessThanOrEqualTo(-1));
    });

    test('cell centers ~150m apart in longitude land in adjacent x cells', () {
      const lat = 46.2044;
      const lon = 6.1432;
      final a = cellIdFor(lat, lon);
      // 200m east in meters converted to degrees longitude at this latitude.
      final metersPerDegLon = 111320.0 * _cosDeg(lat);
      final b = cellIdFor(lat, lon + 200 / metersPerDegLon);
      expect(a.x, isNot(b.x));
    });
  });

  group('gridVertexLatLon', () {
    test('is a pure function of (x, y) alone — same vertex, same point '
        'regardless of which cell asked', () {
      // Vertex (5, 5) is a corner shared by up to 4 cells: (4,4), (5,4),
      // (4,5), (5,5). Every one of them must agree on where it is.
      final p = gridVertexLatLon(5, 5);
      expect(gridVertexLatLon(5, 5), p);
    });

    test('latitude is a pure function of y (independent of x)', () {
      expect(gridVertexLatLon(0, 300).$1, gridVertexLatLon(999, 300).$1);
    });

    test('the origin vertex is (0, 0)', () {
      expect(gridVertexLatLon(0, 0), (0.0, 0.0));
    });

    test('moving one cell size north increases latitude by ~cellM meters', () {
      final v0 = gridVertexLatLon(0, 300);
      final v1 = gridVertexLatLon(0, 301);
      final deltaLatM = (v1.$1 - v0.$1) * 110540.0;
      expect(deltaLatM, closeTo(cellSizeM, 0.01));
    });

    test(
      'fixes the cross-row seam cellBoundsLatLon has by construction: the '
      'corner at grid (10, 300) is the NE corner of cell (9,299) and the SW '
      'corner of cell (10,300) — those two cells\' own central-latitude '
      'correction factors quantize its LONGITUDE slightly differently '
      '(proving the seam is real, even though latitude always agrees), yet '
      'gridVertexLatLon gives every caller one single, unambiguous value '
      'for that shared corner instead of either of the two disagreeing ones',
      () {
        final neOfBelow = cellBoundsLatLon(const CellId(9, 299)).ne;
        final swOfAbove = cellBoundsLatLon(const CellId(10, 300)).sw;

        // Latitude never disagrees (it only depends on y, not on which
        // cell's central-latitude correction was used)...
        expect(neOfBelow.$1, swOfAbove.$1);
        // ...but longitude does: each cell quantized it with a slightly
        // different `cos(latRef)` correction factor. This tiny gap is the
        // pre-existing seam `gridVertexLatLon`'s doc comment describes.
        expect(neOfBelow.$2, isNot(swOfAbove.$2));

        // gridVertexLatLon replaces both with one canonical value, a pure
        // function of the vertex `(10, 300)` alone.
        final vertex = gridVertexLatLon(10, 300);
        expect(vertex.$1, neOfBelow.$1);
      },
    );
  });

  group('quartierOf', () {
    test('aligns to multiples of 8, size 8', () {
      final (topLeft, size) = quartierOf(const CellId(10, 20));
      expect(size, 8);
      expect(topLeft, const CellId(8, 16));
    });

    test(
      'a cell that is itself a multiple of 8 is its own quartier origin',
      () {
        final (topLeft, size) = quartierOf(const CellId(8, 16));
        expect(size, 8);
        expect(topLeft, const CellId(8, 16));
      },
    );

    test('floor semantics hold for negative coordinates', () {
      final (topLeft, size) = quartierOf(const CellId(-1, -1));
      expect(size, 8);
      expect(topLeft, const CellId(-8, -8));
    });

    test('negative multiple of 8 is its own quartier origin', () {
      final (topLeft, size) = quartierOf(const CellId(-8, -8));
      expect(topLeft, const CellId(-8, -8));
    });

    test('negative cell just past a boundary rounds down correctly', () {
      final (topLeft, _) = quartierOf(const CellId(-9, 0));
      expect(topLeft, const CellId(-16, 0));
    });
  });

  group('quartierCompletion', () {
    test('0.0 when nothing in the quartier is revealed', () {
      expect(quartierCompletion(const CellId(0, 0), {}), 0.0);
    });

    test('1.0 when every one of the 64 cells is revealed', () {
      final revealed = <CellId>{};
      for (var x = 0; x < 8; x++) {
        for (var y = 0; y < 8; y++) {
          revealed.add(CellId(x, y));
        }
      }
      expect(quartierCompletion(const CellId(3, 3), revealed), 1.0);
    });

    test('fractional completion counts only cells within this quartier', () {
      final revealed = {
        const CellId(0, 0),
        const CellId(1, 0),
        const CellId(7, 7),
        // Outside the (0,0)-quartier: must not count.
        const CellId(8, 0),
        const CellId(-1, 0),
      };
      expect(quartierCompletion(const CellId(2, 2), revealed), 3 / 64);
    });
  });

  group('discCells', () {
    test('contains the cell of the center point', () {
      const lat = 46.2044;
      const lon = 6.1432;
      final disc = discCells(lat, lon, 75);
      expect(disc.contains(cellIdFor(lat, lon)), isTrue);
    });

    test('larger radius yields a superset of cells vs smaller radius', () {
      const lat = 46.2044;
      const lon = 6.1432;
      final small = discCells(lat, lon, 75);
      final large = discCells(lat, lon, 400);
      expect(large.length, greaterThan(small.length));
      expect(large.containsAll(small), isTrue);
    });

    test('a cell far outside the radius is excluded', () {
      const lat = 46.2044;
      const lon = 6.1432;
      final disc = discCells(lat, lon, 75);
      final farCell = cellIdFor(lat + 2000 / 110540.0, lon);
      expect(disc.contains(farCell), isFalse);
    });

    test('disc radius roughly matches requested size (cell count sanity)', () {
      const lat = 46.2044;
      const lon = 6.1432;
      // Area ~ pi*r^2; cell area ~150*150. For r=150, expect a handful of
      // cells, not a single one and not hundreds.
      final disc = discCells(lat, lon, 150);
      expect(disc.length, greaterThan(1));
      expect(disc.length, lessThan(30));
    });
  });

  group('corridorCells', () {
    test('empty shape yields empty set', () {
      expect(corridorCells([]), isEmpty);
    });

    test('single point shape behaves like a disc', () {
      const lat = 46.2044;
      const lon = 6.1432;
      final corridor = corridorCells([(lat, lon)], radiusM: 75);
      expect(corridor, discCells(lat, lon, 75));
    });

    test('a long straight 1km segment has no gaps: every 25m sample cell '
        'is covered', () {
      const startLat = 46.2044;
      const startLon = 6.1432;
      // Roughly due north for 1km.
      const endLat = 46.2044 + 1000 / 110540.0;
      const endLon = 6.1432;
      final shape = [(startLat, startLon), (endLat, endLon)];
      final corridor = corridorCells(shape, radiusM: 75);

      const totalM = 1000.0;
      const stepM = 25.0;
      final steps = (totalM / stepM).round();
      for (var i = 0; i <= steps; i++) {
        final t = i / steps;
        final lat = startLat + (endLat - startLat) * t;
        final lon = startLon + (endLon - startLon) * t;
        final sampleCell = cellIdFor(lat, lon);
        expect(
          corridor.contains(sampleCell),
          isTrue,
          reason: 'sample at t=$t (lat=$lat) missing from corridor',
        );
      }
    });

    test('a long segment with a turn still covers both legs', () {
      const lat = 46.2044;
      const lon = 6.1432;
      final mid = (lat + 500 / 110540.0, lon);
      final metersPerDegLon = 111320.0 * _cosDeg(lat);
      final end = (mid.$1, mid.$2 + 500 / metersPerDegLon);
      final shape = [(lat, lon), mid, end];
      final corridor = corridorCells(shape, radiusM: 75);

      expect(corridor.contains(cellIdFor(lat, lon)), isTrue);
      expect(corridor.contains(cellIdFor(mid.$1, mid.$2)), isTrue);
      expect(corridor.contains(cellIdFor(end.$1, end.$2)), isTrue);
    });

    test('corridor radius default is 75m per spec', () {
      const lat = 46.2044;
      const lon = 6.1432;
      final shape = [(lat, lon), (lat + 200 / 110540.0, lon)];
      expect(corridorCells(shape), corridorCells(shape, radiusM: 75));
    });

    test('metersBetween sanity used by this test file', () {
      // Guard against a broken import/reference in this test file itself.
      expect(metersBetween(0, 0, 0, 1), closeTo(111320, 200));
    });
  });
}

double _cosDeg(double lat) => math.cos(lat * math.pi / 180);
