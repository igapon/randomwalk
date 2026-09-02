import 'dart:math' as math;

import '../nav/polyline_math.dart';

/// Nominal edge length of one exploration cell, in meters. Chosen to be
/// small enough for meaningful fog-of-war granularity while staying cheap
/// to store/serialize as a `Set<CellId>` (no native geo dependency, no H3 —
/// see the M4 plan's Architecture note: this grid is a stand-in for the
/// server-side H3 index the app doesn't need in M4).
const double cellSizeM = 150.0;

const double _metersPerDegLat = 110540.0;
const double _metersPerDegLon = 111320.0;

/// Latitude, in degrees, at the vertical center of latitude-band [y] (the
/// band spanned by every cell whose `CellId.y == y`), for cell size [cellM].
///
/// This is the "band's own central latitude" referenced by [cellIdFor]'s
/// longitude quantization below — see that function's doc comment for why a
/// fixed reference latitude is not used instead.
double _centralLatForBand(int y, double cellM) =>
    (y + 0.5) * cellM / _metersPerDegLat;

double _cosDeg(double degrees) => math.cos(degrees * math.pi / 180);

/// Identity of one ~150 m exploration grid cell.
///
/// **Quantization scheme** (must stay in sync with `cellIdFor`, the only
/// place that constructs a `CellId` from a lat/lon):
/// - `y = floor(lat * 110540 / cellSizeM)` — a pure function of latitude
///   alone, using the standard "meters per degree of latitude" constant
///   (110540, matching `polyline_math.dart`). Latitude bands are therefore
///   uniform-width strips of the globe, independent of longitude.
/// - `x = floor(lon * 111320 * cos(latRef) / cellSizeM)`, where `latRef` is
///   the **central latitude of band `y`** (i.e. `(y + 0.5) * cellSizeM /
///   110540`) rather than some global reference latitude. This keeps cells
///   close to square (~150 m x ~150 m) at every latitude without needing a
///   single per-region reference latitude to be threaded through every
///   call site — each row picks its own correction factor from its own `y`,
///   which is simple to reproduce anywhere `y` is known (see
///   `cellBoundsLatLon`-style helpers in `reveal.dart`).
///
/// Both `floor` operations are true mathematical floor (rounds toward
/// negative infinity), not truncation toward zero — this matters south of
/// the equator / west of the prime meridian, where a naive `~/` would quantize
/// incorrectly. Dart's `.floor()` on a `double` already has the correct
/// semantics, so `cellIdFor` uses it directly.
///
/// Key format: `'<x>_<y>'`, e.g. `'12_-34'`. This is the exact string that
/// travels as a `cell_revealed` event's `cells: List<String>` payload (see
/// the Task 1 event-schema contract) and that `reducers.dart` stores in
/// `GameState.revealedCellKeys`.
class CellId {
  final int x;
  final int y;

  const CellId(this.x, this.y);

  String get key => '${x}_$y';

  /// Parses a `'<x>_<y>'` key back into a [CellId]. Returns `null` for any
  /// string that isn't exactly two `_`-separated integers (including empty
  /// strings, keys with extra `_`-separated parts, or non-numeric parts) —
  /// this is a pure parser, never throws.
  static CellId? parseKey(String key) {
    final parts = key.split('_');
    if (parts.length != 2) return null;
    final x = int.tryParse(parts[0]);
    final y = int.tryParse(parts[1]);
    if (x == null || y == null) return null;
    return CellId(x, y);
  }

  @override
  bool operator ==(Object other) =>
      other is CellId && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'CellId($x, $y)';
}

/// Quantizes a lat/lon point to its [CellId], per the scheme documented on
/// [CellId].
CellId cellIdFor(double lat, double lon, {double cellM = cellSizeM}) {
  final y = (lat * _metersPerDegLat / cellM).floor();
  final latRef = _centralLatForBand(y, cellM);
  final x = (lon * _metersPerDegLon * _cosDeg(latRef) / cellM).floor();
  return CellId(x, y);
}

