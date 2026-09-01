import 'dart:math' as math;
import 'package:randomwalk/nav/polyline_math.dart';

/// Quantize a latitude-longitude point to a grid cell.
///
/// Uses the cell size [cellM] in meters and the reference latitude [refLat]
/// to ensure cells remain consistent across the shape. Returns (latCell, lonCell).
({int latCell, int lonCell}) _quantizeToCell(
  double lat,
  double lon,
  double refLat,
  double cellM,
) {
  final latCell = (lat * 111320 / cellM).round();
  final lonCell = (lon * 111320 * math.cos(refLat * math.pi / 180) / cellM)
      .round();
  return (latCell: latCell, lonCell: lonCell);
}

/// Returns an unordered pair key for two cells.
///
/// The key is a tuple (smaller cell code, larger cell code) so that
/// segments in both directions map to the same key.
(int, int) _cellPairKey(
  ({int latCell, int lonCell}) cell1,
  ({int latCell, int lonCell}) cell2,
) {
  final code1 = cell1.latCell * 1000000 + cell1.lonCell;
  final code2 = cell2.latCell * 1000000 + cell2.lonCell;
  return (code1 <= code2) ? (code1, code2) : (code2, code1);
}

/// Calculates the ratio of repeated segment distance to unique segment distance.
///
/// Quantizes each point in [shape] to a grid cell (using cell size [cellM]
/// in meters). For each segment, creates an unordered pair key of its endpoint
/// cells. Sums the length of all segments whose key was previously seen
/// (repeated length) and the length of segments seen for the first time (unique length).
///
/// Returns the ratio: repeated length / unique length, capped at 1.0.
/// - Returns 0.0 for empty shapes, single-point shapes, or shapes with no repeated segments.
/// - Returns 1.0 when all non-zero length is repeated (totalLength == repeatedLength > 0).
/// - Returns 0.0 if total length is zero.
double repeatedSegmentRatio(List<(double, double)> shape, {double cellM = 25}) {
  // Guard: empty or single-point shapes have no segments.
  if (shape.isEmpty) return 0.0;
  if (shape.length == 1) return 0.0;

  // Get the reference latitude from the first point for consistent quantization.
  final (refLat, _) = shape.first;

  // Quantize all points to grid cells.
  final cells = shape
      .map((p) => _quantizeToCell(p.$1, p.$2, refLat, cellM))
      .toList();

  // Track visited cell-pair keys and accumulate repeated distance.
  final visitedPairs = <(int, int)>{};
  var repeatedLength = 0.0;
  var totalLength = 0.0;

  // Walk each segment.
  for (var i = 0; i < shape.length - 1; i++) {
    final (lat1, lon1) = shape[i];
    final (lat2, lon2) = shape[i + 1];

    // Segment length in meters.
    final segmentLength = metersBetween(lat1, lon1, lat2, lon2);
    totalLength += segmentLength;

    // Unordered cell-pair key.
    final pairKey = _cellPairKey(cells[i], cells[i + 1]);

    // If this pair was visited before, add to repeated distance.
    if (visitedPairs.contains(pairKey)) {
      repeatedLength += segmentLength;
    }

    visitedPairs.add(pairKey);
  }

  // Guard: zero total length returns 0.0.
  if (totalLength == 0.0) return 0.0;

  // Calculate unique length.
  final uniqueLength = totalLength - repeatedLength;

  // If all length is repeated (no unique segments), return 1.0.
  if (uniqueLength == 0.0) return 1.0;

  // Return the ratio, capped at 1.0.
  return (repeatedLength / uniqueLength).clamp(0.0, 1.0);
}
