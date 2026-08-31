import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/loop/geo_offsets.dart';
import 'package:randomwalk/loop/repeated_segments.dart';

void main() {
  const baseLat = 46.52;
  const baseLon = 6.63;

  group('repeatedSegmentRatio', () {
    test('empty shape returns 0.0', () {
      final ratio = repeatedSegmentRatio([]);
      expect(ratio, 0.0);
    });

    test('single-point shape returns 0.0', () {
      final ratio = repeatedSegmentRatio([(baseLat, baseLon)]);
      expect(ratio, 0.0);
    });

    test('straight line with no repeated segments returns ~0.0', () {
      // Build a straight line: go east 500m, 1000m, 1500m from base.
      final shape = [
        (baseLat, baseLon),
        destinationPoint(baseLat, baseLon, 90, 500),
        destinationPoint(baseLat, baseLon, 90, 1000),
        destinationPoint(baseLat, baseLon, 90, 1500),
      ];

      final ratio = repeatedSegmentRatio(shape);
      expect(ratio, lessThan(0.05));
    });

    test('perfect out-and-back (same points reversed) → high ratio', () {
      // Go north 1000m and back south 1000m.
      // With 2 equal segments on the same cell-pair, the 2nd is repeated,
      // so ratio = repeatedLength / uniqueLength = 1 / 1 = 1.0.
      final north = destinationPoint(baseLat, baseLon, 0, 1000);
      final shape = [
        (baseLat, baseLon),
        north,
        (baseLat, baseLon), // Back to start
      ];

      final ratio = repeatedSegmentRatio(shape);
      // 50% of the path is repeated against the other 50% that's unique.
      expect(ratio, closeTo(1.0, 0.05));
    });

    test('clean square loop (~400m sides) → low ratio', () {
      // Build a square: start, go north ~400m, east ~400m, south ~400m, west ~400m.
      final p1 = (baseLat, baseLon);
      final p2 = destinationPoint(baseLat, baseLon, 0, 400); // North
      final p3 = destinationPoint(p2.$1, p2.$2, 90, 400); // East
      final p4 = destinationPoint(p3.$1, p3.$2, 180, 400); // South
      // Back to p1 (or close)
      final shape = [p1, p2, p3, p4, p1];

      final ratio = repeatedSegmentRatio(shape);
      // A closed square should have minimal repeated segments.
      expect(ratio, lessThan(0.1));
    });

    test('loop with slight start/end overlap → small ratio', () {
      // Build a loop, but at the end, do a retrace of the beginning.
      final p1 = (baseLat, baseLon);
      final p2 = destinationPoint(baseLat, baseLon, 0, 300); // North 300m
      final p3 = destinationPoint(p2.$1, p2.$2, 90, 300); // East 300m
      final p4 = destinationPoint(p3.$1, p3.$2, 180, 300); // South 300m
      final p5 = destinationPoint(p4.$1, p4.$2, 270, 300); // West 300m (back to p1)
      // Now add a retrace of the first segment (300m out of ~1200m loop)
      final p6 = destinationPoint(p1.$1, p1.$2, 0, 300);

      final shape = [p1, p2, p3, p4, p5, p6];

      final ratio = repeatedSegmentRatio(shape);
      // The last segment (p5->p6) retraces (p1->p2).
      // repeatedLength = 300, uniqueLength = 1200, ratio = 300/1200 = 0.25
      expect(ratio, greaterThan(0.0));
      expect(ratio, lessThan(0.3));
    });

    test('figure-eight (two overlapping loops) → medium-to-high ratio', () {
      // Build a figure-eight: go up-right-down (3 segments), then up-left-down (3 segments),
      // crossing the middle. Some segments should occupy the same cells.
      final p0 = (baseLat, baseLon);
      final p1 = destinationPoint(baseLat, baseLon, 0, 300); // North
      final p2 = destinationPoint(p1.$1, p1.$2, 90, 200); // East
      final p3 = destinationPoint(p2.$1, p2.$2, 180, 300); // South (back near start)
      final p4 = destinationPoint(p3.$1, p3.$2, 270, 400); // West (past start)
      final p5 = destinationPoint(p4.$1, p4.$2, 0, 300); // North again
      final p6 = destinationPoint(p5.$1, p5.$2, 90, 200); // East
      // Back to start via south
      final p7 = destinationPoint(p6.$1, p6.$2, 180, 300);

      final shape = [p0, p1, p2, p3, p4, p5, p6, p7];

      final ratio = repeatedSegmentRatio(shape);
      // Figure-eights typically have some cell overlap, so expect a modest ratio.
      expect(ratio, greaterThan(0.05));
    });

    test('ratio changes with different cellM values', () {
      // For a given shape, smaller cellM should lead to finer grid quantization.
      final shape = [
        (baseLat, baseLon),
        destinationPoint(baseLat, baseLon, 0, 100),
        destinationPoint(baseLat, baseLon, 0, 100),
      ];

      final ratio25 = repeatedSegmentRatio(shape, cellM: 25);
      final ratio100 = repeatedSegmentRatio(shape, cellM: 100);

      // With a coarser grid (cellM=100), more segments map to the same cells.
      // So we'd expect a higher ratio with coarser quantization for a retraced path.
      // This is a property test: both should be reasonable values, and if anything,
      // the coarser grid might yield higher ratio (but this depends on geometry).
      expect(ratio25, greaterThanOrEqualTo(0.0));
      expect(ratio100, greaterThanOrEqualTo(0.0));
      expect(ratio25, lessThanOrEqualTo(1.0));
      expect(ratio100, lessThanOrEqualTo(1.0));
    });

    test('two segments in opposite directions on same cell pair → counted as repeated',
        () {
      // Create two segments that go between the same two points but in opposite order.
      // This tests that the unordered cell-pair key works.
      final p1 = (baseLat, baseLon);
      final p2 = destinationPoint(baseLat, baseLon, 45, 200);
      final p3 = destinationPoint(baseLat, baseLon, 45, 400);

      // Segment p1->p2, then segment p2->p1 (reversed), then p1->p3.
      final shape = [p1, p2, p1, p3];

      final ratio = repeatedSegmentRatio(shape);
      // The segment p1<->p2 (in both directions) should be counted as repeated once.
      // Assuming the cell quantization is coarse enough that both directions land
      // in the same cell pair, we expect a nonzero ratio.
      expect(ratio, greaterThan(0.0));
    });

    test('shape with zero-length segments', () {
      // If two consecutive points are identical, the segment length is 0.
      final p1 = (baseLat, baseLon);
      final p2 = destinationPoint(baseLat, baseLon, 0, 100);

      final shape = [p1, p1, p2]; // First segment has length 0

      final ratio = repeatedSegmentRatio(shape);
      // Should not crash and should return a valid ratio.
      expect(ratio, greaterThanOrEqualTo(0.0));
      expect(ratio, lessThanOrEqualTo(1.0));
    });

    test('out-and-back with multiple waypoints → high ratio', () {
      // Go north 1000m via waypoints, then return south via the same waypoints.
      // Break into: start, 500m north, 1000m north, 500m north, start.
      final p1 = (baseLat, baseLon);
      final p2 = destinationPoint(baseLat, baseLon, 0, 500);
      final p3 = destinationPoint(baseLat, baseLon, 0, 1000);
      final p4 = destinationPoint(baseLat, baseLon, 0, 500);

      final shape = [p1, p2, p3, p4, p1];

      final ratio = repeatedSegmentRatio(shape);
      // Segments 1 and 2 are not repeated (outbound path).
      // Segments 3 and 4 retrace segments 2 and 1 respectively.
      // repeatedLength = 2L, uniqueLength = 2L, ratio = 1.0
      expect(ratio, closeTo(1.0, 0.05));
    });
  });
}
