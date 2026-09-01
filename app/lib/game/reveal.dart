import 'dart:convert';

import 'grid.dart';

/// Mutable in-memory record of which grid cells have been revealed so far.
///
/// This is *not* the durable source of truth — that is the game event
/// journal's `cell_revealed` events, replayed into `GameState.
/// revealedCellKeys` by `reducers.dart`. `RevealState` is the fast,
/// in-session working set the UI/planner consult and update between journal
/// writes (e.g. rebuilt from `GameState.revealedCellKeys` at startup, then
/// grown as new corridors/discs are revealed during a trip).
class RevealState {
  final Set<CellId> _revealed;

  RevealState(Set<CellId> revealed) : _revealed = {...revealed};

  /// A read-only snapshot of every revealed cell so far.
  Set<CellId> get revealed => Set.unmodifiable(_revealed);

  bool isRevealed(CellId cell) => _revealed.contains(cell);

  /// Marks every cell in [cells] as revealed and returns exactly the subset
  /// that was *not* already revealed before this call (i.e. the genuinely
  /// new cells) — duplicates within [cells] itself, or cells already
  /// revealed from a prior call, are excluded from the returned set even
  /// though they remain (or become) revealed in this state.
  Set<CellId> addAll(Iterable<CellId> cells) {
    final newly = <CellId>{};
    for (final cell in cells) {
      if (_revealed.add(cell)) {
        newly.add(cell);
      }
    }
    return newly;
  }
}

/// Builds the fog-of-war GeoJSON for the viewport bounded by [sw]
/// (south-west corner, `(lat, lon)`) and [ne] (north-east corner), given the
/// current set of [revealed] cells.
///
/// The result is a `FeatureCollection` with exactly one `Feature` whose
/// geometry is a single `MultiPolygon` covering every *unrevealed* cell that
/// intersects the viewport — this is the fog overlay: unrevealed = opaque,
/// revealed = transparent (nothing drawn there). Adjacent unrevealed cells
/// within the same latitude row are merged into one rectangular polygon
/// (a horizontal strip) rather than emitted one polygon per cell, keeping
/// the polygon count proportional to the number of *fog boundaries* per row
/// rather than to the number of fogged cells — a fully-fogged viewport
/// therefore yields at most one polygon per row.
///
/// A fully-revealed viewport yields an empty `MultiPolygon`
/// (`coordinates: []`), which MapLibre renders as no fog at all.
String fogGeoJson({
  required (double, double) sw,
  required (double, double) ne,
  required Set<CellId> revealed,
  double cellM = cellSizeM,
}) {
  final swCell = cellIdFor(sw.$1, sw.$2, cellM: cellM);
  final neCell = cellIdFor(ne.$1, ne.$2, cellM: cellM);

  final polygons = <List<List<List<double>>>>[];
  for (var y = swCell.y; y <= neCell.y; y++) {
    // The lon-per-cell scale depends on the row's own central latitude (see
    // CellId's doc comment), so each row re-quantizes the viewport's west/
    // east longitudes independently via `cellXForRow` rather than reusing
    // swCell.x/neCell.x (which were quantized at swCell.y/neCell.y's scale).
    final xMin = cellXForRow(sw.$2, y, cellM: cellM);
    final xMax = cellXForRow(ne.$2, y, cellM: cellM);

    int? runStart;
    for (var x = xMin; x <= xMax + 1; x++) {
      final isFog = x <= xMax && !revealed.contains(CellId(x, y));
      if (isFog) {
        runStart ??= x;
      } else if (runStart != null) {
        polygons.add(_rowStripPolygon(runStart, x - 1, y, cellM));
        runStart = null;
      }
    }
  }

  final geometry = <String, dynamic>{
    'type': 'MultiPolygon',
    'coordinates': polygons,
  };
  final featureCollection = <String, dynamic>{
    'type': 'FeatureCollection',
    'features': [
      {
        'type': 'Feature',
        'properties': <String, dynamic>{},
        'geometry': geometry,
      },
    ],
  };
  return jsonEncode(featureCollection);
}

/// One rectangular polygon ring (as a single-ring GeoJSON polygon, i.e. no
/// holes) covering the contiguous run of unrevealed cells `x` in
/// `[xStart, xEnd]` (inclusive) at row `y`. Coordinates are `[lon, lat]`
/// pairs, closed (first point repeated as the last), per the GeoJSON spec.
List<List<List<double>>> _rowStripPolygon(
  int xStart,
  int xEnd,
  int y,
  double cellM,
) {
  final westBounds = cellBoundsLatLon(CellId(xStart, y), cellM: cellM);
  final eastBounds = cellBoundsLatLon(CellId(xEnd, y), cellM: cellM);
  final latS = westBounds.sw.$1;
  final latN = westBounds.ne.$1;
  final lonW = westBounds.sw.$2;
  final lonE = eastBounds.ne.$2;

  final ring = [
    [lonW, latS],
    [lonE, latS],
    [lonE, latN],
    [lonW, latN],
    [lonW, latS],
  ];
  return [ring];
}
