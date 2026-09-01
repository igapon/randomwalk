import 'dart:convert' show jsonEncode;

enum RoutingProfile { walk, bike }

/// Shared Valhalla JSON builder for costing and direction options.
Map<String, dynamic> _buildValhallaOptions(RoutingProfile profile) => {
  'costing': profile == RoutingProfile.bike ? 'bicycle' : 'pedestrian',
  'directions_options': {'units': 'kilometers', 'language': 'fr-FR'},
};

class RouteRequest {
  final double fromLat, fromLon, toLat, toLon;
  final RoutingProfile profile;
  const RouteRequest({
    required this.fromLat,
    required this.fromLon,
    required this.toLat,
    required this.toLon,
    required this.profile,
  });

  String toValhallaJson() => jsonEncode({
    'locations': [
      {'lat': fromLat, 'lon': fromLon, 'type': 'break'},
      {'lat': toLat, 'lon': toLon, 'type': 'break'},
    ],
    ..._buildValhallaOptions(profile),
  });
}

class MultiPointRouteRequest {
  final List<(double, double)> locations;
  final RoutingProfile profile;

  MultiPointRouteRequest({required this.locations, required this.profile}) {
    if (locations.length < 2) {
      throw ArgumentError('at least 2 locations required');
    }
  }

  String toValhallaJson() {
    final locObjects = <Map<String, dynamic>>[];
    for (var i = 0; i < locations.length; i++) {
      final (lat, lon) = locations[i];
      final isFirst = i == 0;
      final isLast = i == locations.length - 1;
      final type = (isFirst || isLast) ? 'break' : 'through';
      locObjects.add({'lat': lat, 'lon': lon, 'type': type});
    }

    return jsonEncode({
      'locations': locObjects,
      ..._buildValhallaOptions(profile),
    });
  }
}

class Maneuver {
  final String instruction;
  final double lengthKm;
  final int beginShapeIndex;
  const Maneuver({
    required this.instruction,
    required this.lengthKm,
    required this.beginShapeIndex,
  });

  Map<String, dynamic> toJson() => {
    'instruction': instruction,
    'lengthKm': lengthKm,
    'beginShapeIndex': beginShapeIndex,
  };

  factory Maneuver.fromJson(Map<String, dynamic> j) => Maneuver(
    instruction: j['instruction'] as String,
    lengthKm: (j['lengthKm'] as num).toDouble(),
    beginShapeIndex: j['beginShapeIndex'] as int,
  );
}

class RouteResult {
  final List<(double, double)> shape; // (lat, lon)
  final double distanceKm;
  final Duration duration;
  final List<Maneuver> maneuvers;
  const RouteResult({
    required this.shape,
    required this.distanceKm,
    required this.duration,
    required this.maneuvers,
  });

  /// Round-trippable form used to persist the *planned* route across process
  /// death (see `ActiveRouteStore`). Deliberately not Valhalla's own shape:
  /// this is our own model, and re-deriving it from a raw trip response would
  /// mean keeping (and re-parsing) the whole Valhalla payload on disk.
  /// The polyline is re-encoded rather than stored as a list of pairs — the
  /// same 1e-6 encoding the engine already speaks, ~6x smaller on disk.
  Map<String, dynamic> toJson() => {
    'shape': encodePolyline6(shape),
    'distanceKm': distanceKm,
    'durationSeconds': duration.inSeconds,
    'maneuvers': [for (final m in maneuvers) m.toJson()],
  };

  factory RouteResult.fromJson(Map<String, dynamic> j) => RouteResult(
    shape: decodePolyline6(j['shape'] as String),
    distanceKm: (j['distanceKm'] as num).toDouble(),
    duration: Duration(seconds: j['durationSeconds'] as int),
    maneuvers: [
      for (final m in (j['maneuvers'] as List<dynamic>))
        Maneuver.fromJson(m as Map<String, dynamic>),
    ],
  );

  factory RouteResult.fromValhallaJson(Map<String, dynamic> j) {
    final trip = j['trip'] as Map<String, dynamic>;
    final summary = trip['summary'] as Map<String, dynamic>;
    final legs = trip['legs'] as List<dynamic>;
    final shape = <(double, double)>[];
    final maneuvers = <Maneuver>[];
    for (final legRaw in legs) {
      final leg = legRaw as Map<String, dynamic>;
      final offset = shape.length;
      shape.addAll(decodePolyline6(leg['shape'] as String));
      for (final mRaw in (leg['maneuvers'] as List<dynamic>? ?? [])) {
        final m = mRaw as Map<String, dynamic>;
        maneuvers.add(
          Maneuver(
            instruction: m['instruction'] as String? ?? '',
            lengthKm: (m['length'] as num).toDouble(),
            beginShapeIndex: offset + (m['begin_shape_index'] as int),
          ),
        );
      }
    }
    return RouteResult(
      shape: shape,
      distanceKm: (summary['length'] as num).toDouble(),
      duration: Duration(seconds: (summary['time'] as num).round()),
      maneuvers: maneuvers,
    );
  }
}

/// Valhalla encodes shapes as Google polylines with 1e-6 precision.
List<(double, double)> decodePolyline6(String encoded) {
  final points = <(double, double)>[];
  var index = 0, lat = 0, lon = 0;
  int nextDelta() {
    var result = 0, shift = 0, b = 0x20;
    while (b >= 0x20) {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    }
    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
  }

  while (index < encoded.length) {
    lat += nextDelta();
    lon += nextDelta();
    points.add((lat / 1e6, lon / 1e6));
  }
  return points;
}

/// Inverse of [decodePolyline6]. Used by [RouteResult.toJson] to persist a
/// planned route compactly, and by the model tests to build fixtures without
/// duplicating the format.
String encodePolyline6(List<(double, double)> pts) {
  final sb = StringBuffer();
  var lastLat = 0, lastLon = 0;
  void emit(int v) {
    var value = v < 0 ? ~(v << 1) : (v << 1);
    while (value >= 0x20) {
      sb.writeCharCode((0x20 | (value & 0x1f)) + 63);
      value >>= 5;
    }
    sb.writeCharCode(value + 63);
  }

  for (final (la, lo) in pts) {
    final ila = (la * 1e6).round(), ilo = (lo * 1e6).round();
    emit(ila - lastLat);
    emit(ilo - lastLon);
    lastLat = ila;
    lastLon = ilo;
  }
  return sb.toString();
}
