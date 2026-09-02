import 'dart:convert';

import '../game/grid.dart';

/// One closed rectilinear loop as grid-CORNER coordinates `(x, y)`
/// (integers), in CYCLIC form — i.e. NOT closed (the first vertex is not
/// repeated at the end); wraparound from the last vertex back to the first
/// is implicit. [traceGridBoundary] returns loops in this form; helpers in
/// this file that need a GeoJSON-style closed ring (first == last) do that
/// closing explicitly at their own boundary.
typedef GridRing = List<(int, int)>;

/// Traces the boundary of the union of [revealed] grid cells (see
/// `CellId`/`cellSizeM` in `grid.dart`) as a set of closed rectilinear
/// loops in grid-corner coordinates — no lat/lon, no viewport, purely a
/// function of the cell set. That last part is the whole point: the fog
/// polygon this feeds ([fogWorldGeoJson]) is a stable function of *world*
/// state (which cells are revealed), never of where the camera happens to
/// be pointed — see that function's doc comment for the correctness bug
/// this replaces.
///
/// **Algorithm** ("edge cancellation" boundary trace — standard for
/// rasterised-region-to-polygon conversion): every revealed cell
/// contributes its four unit edges, each directed so the cell's own
/// interior is on the edge's LEFT (a counter-clockwise square:
/// `(x,y)→(x+1,y)→(x+1,y+1)→(x,y+1)→(x,y)`). Whenever two revealed cells
/// are adjacent, they contribute the exact SAME edge in OPPOSITE
/// directions (each cell sees its own interior on its own left); those two
/// directed edges cancel exactly and are dropped, leaving only the edges
/// that border unrevealed territory — i.e. the boundary. What remains is a
/// directed multigraph in which every vertex's in-degree equals its
/// out-degree (0, 1, or 2 — 2 exactly when two revealed blobs touch at a
/// single corner with no shared edge, e.g. diagonally-adjacent cells), so
/// it decomposes cleanly into edge-disjoint simple cycles: repeatedly start
/// at any vertex with a remaining outgoing edge, always follow (and
/// consume) ANY one remaining outgoing edge from the current vertex, until
/// back at the start vertex — this can never dead-end partway (every
/// vertex reached still has a matching outgoing edge, by the in/out-degree
/// balance), and a vertex with two outgoing edges simply gets walked twice,
/// on two separate outer iterations, producing two separate loops that
/// happen to share that one corner. A first version of this function used
/// a single-successor `Map` instead of a per-vertex list and would corrupt
/// (and infinite-loop on) the ordinary case of two edge-adjacent revealed
/// cells, not just the diagonal-touch case — see `fog_geometry_test.dart`'s
/// "two adjacent cells" regression test.
///
/// This runs in `O(revealed.length)`: every cell contributes exactly 4
/// O(1) (amortized) map/list operations, and every surviving edge is
/// walked exactly once across the whole trace — well inside the brief's
/// "<50ms for 5k cells" indicative budget (see `fog_geometry_test.dart`'s
/// perf test).
///
/// **Loop orientation encodes role** — callers never need a separate
/// point-in-polygon test to tell "outer boundary of a revealed blob" from
/// "unrevealed pocket fully enclosed by revealed cells": the shoelace
/// [signedArea] of a loop is positive (CCW) for the former, negative (CW)
/// for the latter — a direct consequence of the edge-cancellation rule
/// above (a lone revealed cell's own 4-edge loop is already CCW/positive;
/// a hole traced from the surrounding cells' contributed edges is the
/// exact reverse). See [fogWorldGeoJson] for how the two roles become
/// GeoJSON holes vs. new exterior rings respectively.
///
/// A vertex with two outgoing edges (the diagonal-touch case) needs one
/// more piece of care beyond "just keep walking until back at `start`":
/// if the walk enters that vertex again from the OTHER cycle before ever
/// returning to `start` (which happens whenever `start` itself isn't the
/// shared vertex — i.e. most of the time, since which vertex the outer
/// loop below happens to start from is arbitrary), naively continuing
/// would wander onto the second cycle and weld both into one figure-eight
/// "loop" that revisits that vertex twice — not a simple polygon. Instead,
/// every time the walk is about to revisit a vertex already seen earlier
/// in the CURRENT walk, the sub-path since that earlier visit is spliced
/// out as its own separate closed loop right away (removed from the
/// in-progress walk, appended to the result), and the walk continues from
/// there — this is what actually separates the two cycles correctly.
///
/// **Known limitation** (unreachable from this app's disc/corridor reveal
/// shapes in practice, so deliberately not handled): nesting beyond one
/// level (e.g. a revealed island inside an unrevealed pocket inside a
/// revealed blob) is not resolved by depth; the innermost loop would be
/// attached to the wrong ring by [fogWorldGeoJson].
List<GridRing> traceGridBoundary(Set<CellId> revealed) {
  // Adjacency, allowing MULTIPLE outgoing edges per vertex — required for
  // the diagonal-touch case (see doc comment above); a single-successor
  // map would silently drop one of two distinct outgoing edges at the same
  // vertex, which is not even a rare case: it also happens at any vertex
  // shared by two ordinarily edge-adjacent revealed cells before the
  // matching cancellation is processed.
  final edges = <(int, int), List<(int, int)>>{};

  void toggleEdge((int, int) a, (int, int) b) {
    final reverseOut = edges[b];
    final reverseIndex = reverseOut?.indexOf(a) ?? -1;
    if (reverseIndex != -1) {
      // The exact reverse edge is already pending from the other side of a
      // shared interior edge -> cancel both, neither survives.
      reverseOut!.removeAt(reverseIndex);
      if (reverseOut.isEmpty) edges.remove(b);
      return;
    }
    (edges[a] ??= <(int, int)>[]).add(b);
  }

  for (final cell in revealed) {
    final x = cell.x, y = cell.y;
    final p00 = (x, y);
    final p10 = (x + 1, y);
    final p11 = (x + 1, y + 1);
    final p01 = (x, y + 1);
    toggleEdge(p00, p10);
    toggleEdge(p10, p11);
    toggleEdge(p11, p01);
    toggleEdge(p01, p00);
  }

  final loops = <GridRing>[];
  while (edges.isNotEmpty) {
    final start = edges.keys.first;
    final loop = <(int, int)>[];
    // Index of each vertex currently in `loop`, for O(1) "have we already
    // seen this vertex in the current walk" checks — see the splice logic
    // in the doc comment above.
    final indexInLoop = <(int, int), int>{};
    var current = start;
    while (true) {
      final repeatAt = indexInLoop[current];
      if (repeatAt != null) {
        final subLoop = loop.sublist(repeatAt);
        loops.add(subLoop);
        for (final v in subLoop) {
          indexInLoop.remove(v);
        }
        loop.removeRange(repeatAt, loop.length);
        if (current == start) break; // Fully closed back to the very start.
        // `current` (the shared vertex) still needs recording and walking
        // onward via its remaining edge(s) below.
      }
      indexInLoop[current] = loop.length;
      loop.add(current);
      final outs = edges[current];
      if (outs == null || outs.isEmpty) break; // Defensive.
      final next = outs.removeLast();
      if (outs.isEmpty) edges.remove(current);
      current = next;
    }
  }
  return loops;
}

