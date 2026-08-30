import 'dart:convert' show jsonEncode;

enum RoutingProfile { walk, bike }

class RouteRequest {
  final double fromLat, fromLon, toLat, toLon;
  final RoutingProfile profile;
  const RouteRequest(
      {required this.fromLat,
      required this.fromLon,
      required this.toLat,
      required this.toLon,
      required this.profile});

  String toValhallaJson() => jsonEncode({
        'locations': [
          {'lat': fromLat, 'lon': fromLon, 'type': 'break'},
          {'lat': toLat, 'lon': toLon, 'type': 'break'},
        ],
        'costing': profile == RoutingProfile.bike ? 'bicycle' : 'pedestrian',
        'directions_options': {'units': 'kilometers', 'language': 'fr-FR'},
      });
}

class Maneuver {
  final String instruction;
  final double lengthKm;
  final int beginShapeIndex;
  const Maneuver(
      {required this.instruction,
      required this.lengthKm,
      required this.beginShapeIndex});
}

class RouteResult {
  final List<(double, double)> shape; // (lat, lon)
  final double distanceKm;
  final Duration duration;
  final List<Maneuver> maneuvers;
  const RouteResult(
      {required this.shape,
      required this.distanceKm,
      required this.duration,
      required this.maneuvers});

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
        maneuvers.add(Maneuver(
            instruction: m['instruction'] as String? ?? '',
            lengthKm: (m['length'] as num).toDouble(),
            beginShapeIndex: offset + (m['begin_shape_index'] as int)));
      }
    }
    return RouteResult(
        shape: shape,
        distanceKm: (summary['length'] as num).toDouble(),
        duration: Duration(seconds: (summary['time'] as num).round()),
        maneuvers: maneuvers);
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

/// Test helper (encoder) — kept here so tests don't duplicate the format.
String encodePolyline6ForTest(List<(double, double)> pts) {
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
