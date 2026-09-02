import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/grid.dart';
import 'package:randomwalk/map/fog_geometry.dart';

/// Even-odd ray-casting point-in-ring test over DECODED `[lon, lat]`
/// GeoJSON ring coordinates — a test-file-local mirror of the mechanism
/// `fog_geometry.dart` uses internally for containment, but applied here to
/// the actual, final, smoothed output, so these tests verify end-to-end
/// rendered behavior rather than re-asserting internals.
bool _pointInLonLatRing((double, double) point, List<dynamic> ring) {
  final (px, py) = point;
  var inside = false;
  final n = ring.length;
  for (var i = 0; i < n; i++) {
    final a = ring[i] as List;
    final b = ring[(i + 1) % n] as List;
    final x1 = (a[0] as num).toDouble();
    final y1 = (a[1] as num).toDouble();
    final x2 = (b[0] as num).toDouble();
    final y2 = (b[1] as num).toDouble();
    if ((y1 > py) != (y2 > py)) {
      final xIntersect = x1 + (py - y1) * (x2 - x1) / (y2 - y1);
      if (px < xIntersect) inside = !inside;
    }
  }
  return inside;
}

/// Whether `(lon, lat)` [point] is covered by the fog fill's
/// `MultiPolygon` — inside some polygon's exterior ring and not inside any
/// of THAT polygon's own hole rings. This is the actual visual contract
/// the fill layer renders (MapLibre fills a `Polygon` by exterior-minus-
/// holes, same as every other GeoJSON consumer), so it's what the nested-
/// loop regression tests below assert against, rather than any particular
/// internal ring/index shape.
bool _pointInFogFill((double, double) point, Map<String, dynamic> fillFeature) {
  final polygons = fillFeature['geometry']['coordinates'] as List;
  for (final polygon in polygons) {
    final rings = (polygon as List).cast<List>();
    if (!_pointInLonLatRing(point, rings[0])) continue;
    final inHole = rings.skip(1).any((hole) => _pointInLonLatRing(point, hole));
    if (!inHole) return true;
  }
  return false;
}

/// `(lon, lat)` of the center of grid cell ([x], [y]) — a point safely
/// inside that cell's interior even after Chaikin smoothing has rounded
/// its ring's corners.
(double, double) _cellCenterLonLat(int x, int y) {
  final sw = gridVertexLatLon(x, y);
  final ne = gridVertexLatLon(x + 1, y + 1);
  return ((sw.$2 + ne.$2) / 2, (sw.$1 + ne.$1) / 2);
}