/// Shoelace signed area of cyclic polygon [ring] (NOT closed — see
/// [GridRing]'s doc comment). Positive for counter-clockwise vertex order
/// (in a standard x-right/y-up plane, which `[lon, lat]` GeoJSON coordinates
/// share), negative for clockwise. Used both to classify [traceGridBoundary]
/// loops (see its doc comment) and, via [fogWorldGeoJson]'s tests, to assert
/// GeoJSON ring winding is correct for MapLibre.
double signedArea(List<(num, num)> ring) {
  var sum = 0.0;
  final n = ring.length;
  for (var i = 0; i < n; i++) {
    final (x1, y1) = ring[i];
    final (x2, y2) = ring[(i + 1) % n];
    sum += x1 * y2 - x2 * y1;
  }
  return sum / 2;
}

/// Drops every vertex of cyclic rectilinear loop [ring] that sits exactly
/// between two collinear neighbours (i.e. isn't a real corner) — a loop
/// traced cell-by-cell has one vertex per unit cell edge, most of which are
/// mid-straight-run points a smoothing/rendering pass has no reason to see.
/// Uses exact integer cross products (no floating point), so this is exact,
/// not an approximation.
List<(int, int)> simplifyCollinear(GridRing ring) {
  final n = ring.length;
  if (n <= 3) return ring;
  final kept = <(int, int)>[];
  for (var i = 0; i < n; i++) {
    final prev = ring[(i - 1 + n) % n];
    final cur = ring[i];
    final next = ring[(i + 1) % n];
    final dx1 = cur.$1 - prev.$1, dy1 = cur.$2 - prev.$2;
    final dx2 = next.$1 - cur.$1, dy2 = next.$2 - cur.$2;
    // Cross product zero <=> prev->cur->next is a straight line.
    if (dx1 * dy2 - dy1 * dx2 != 0) {
      kept.add(cur);
    }
  }
  // A ring that simplifies away entirely (shouldn't happen for a real
  // rectilinear cell boundary, which always turns at least 4 times) falls
  // back to itself rather than vanishing.
  return kept.isEmpty ? ring : kept;
}

