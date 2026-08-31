import 'dart:convert';

import '../valhalla/engine.dart';

/// A shape shorter than this cannot say anything about which edges were
/// walked — Valhalla's `trace_attributes` needs at least two points to
/// map-match anything, and a single-point (or empty) trace is not worth a
/// round trip to the engine.
const kMinTraceShapePoints = 2;

/// The OSM way ids a walked trace matched onto, plus the total length (in
/// kilometers) of the matched edges — the on-device output of Valhalla's
/// `trace_attributes` action, narrowed to exactly what `EdgesStore` and the
/// exploration event emitters need.
class MatchResult {
  /// Way ids as decimal strings (matching `EdgesStore`'s `TEXT PRIMARY KEY`
  /// column) — one entry per matched edge, in the order Valhalla returned
  /// them, duplicates included (a single OSM way can be split into several
  /// consecutive edges the trace crosses more than once).
  final List<String> wayIds;

  /// Sum of every matched edge's `length` field, in kilometers (Valhalla's
  /// default `trace_attributes` unit).
  final double matchedKm;

  const MatchResult({required this.wayIds, required this.matchedKm});
}

/// Builds a `trace_attributes` request for [shape] (a walked or ridden
/// route, as `(lat, lon)` points in order), narrowed via `filters` to just
/// `edge.way_id` and `edge.length` — the only attributes the exploration
/// pipeline needs, out of the much larger set Valhalla can return by
/// default (see `Valhalla.traceAttributes`'s own doc comment on the AAR
/// side).
String _buildTraceRequest(List<(double, double)> shape) => jsonEncode({
      'shape': [
        for (final (lat, lon) in shape) {'lat': lat, 'lon': lon},
      ],
      'costing': 'pedestrian',
      'shape_match': 'map_snap',
      'filters': {
        'attributes': ['edge.way_id', 'edge.length'],
        'action': 'include',
      },
    });

/// Map-matches [shape] onto the road network via [engine]'s `trace`
/// (`trace_attributes`) and extracts the matched way ids and total matched
/// distance.
///
/// Returns `null` on any failure whatsoever — too few points, a
/// [RoutingException] from the engine (no tiles for the area, an
/// unmatchable trace, the engine not initialized), or a response Valhalla
/// returned in a shape this function does not understand. Map-matching is a
/// best-effort exploration feature (brief: "le jeu ne bloque jamais l'outil")
/// — a caller must never let a failure here interrupt anything else a trip
/// finalising does.
Future<MatchResult?> matchTrace(
  RoutingEngine engine,
  List<(double, double)> shape,
) async {
  if (shape.length < kMinTraceShapePoints) return null;
  try {
    final raw = await engine.trace(_buildTraceRequest(shape));
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    final edges = decoded['edges'];
    if (edges is! List) return null;

    final wayIds = <String>[];
    var matchedKm = 0.0;
    for (final entry in edges) {
      if (entry is! Map) continue;
      final wayId = entry['way_id'];
      if (wayId is num) wayIds.add(wayId.toInt().toString());
      final length = entry['length'];
      if (length is num) matchedKm += length.toDouble();
    }
    return MatchResult(wayIds: wayIds, matchedKm: matchedKm);
  } catch (_) {
    return null;
  }
}