void main() {
  group('traceGridBoundary', () {
    test('a single revealed cell traces its own 4-vertex CCW loop', () {
      final loops = traceGridBoundary({const CellId(0, 0)});
      expect(loops, hasLength(1));
      expect(loops.single.toSet(), {(0, 0), (1, 0), (1, 1), (0, 1)});
      expect(signedArea(loops.single), 1);
    });

    test('two adjacent cells merge into one loop with no interior seam', () {
      final loops = traceGridBoundary({const CellId(0, 0), const CellId(1, 0)});
      expect(loops, hasLength(1));
      // The shared edge between the two cells must not survive the trace.
      final ring = simplifyCollinear(loops.single);
      expect(ring.toSet(), {(0, 0), (2, 0), (2, 1), (0, 1)});
    });

    test('a solid NxN block traces to a single outer loop', () {
      final revealed = <CellId>{
        for (var x = 0; x < 5; x++)
          for (var y = 0; y < 5; y++) CellId(x, y),
      };
      final loops = traceGridBoundary(revealed);
      expect(loops, hasLength(1));
      final simplified = simplifyCollinear(loops.single);
      expect(simplified.toSet(), {(0, 0), (5, 0), (5, 5), (0, 5)});
      expect(signedArea(loops.single), 25);
    });

    test('a ring of revealed cells around one unrevealed pocket traces two '
        'loops: a positive outer boundary and a negative inner hole', () {
      final revealed = <CellId>{
        for (var x = 0; x < 3; x++)
          for (var y = 0; y < 3; y++)
            if (!(x == 1 && y == 1)) CellId(x, y),
      };
      final loops = traceGridBoundary(revealed);
      expect(loops, hasLength(2));
      final areas = loops.map(signedArea).toList()..sort();
      // Outer boundary encloses the full 3x3 footprint (area 9); the
      // hole loop (traced from the surrounding cells) has area -1 (the
      // one unrevealed cell), per this file's documented orientation
      // convention.
      expect(areas, [-1, 9]);
    });

    test('two disjoint blocks trace to two independent loops', () {
      final revealed = <CellId>{const CellId(0, 0), const CellId(10, 10)};
      final loops = traceGridBoundary(revealed);
      expect(loops, hasLength(2));
    });

    test('two cells touching only diagonally at one grid corner (no shared '
        'edge) trace to two separate 4-vertex loops sharing that corner, not '
        'one corrupted loop — regression test for a real infinite-loop bug '
        '(a single-successor Map silently dropped one of the two outgoing '
        'edges at the shared corner, corrupting the trace into a cycle that '
        'never returned to its start)', () {
      final loops = traceGridBoundary({const CellId(0, 0), const CellId(1, 1)});
      expect(loops, hasLength(2));
      final areas = loops.map(signedArea).toList()..sort();
      expect(areas, [1, 1]);
      expect(loops[0].toSet(), hasLength(4));
      expect(loops[1].toSet(), hasLength(4));
    });

    test('two ordinarily edge-adjacent cells trace without hanging — the same '
        'underlying bug also corrupted this far more common case (any shared '
        'grid vertex between two adjacent revealed cells), not just the '
        'diagonal-touch one', () {
      final loops = traceGridBoundary({const CellId(5, 5), const CellId(6, 5)});
      expect(loops, hasLength(1));
      expect(signedArea(loops.single), 2);
    });

    test('an empty revealed set traces no loops', () {
      expect(traceGridBoundary({}), isEmpty);
    });
  });

  group('signedArea', () {
    test('CCW square is positive', () {
      expect(signedArea([(0, 0), (1, 0), (1, 1), (0, 1)]), 1);
    });

    test('CW square is negative', () {
      expect(signedArea([(0, 0), (0, 1), (1, 1), (1, 0)]), -1);
    });
  });

  group('simplifyCollinear', () {
    test('drops mid-run points on a straight rectilinear edge', () {
      final ring = [
        (0, 0),
        (1, 0),
        (2, 0), // mid-run point on the bottom edge.
        (2, 1),
        (0, 1),
      ];
      expect(simplifyCollinear(ring), [(0, 0), (2, 0), (2, 1), (0, 1)]);
    });

    test('keeps every vertex of an already-simplified ring', () {
      final ring = [(0, 0), (2, 0), (2, 2), (0, 2)];
      expect(simplifyCollinear(ring), ring);
    });

    test('rings of 3 or fewer points pass through unchanged', () {
      final ring = [(0, 0), (1, 0), (0, 1)];
      expect(simplifyCollinear(ring), ring);
    });
  });

  group('chaikinSmooth', () {
    test('preserves ring closure (first == last)', () {
      final ring = [
        (0.0, 0.0),
        (10.0, 0.0),
        (10.0, 10.0),
        (0.0, 10.0),
        (0.0, 0.0),
      ];
      final smoothed = chaikinSmooth(ring);
      expect(smoothed.first, smoothed.last);
    });

    test('rounds corners: no output point sits exactly on an input corner '
        'after at least one iteration', () {
      final ring = [
        (0.0, 0.0),
        (10.0, 0.0),
        (10.0, 10.0),
        (0.0, 10.0),
        (0.0, 0.0),
      ];
      final smoothed = chaikinSmooth(ring, iterations: 1);
      const corners = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];
      for (final p in smoothed) {
        expect(corners.contains(p), isFalse, reason: '$p is an input corner');
      }
    });

    test('every smoothed point stays within the original ring\'s bounding '
        'box (corner-cutting never overshoots outward)', () {
      final ring = [
        (0.0, 0.0),
        (10.0, 0.0),
        (10.0, 10.0),
        (0.0, 10.0),
        (0.0, 0.0),
      ];
      final smoothed = chaikinSmooth(ring, iterations: 3);
      for (final (x, y) in smoothed) {
        expect(x, inInclusiveRange(0.0, 10.0));
        expect(y, inInclusiveRange(0.0, 10.0));
      }
    });

    test('more iterations produce more points', () {
      final ring = [
        (0.0, 0.0),
        (10.0, 0.0),
        (10.0, 10.0),
        (0.0, 10.0),
        (0.0, 0.0),
      ];
      final once = chaikinSmooth(ring, iterations: 1);
      final twice = chaikinSmooth(ring, iterations: 2);
      expect(twice.length, greaterThan(once.length));
    });

    test('a degenerate (<4-point) ring passes through unchanged', () {
      final ring = [(0.0, 0.0), (1.0, 0.0), (0.0, 0.0)];
      expect(chaikinSmooth(ring), ring);
    });
  });

  group('fogWorldGeoJson', () {
    Map<String, dynamic> decode(String json) =>
        jsonDecode(json) as Map<String, dynamic>;

    List<dynamic> features(Map<String, dynamic> doc) => doc['features'] as List;

    Map<String, dynamic> featureOfKind(Map<String, dynamic> doc, String kind) =>
        features(doc).cast<Map<String, dynamic>>().firstWhere(
          (f) => (f['properties'] as Map)['kind'] == kind,
        );

    test('is a well-formed FeatureCollection with a fill and a halo '
        'feature', () {
      final doc = decode(fogWorldGeoJson(revealed: {}));
      expect(doc['type'], 'FeatureCollection');
      expect(features(doc), hasLength(2));
      final fill = featureOfKind(doc, 'fill');
      expect(fill['geometry']['type'], 'MultiPolygon');
      final halo = featureOfKind(doc, 'halo');
      expect(halo['geometry']['type'], 'MultiLineString');
    });

    test('an empty revealed set yields just the world rectangle, no holes', () {
      final doc = decode(fogWorldGeoJson(revealed: {}));
      final fill = featureOfKind(doc, 'fill');
      final polygons = fill['geometry']['coordinates'] as List;
      expect(polygons, hasLength(1)); // one polygon: the world rect.
      final rings = polygons[0] as List;
      expect(rings, hasLength(1)); // exterior only, no holes.
      final halo = featureOfKind(doc, 'halo');
      expect((halo['geometry']['coordinates'] as List), isEmpty);
    });

    test('calling twice with the same revealed set yields byte-identical '
        'output — the whole point being that nothing here depends on a '
        'viewport or camera state', () {
      final revealed = {
        const CellId(3, 3),
        const CellId(4, 3),
        const CellId(4, 4),
      };
      final a = fogWorldGeoJson(revealed: revealed);
      final b = fogWorldGeoJson(revealed: revealed);
      expect(a, b);
    });

    test('revealing an adjacent cell produces ONE merged hole boundary, '
        'not two independent (and therefore seam-prone) polygons', () {
      final revealed = {const CellId(3, 3), const CellId(4, 3)};
      final doc = decode(fogWorldGeoJson(revealed: revealed));
      final fill = featureOfKind(doc, 'fill');
      final polygons = fill['geometry']['coordinates'] as List;
      final worldPolygon = polygons[0] as List;
      // rings[0] is the world exterior; every ring after that is a hole.
      expect(worldPolygon, hasLength(2), reason: 'exactly one merged hole');
    });

    test('the world exterior ring winds CCW and every hole ring winds CW '
        '(GeoJSON/MapLibre right-hand rule, RFC 7946 §3.1.6)', () {
      final revealed = {
        const CellId(0, 0),
        const CellId(1, 0),
        const CellId(1, 1),
      };
      final doc = decode(fogWorldGeoJson(revealed: revealed));
      final fill = featureOfKind(doc, 'fill');
      final polygons = fill['geometry']['coordinates'] as List;
      final worldPolygon = (polygons[0] as List).cast<List>();

      double ringArea(List ring) {
        final pts = ring
            .map((p) => ((p as List)[0] as num, p[1] as num))
            .toList();
        return signedArea(pts);
      }

      expect(ringArea(worldPolygon[0]), greaterThan(0), reason: 'exterior CCW');
      for (final hole in worldPolygon.skip(1)) {
        expect(ringArea(hole), lessThan(0), reason: 'hole CW');
      }
    });

    test('an unrevealed pocket fully enclosed by revealed cells becomes '
        'its own separate CCW "fog island" polygon', () {
      final revealed = <CellId>{
        for (var x = 0; x < 3; x++)
          for (var y = 0; y < 3; y++)
            if (!(x == 1 && y == 1)) CellId(x, y),
      };
      final doc = decode(fogWorldGeoJson(revealed: revealed));
      final fill = featureOfKind(doc, 'fill');
      final polygons = (fill['geometry']['coordinates'] as List).cast<List>();
      // One polygon for "world minus outer boundary" plus one standalone
      // island polygon for the enclosed unrevealed cell.
      expect(polygons, hasLength(2));
      final island = polygons[1].cast<List>();
      expect(island, hasLength(1), reason: 'island has no holes of its own');
    });

    test('reviewer regression: a revealed ring around an unrevealed pocket, '
        'plus a second, DISCONNECTED revealed island inside that same '
        'pocket (e.g. two separate trips weeks apart — a loop walked around '
        'a park, then a smaller loop inside it later, the outer loop never '
        'retraced) — the inner island must NOT be silently re-fogged', () {
      // Outer revealed "frame": a 5x5 footprint minus its inner 3x3 (an
      // annulus), leaving a 3x3 unrevealed pocket in the middle.
      final revealed = <CellId>{
        for (var x = 0; x < 5; x++)
          for (var y = 0; y < 5; y++)
            if (x < 1 || x > 3 || y < 1 || y > 3) CellId(x, y),
        // A single, disconnected revealed cell dead-center of that
        // pocket — its own neighbours (1,2)/(3,2)/(2,1)/(2,3) are all
        // still unrevealed, so this is genuinely its own connected
        // component, not touching the outer frame.
        const CellId(2, 2),
      };
      final doc = decode(fogWorldGeoJson(revealed: revealed));
      final fill = featureOfKind(doc, 'fill');

      // The genuinely explored inner island must read as clear, not
      // fog — this is exactly what sign-only classification got wrong
      // (it dumped this ring into the WORLD polygon's holes instead of
      // the enclosing fog island's, so the fog island's fill — with no
      // hole of its own — silently re-covered it).
      expect(
        _pointInFogFill(_cellCenterLonLat(2, 2), fill),
        isFalse,
        reason: 'the small revealed island must not be re-fogged',
      );
      // A neighbouring cell that IS still part of the unrevealed pocket
      // must still read as fog — the fix must not over-correct either.
      expect(_pointInFogFill(_cellCenterLonLat(1, 2), fill), isTrue);
      // A cell well outside the whole footprint (never revealed at all)
      // is fog too.
      expect(_pointInFogFill(_cellCenterLonLat(20, 20), fill), isTrue);
    });

    test('three-level nesting (revealed blob -> unrevealed pocket -> '
        'revealed island) renders as exactly two polygons: the world '
        '(holding the outer boundary as its own hole) and a standalone fog-'
        'island polygon (holding the inner revealed island as ITS hole, not '
        'the world\'s) — the general depth classification this task added '
        'in place of sign-only classification', () {
      final revealed = <CellId>{
        for (var x = 0; x < 5; x++)
          for (var y = 0; y < 5; y++)
            if (x < 1 || x > 3 || y < 1 || y > 3) CellId(x, y),
        const CellId(2, 2),
      };
      final doc = decode(fogWorldGeoJson(revealed: revealed));
      final fill = featureOfKind(doc, 'fill');
      final polygons = (fill['geometry']['coordinates'] as List).cast<List>();

      expect(
        polygons,
        hasLength(2),
        reason: 'world polygon + one fog-island polygon',
      );

      final worldPolygon = polygons[0].cast<List>();
      expect(
        worldPolygon,
        hasLength(2),
        reason: 'exterior + the outer boundary as its hole',
      );

      final islandPolygon = polygons[1].cast<List>();
      expect(
        islandPolygon,
        hasLength(2),
        reason:
            'the fog island\'s own exterior + the inner revealed '
            'island as ITS hole — not the world\'s',
      );
    });

    test('every ring is closed (first coordinate == last)', () {
      final revealed = {const CellId(0, 0), const CellId(1, 0)};
      final doc = decode(fogWorldGeoJson(revealed: revealed));
      final fill = featureOfKind(doc, 'fill');
      for (final polygon in fill['geometry']['coordinates'] as List) {
        for (final ring in polygon as List) {
          final coords = ring as List;
          expect(coords.first, coords.last);
        }
      }
    });

    test('coordinates are [lon, lat] pairs within plausible world bounds', () {
      final revealed = {const CellId(100, 300)}; // somewhere in Switzerland.
      final doc = decode(fogWorldGeoJson(revealed: revealed));
      final fill = featureOfKind(doc, 'fill');
      final worldPolygon =
          ((fill['geometry']['coordinates'] as List)[0] as List);
      final hole = worldPolygon[1] as List;
      for (final coord in hole) {
        final lon = (coord as List)[0] as num;
        final lat = coord[1] as num;
        expect(lon, inInclusiveRange(-180, 180));
        expect(lat, inInclusiveRange(-85, 85));
      }
    });

    test('perf: builds a fog polygon for ~5k revealed cells comfortably '
        'inside the brief\'s <50ms indicative budget', () {
      final revealed = <CellId>{
        for (var x = 0; x < 71; x++)
          for (var y = 0; y < 71; y++) CellId(x, y),
      };
      expect(revealed.length, greaterThanOrEqualTo(5000));

      // Warm-up run (JIT/first-call overhead is not what the budget is
      // measuring).
      fogWorldGeoJson(revealed: revealed);

      final stopwatch = Stopwatch()..start();
      fogWorldGeoJson(revealed: revealed);
      stopwatch.stop();

      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(50),
        reason:
            'indicative perf budget from the Task 2h brief — a solid '
            'block is close to the worst case for this algorithm since '
            'it maximises interior-edge cancellation work, while still '
            'tracing down to a single 4-corner loop',
      );
    });

    test('perf: a fragmented shape (many small disjoint blobs) also stays '
        'inside budget', () {
      // 500 separate 3x3 blobs, spaced out so none touch — exercises the
      // "many independent loops" path rather than one big cancellation.
      final revealed = <CellId>{};
      for (var i = 0; i < 500; i++) {
        final ox = (i % 50) * 10;
        final oy = (i ~/ 50) * 10;
        for (var dx = 0; dx < 3; dx++) {
          for (var dy = 0; dy < 3; dy++) {
            revealed.add(CellId(ox + dx, oy + dy));
          }
        }
      }
      expect(revealed.length, 4500);

      fogWorldGeoJson(revealed: revealed); // Warm-up.
      final stopwatch = Stopwatch()..start();
      fogWorldGeoJson(revealed: revealed);
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, lessThan(50));
    });
  });
}