/// Chaikin corner-cutting: [iterations] passes of replacing every vertex of
/// closed ring [ring] (GeoJSON-style — first point repeated as the last)
/// with two points at [ratio] and `1 - ratio` along each edge, rounding
/// every corner a little more each pass. This is the "lissage chaikin de la
/// géométrie fusionnée" the brief asks for turning the fog's rectilinear
/// grid corners into the soft, rounded edges of the pinned "papier non
/// exploré" look — pure Dart, no new dependency.
///
/// [ring] must be closed (`ring.first == ring.last`); the result is closed
/// the same way. A ring with fewer than 4 points (degenerate) is returned
/// unchanged — there is nothing to smooth.
List<(double, double)> chaikinSmooth(
  List<(double, double)> ring, {
  int iterations = 2,
  double ratio = 0.25,
}) {
  if (ring.length < 4) return ring;
  // Work on the open (unclosed) cyclic form so the wraparound edge (last
  // distinct point -> first point) gets smoothed exactly like every other
  // edge, then re-close once at the end.
  var points = ring.sublist(0, ring.length - 1);
  for (var iter = 0; iter < iterations; iter++) {
    final next = <(double, double)>[];
    final n = points.length;
    for (var i = 0; i < n; i++) {
      final (x1, y1) = points[i];
      final (x2, y2) = points[(i + 1) % n];
      next.add((x1 + (x2 - x1) * ratio, y1 + (y2 - y1) * ratio));
      next.add((x1 + (x2 - x1) * (1 - ratio), y1 + (y2 - y1) * (1 - ratio)));
    }
    points = next;
  }
  return [...points, points.first];
}

/// World bounding rectangle used as the fog's outer/exterior ring, clamped
/// just short of the poles (Web Mercator's own projection limit) — the fog
/// never needs to render there, so there is no reason to court the
/// projection singularity. CCW winding (south-west -> south-east ->
/// north-east -> north-west -> close), per GeoJSON's right-hand-rule
/// exterior-ring convention (RFC 7946 §3.1.6).
const kFogWorldSouth = -85.0;
const kFogWorldNorth = 85.0;
const kFogWorldWest = -180.0;
const kFogWorldEast = 180.0;

List<List<double>> _closedLonLatRing(List<(double, double)> latLonPoints) => [
  for (final (lat, lon) in latLonPoints) [lon, lat],
];

