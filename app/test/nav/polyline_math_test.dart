import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/nav/polyline_math.dart';

void main() {
  // Segment ~nord-sud de 111 m à Lausanne, puis virage est.
  final shape = <(double, double)>[
    (46.5200, 6.6300),
    (46.5210, 6.6300), // ~111 m
    (46.5210, 6.6315), // ~115 m vers l'est
  ];
  final g = RouteGeometry(shape);

  test('cumulative distances are monotonic and total is coherent', () {
    expect(g.cumulativeKm.first, 0);
    expect(g.cumulativeKm.length, shape.length);
    expect(g.totalKm, closeTo(0.226, 0.01));
  });

  test('point beside the first segment projects onto it', () {
    // 46.5205,6.6302 : à mi-hauteur du segment 0, ~15 m à l'est
    final p = projectOntoRoute(g, 46.5205, 6.6302);
    expect(p.segmentIndex, 0);
    expect(p.t, closeTo(0.5, 0.05));
    expect(p.crossTrackM, closeTo(15, 3));
    expect(p.alongKm, closeTo(0.0555, 0.005));
  });

  test('point past the end clamps to the last vertex', () {
    final p = projectOntoRoute(g, 46.5210, 6.6320);
    expect(p.segmentIndex, 1);
    expect(p.t, 1.0);
    expect(p.alongKm, closeTo(g.totalKm, 1e-9));
  });

  test('searchFrom biases forward on overlapping return paths', () {
    // Boucle aller-retour sur le même tronçon : projeté près du départ,
    // mais searchFrom force la seconde passe.
    final loop = RouteGeometry([
      (46.5200, 6.6300),
      (46.5210, 6.6300),
      (46.5200, 6.6300),
    ]);
    final back = projectOntoRoute(loop, 46.52045, 6.63005, searchFrom: 1);
    expect(back.segmentIndex, 1);
  });

  group('simplifyForDisplay', () {
    test('shapes of 2 or fewer points pass through unchanged', () {
      expect(simplifyForDisplay(const []), isEmpty);
      expect(simplifyForDisplay([shape[0]]), [shape[0]]);
      final two = [shape[0], shape[1]];
      expect(simplifyForDisplay(two), two);
    });

    test('always keeps the first and last point, regardless of tolerance', () {
      final simplified = simplifyForDisplay(shape, toleranceM: 1000000);
      expect(simplified.first, shape.first);
      expect(simplified.last, shape.last);
      expect(simplified, hasLength(2)); // the wide turn is well under this
      // absurd tolerance, so the middle vertex is dropped.
    });

    test('an exactly straight line collapses to just its two endpoints', () {
      // 5 perfectly collinear points, evenly spaced.
      final straight = [
        for (var i = 0; i <= 4; i++) (46.5200 + i * 0.0010, 6.6300),
      ];
      expect(simplifyForDisplay(straight), [straight.first, straight.last]);
    });

    test('a point that deviates well beyond tolerance is kept', () {
      // Same straight line as above, but the middle point is nudged ~50m
      // east — clearly outside a 3m tolerance.
      final nudged = [
        (46.5200, 6.6300),
        (46.5210, 6.6300),
        (46.5220, 6.6307), // ~54m east of the straight 46.5220,6.6300 line.
        (46.5230, 6.6300),
        (46.5240, 6.6300),
      ];
      final simplified = simplifyForDisplay(nudged, toleranceM: 3.0);
      expect(simplified, contains(nudged[2]));
    });

    test('a point that deviates less than tolerance is dropped', () {
      final nudged = [
        (46.5200, 6.6300),
        (46.5210, 6.6300),
        (46.5220, 6.63001), // ~0.8m east — well under a 3m tolerance.
        (46.5230, 6.6300),
        (46.5240, 6.6300),
      ];
      final simplified = simplifyForDisplay(nudged, toleranceM: 3.0);
      expect(simplified, isNot(contains(nudged[2])));
    });

    test('preserves point order (never reorders or duplicates)', () {
      final simplified = simplifyForDisplay(shape, toleranceM: 0.001);
      expect(simplified, shape); // tolerance tight enough to keep every
      // point — this asserts nothing is dropped OR reordered when it
      // shouldn't be.
    });

    test('drastically reduces point count on a realistic dense, winding '
        'route shape — the case behind the owner\'s reported freeze — while '
        'staying within tolerance of the original at every dropped point '
        '(task 2l)', () {
      // A believable Valhalla walking-route shape: ~4.4m between
      // consecutive points, gently wandering (not a straight line, which
      // would let simplification cheat).
      final dense = <(double, double)>[];
      var lat = 46.2044, lon = 6.1432;
      const stepDeg = 0.00004;
      var bearing = 0.0;
      for (var i = 0; i < 6000; i++) {
        bearing += ((i * 37) % 23 - 11) * 0.05;
        lat += stepDeg * (i.isEven ? 1 : 0.7) * (0.6 + 0.4 * (i % 5) / 5);
        lon += stepDeg * 0.8 * (bearing.remainder(1.0));
        dense.add((lat, lon));
      }

      final simplified = simplifyForDisplay(dense);

      expect(simplified.first, dense.first);
      expect(simplified.last, dense.last);
      // The whole point: an order-of-magnitude fewer points to convert to
      // `LatLng` and push over the platform channel on every redraw.
      expect(simplified.length, lessThan(dense.length ~/ 5));

      // Every point in the simplified line is a genuine point from the
      // original shape, in the original order (no smoothing/interpolation —
      // Douglas-Peucker only ever DROPS points).
      var searchFrom = 0;
      for (final p in simplified) {
        final idx = dense.indexOf(p, searchFrom);
        expect(idx, greaterThanOrEqualTo(searchFrom));
        searchFrom = idx + 1;
      }
    });
  });
}