/// South-west and north-east corners (lat, lon) of cell [c]'s footprint, for
/// cell size [cellM]. Both corners share the same longitude scale factor
/// (derived from `c.y`'s central latitude), matching how [cellIdFor]
/// quantized `c.x` in the first place.
({(double, double) sw, (double, double) ne}) cellBoundsLatLon(
  CellId c, {
  double cellM = cellSizeM,
}) {
  final latRef = _centralLatForBand(c.y, cellM);
  final lonScale = _metersPerDegLon * _cosDeg(latRef);
  final latS = c.y * cellM / _metersPerDegLat;
  final latN = (c.y + 1) * cellM / _metersPerDegLat;
  final lonW = c.x * cellM / lonScale;
  final lonE = (c.x + 1) * cellM / lonScale;
  return (sw: (latS, lonW), ne: (latN, lonE));
}

/// Lat/lon of grid-CORNER vertex ([x], [y]) — the shared point where up to
/// four cells' footprints meet — as a pure function of `(x, y)` alone.
///
/// This is deliberately NOT [cellBoundsLatLon]: that function quantizes a
/// cell's footprint using the correction factor for THAT CELL's own central
/// latitude (`y + 0.5`), so two vertically-adjacent cells (rows `y` and
/// `y + 1`) each compute a slightly different longitude for the corner they
/// nominally share (the `cos(latRef)` factor differs by a hair between the
/// two rows' central latitudes). That is harmless for `cellBoundsLatLon`'s
/// original use (an isolated per-cell rectangle), but is exactly the kind
/// of sub-pixel disagreement that turns into a visible seam once cell
/// footprints get merged into one traced polygon (`fog_geometry.dart`).
///
/// Here, latitude is `y * cellM / metersPerDegLat` and longitude is
/// `x * cellM / lonScale`, where `lonScale` is evaluated at THIS vertex's
/// own latitude — a pure function of `(x, y)`, so every cell that shares
/// this corner computes the bit-for-bit identical point. That equality is
/// what lets `fog_geometry.dart`'s grid-boundary tracer merge adjacent
/// revealed cells into a single seamless ring with no floating-point gap
/// at shared corners.
(double, double) gridVertexLatLon(int x, int y, {double cellM = cellSizeM}) {
  final lat = y * cellM / _metersPerDegLat;
  final lonScale = _metersPerDegLon * _cosDeg(lat);
  final lon = x * cellM / lonScale;
  return (lat, lon);
}

/// All cells intersecting a disc of radius [radiusM] meters centered at
/// ([lat], [lon]).
///
/// Candidate cells are gathered from a generous bounding box (padded by one
/// extra cell beyond the naive radius/cellSize ratio) around the center,
/// then each candidate is kept only if the point-to-rectangle distance from
/// the center to that cell's footprint is within [radiusM]. Distances are
/// computed in a local equirectangular projection referenced at the query
/// point's own latitude — accurate for the sub-kilometer radii this game
/// uses (75 m corridor half-width, 400 m landmark reveal).
Set<CellId> discCells(
  double lat,
  double lon,
  double radiusM, {
  double cellM = cellSizeM,
}) {
  final center = cellIdFor(lat, lon, cellM: cellM);
  final cellRadius = (radiusM / cellM).ceil() + 1;

  final result = <CellId>{};
  for (var y = center.y - cellRadius; y <= center.y + cellRadius; y++) {
    for (var x = center.x - cellRadius; x <= center.x + cellRadius; x++) {
      final candidate = CellId(x, y);
      if (_distanceToCellM(lat, lon, candidate, cellM) <= radiusM) {
        result.add(candidate);
      }
    }
  }
  return result;
}