/// Builds the fog-of-war GeoJSON — **world-in-coordinates, camera-agnostic**
/// — for the current set of [revealed] cells.
///
/// Task 2h fixes a correctness bug (owner: "fog of war seems patchy and
/// changes when i move the map") whose root cause was that the fog geometry
/// was the old `fogGeoJson` (see `game/reveal.dart`'s git history):
/// generated FOR THE CURRENT VIEWPORT (`sw`/`ne` params) and regenerated on
/// every camera move past ~1 cell — i.e. the polygon set was a function of
/// where the camera was pointed, not just of which cells were revealed, so
/// panning visibly changed the fog even with zero new reveals (both because
/// cells at the old viewport's edge dropped out of the new one, and because
/// each row was emitted as an independent rectangle whose neighbours only
/// *approximately* shared an edge — those adjacent-but-separate fills is
/// also what produced the reported patchiness, distinct from the viewport
/// bug).
///
/// This function instead builds ONE polygon covering the **entire world**
/// minus the revealed union, expressed as holes — practical approach picked
/// per the brief: one large exterior ring ([kFogWorldSouth]..[kFogWorldNorth]
/// / [kFogWorldWest]..[kFogWorldEast]) with the revealed union's boundary as
/// interior rings. Nothing here reads a viewport; the ONLY input is
/// [revealed], so calling this twice with the same [revealed] set (and the
/// same [cellM]/[smoothIterations]) always yields byte-identical output
/// regardless of camera position — see `fog_geometry_test.dart`'s
/// viewport-independence test.
///
/// **Winding, worked out for MapLibre/GeoJSON's right-hand rule** (RFC 7946
/// §3.1.6: exterior rings CCW, interior/hole rings CW, as seen in
/// `[lon, lat]` = standard x-right/y-up axes):
/// - [traceGridBoundary]'s CCW (positive-area) loops are a revealed blob's
///   own outer boundary — these become the shared world polygon's HOLES, so
///   they are reversed to CW before use.
/// - Its CW (negative-area) loops are an unrevealed pocket fully enclosed by
///   revealed cells — these are fog again (unrevealed = fog by definition),
///   so each becomes its own new, separate exterior ring (a small floating
///   "fog island" Polygon in the MultiPolygon) — reversed to CCW, since a
///   single GeoJSON Polygon cannot nest a hole inside a hole (RFC 7946); an
///   island inside a hole must be its own Polygon even though it visually
///   sits inside the shared one.
///
/// The result is a `FeatureCollection` with exactly two features, both
/// consumed by `fog_layer.dart`'s two paint layers over the one shared
/// source:
/// - `properties.kind == 'fill'`: the `MultiPolygon` described above, for
///   the soft veil fill.
/// - `properties.kind == 'halo'`: a `MultiLineString` retracing every
///   hole/island ring (never the always-off-screen world rectangle) — the
///   actual revealed/fog frontier, for the `line-blur` halo layer.
///
/// Each ring is corner-rounded via [chaikinSmooth] ([smoothIterations]
/// passes, after [simplifyCollinear] discards the mid-run points a
/// grid-cell trace produces one per unit edge) — the "coins arrondis" the
/// brief asks for, replacing the fog's grid-square corners with the pinned
/// "papier non exploré" softness.
String fogWorldGeoJson({
  required Set<CellId> revealed,
  double cellM = cellSizeM,
  int smoothIterations = 2,
}) {
  final loops = traceGridBoundary(revealed);
  // Rings (each a closed `[lon, lat]` list) that become the shared world
  // polygon's interior holes.
  final worldHoles = <List<List<double>>>[];
  // Each entry is a whole standalone Polygon (a single exterior ring, no
  // holes of its own) — a "fog island" floating inside a world hole.
  final islandPolygons = <List<List<List<double>>>>[];
  // Every hole/island ring, for the halo line layer — never the world
  // rectangle itself (always off-screen, nothing to soften there).
  final haloLines = <List<List<double>>>[];

  for (final loop in loops) {
    final simplified = simplifyCollinear(loop);
    if (simplified.length < 3) continue; // Degenerate; not a real loop.

    final area = signedArea([for (final (x, y) in simplified) (x, y)]);
    final closedGrid = [...simplified, simplified.first];
    final latLon = [
      for (final (x, y) in closedGrid) gridVertexLatLon(x, y, cellM: cellM),
    ];
    final smoothed = chaikinSmooth(latLon, iterations: smoothIterations);

    if (area > 0) {
      // Revealed blob's outer boundary, traced CCW -> reverse to CW for use
      // as a hole in the world polygon (RFC 7946 §3.1.6).
      final holeRing = _closedLonLatRing(smoothed.reversed.toList());
      worldHoles.add(holeRing);
      haloLines.add(holeRing);
    } else {
      // Unrevealed pocket fully enclosed by revealed cells, traced CW ->
      // reverse to CCW for use as its own exterior ring (a hole cannot
      // nest another hole in GeoJSON, so this is a separate Polygon).
      final islandRing = _closedLonLatRing(smoothed.reversed.toList());
      islandPolygons.add([islandRing]);
      haloLines.add(islandRing);
    }
  }

  const worldRing = [
    [kFogWorldWest, kFogWorldSouth],
    [kFogWorldEast, kFogWorldSouth],
    [kFogWorldEast, kFogWorldNorth],
    [kFogWorldWest, kFogWorldNorth],
    [kFogWorldWest, kFogWorldSouth],
  ];

  final fillPolygons = <List<List<List<double>>>>[
    [worldRing, ...worldHoles],
    ...islandPolygons,
  ];

  final fillFeature = <String, dynamic>{
    'type': 'Feature',
    'properties': <String, dynamic>{'kind': 'fill'},
    'geometry': <String, dynamic>{
      'type': 'MultiPolygon',
      'coordinates': fillPolygons,
    },
  };
  final haloFeature = <String, dynamic>{
    'type': 'Feature',
    'properties': <String, dynamic>{'kind': 'halo'},
    'geometry': <String, dynamic>{
      'type': 'MultiLineString',
      'coordinates': haloLines,
    },
  };

  return jsonEncode(<String, dynamic>{
    'type': 'FeatureCollection',
    'features': [fillFeature, haloFeature],
  });
}