/// Distance in meters from point ([lat], [lon]) to the nearest point of
/// cell [c]'s rectangular footprint, computed in a local equirectangular
/// projection referenced at ([lat], [lon]) itself (accurate for the small
/// radii used here; see [discCells]).
double _distanceToCellM(double lat, double lon, CellId c, double cellM) {
  final bounds = cellBoundsLatLon(c, cellM: cellM);
  final lonScale = _metersPerDegLon * _cosDeg(lat);

  double toX(double pointLon) => (pointLon - lon) * lonScale;
  double toY(double pointLat) => (pointLat - lat) * _metersPerDegLat;

  final qx = 0.0; // toX(lon) == 0 by construction.
  final qy = 0.0; // toY(lat) == 0 by construction.

  final xW = toX(bounds.sw.$2);
  final xE = toX(bounds.ne.$2);
  final yS = toY(bounds.sw.$1);
  final yN = toY(bounds.ne.$1);

  final dx = qx < xW ? xW - qx : (qx > xE ? qx - xE : 0.0);
  final dy = qy < yS ? yS - qy : (qy > yN ? qy - yN : 0.0);
  return math.sqrt(dx * dx + dy * dy);
}

/// All cells within [radiusM] meters of the polyline [shape] (a route or
/// walk geometry as `(lat, lon)` points, in order).
///
/// Implementation: walks each segment in steps of at most 50 m (so no
/// segment interior is ever more than 25 m from the nearest sample), taking
/// the union of [discCells] at every sample point (segment endpoints plus
/// interpolated points). Since a 50 m step means consecutive samples are at
/// most 25 m from the true segment, and [radiusM] is always well above that
/// (75 m default corridor, 400 m landmark reveal), this union has no gaps
/// along the segment's interior — exact-enough for fog-of-war without
/// needing genuine polyline-buffer geometry.
Set<CellId> corridorCells(
  List<(double, double)> shape, {
  double radiusM = 75,
  double cellM = cellSizeM,
}) {
  final result = <CellId>{};
  if (shape.isEmpty) return result;
  if (shape.length == 1) {
    final (lat, lon) = shape.first;
    return discCells(lat, lon, radiusM, cellM: cellM);
  }

  const maxStepM = 50.0;
  for (var i = 0; i < shape.length - 1; i++) {
    final (lat1, lon1) = shape[i];
    final (lat2, lon2) = shape[i + 1];
    final segLen = metersBetween(lat1, lon1, lat2, lon2);
    final steps = math.max(1, (segLen / maxStepM).ceil());
    for (var s = 0; s <= steps; s++) {
      final t = s / steps;
      final lat = lat1 + (lat2 - lat1) * t;
      final lon = lon1 + (lon2 - lon1) * t;
      result.addAll(discCells(lat, lon, radiusM, cellM: cellM));
    }
  }
  return result;
}

/// Floor-division of [v] by 8 — i.e. `(v / 8).floor()` for integers,
/// rounding toward negative infinity rather than toward zero (`v ~/ 8`
/// would truncate toward zero and give the wrong quartier origin for
/// negative coordinates, e.g. `-1 ~/ 8 == 0` but the correct floor is `-1`).
///
/// Relies on Dart's `%` operator on `int` always returning a non-negative
/// result for a positive divisor (Euclidean remainder), which is exactly
/// what `floor` needs.
int _floorDiv8(int v) {
  final remainder = v % 8;
  return (v - remainder) ~/ 8;
}

/// The 8x8-cell "quartier" block containing [c]: its top-left (south-west)
/// [CellId] aligned to a multiple of 8 in both axes, and the block size
/// (always 8). A cell that is itself already a multiple of 8 in both `x`
/// and `y` is the top-left corner of its own quartier.
(CellId topLeft, int size) quartierOf(CellId c) {
  return (CellId(_floorDiv8(c.x) * 8, _floorDiv8(c.y) * 8), 8);
}

/// Fraction (0.0-1.0) of cell [c]'s 8x8 quartier block that is present in
/// [revealed]. Used to drive both the "% quartier" HUD stat and the
/// `quartier_25` badge threshold (emitted by the caller, not this function
/// — see the Task 1 report's note that `grid.dart` owns detecting the
/// crossing, `reducers.dart` only records the resulting `badge_unlocked`
/// event).
double quartierCompletion(CellId c, Set<CellId> revealed) {
  final (topLeft, size) = quartierOf(c);
  var count = 0;
  for (var dx = 0; dx < size; dx++) {
    for (var dy = 0; dy < size; dy++) {
      if (revealed.contains(CellId(topLeft.x + dx, topLeft.y + dy))) {
        count++;
      }
    }
  }
  return count / (size * size);
}
