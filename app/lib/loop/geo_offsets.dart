/// Spherical offset and waypoint geometry for loop generation.
///
/// Uses the same spherical-earth model (mean radius R=6371.0 km) as
/// `nav/polyline_math.dart`'s `metersBetween`, so `destinationPoint` and
/// `metersBetween` round-trip against each other.
library;

import 'dart:math' as math;

const _earthRadiusM = 6371000.0;

double _degToRad(double deg) => deg * math.pi / 180;
double _radToDeg(double rad) => rad * 180 / math.pi;

/// Returns the point reached by travelling [distanceM] metres from
/// ([lat], [lon]) along initial bearing [bearingDeg] (degrees clockwise
/// from true north), using the standard spherical "destination point given
/// distance and bearing" formula.
(double lat, double lon) destinationPoint(
    double lat, double lon, double bearingDeg, double distanceM) {
  final phi1 = _degToRad(lat);
  final lambda1 = _degToRad(lon);
  final theta = _degToRad(bearingDeg);
  final delta = distanceM / _earthRadiusM; // angular distance

  final phi2 = math.asin(math.sin(phi1) * math.cos(delta) +
      math.cos(phi1) * math.sin(delta) * math.cos(theta));
  final lambda2 = lambda1 +
      math.atan2(
        math.sin(theta) * math.sin(delta) * math.cos(phi1),
        math.cos(delta) - math.sin(phi1) * math.sin(phi2),
      );

  return (_radToDeg(phi2), _radToDeg(lambda2));
}

/// Initial bearing (degrees, 0-360) from (lat1,lon1) to (lat2,lon2) along
/// the great circle.
double _initialBearing(double lat1, double lon1, double lat2, double lon2) {
  final phi1 = _degToRad(lat1);
  final phi2 = _degToRad(lat2);
  final dLambda = _degToRad(lon2 - lon1);
  final y = math.sin(dLambda) * math.cos(phi2);
  final x = math.cos(phi1) * math.sin(phi2) -
      math.sin(phi1) * math.cos(phi2) * math.cos(dLambda);
  final theta = math.atan2(y, x);
  return (_radToDeg(theta) + 360) % 360;
}

/// Great-circle distance in metres between two points, matching
/// `nav/polyline_math.dart`'s `metersBetween` (same R=6371 km sphere).
double _metersBetween(double lat1, double lon1, double lat2, double lon2) {
  final dLat = _degToRad(lat2 - lat1);
  final dLon = _degToRad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(_degToRad(lat1)) *
          math.cos(_degToRad(lat2)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * _earthRadiusM * math.asin(math.sqrt(a.toDouble()));
}

/// Returns [count] points equally spaced in azimuth around a circle of
/// radius [radiusM] centred at ([lat], [lon]), starting at
/// [startBearingDeg] and proceeding clockwise (increasing bearing).
List<(double, double)> circleWaypoints({
  required double lat,
  required double lon,
  required double radiusM,
  required int count,
  required double startBearingDeg,
}) {
  assert(count > 0, 'count must be positive');
  final stepDeg = 360.0 / count;
  return List<(double, double)>.generate(count, (i) {
    final bearing = startBearingDeg + i * stepDeg;
    return destinationPoint(lat, lon, bearing, radiusM);
  });
}

/// Returns [count] intermediate points forming a detour between foci [a]
/// and [b], bulging away from the straight a->b axis by approximately
/// [detourM] at the midpoint (mirrored to the other side when [mirrored]
/// is true).
///
/// Implementation note: rather than solving a true ellipse (which needs a
/// numeric arc-length parameterisation to space points evenly), each point
/// is placed along the a->b axis at fraction `t = (i+1)/(count+1)` and then
/// offset perpendicular to that axis by `detourM * sin(pi * t)` — a
/// half-sine "bulge" that is 0 at both foci and reaches its maximum
/// (~detourM, matching the ellipse's semi-minor axis) at the midpoint. This
/// is simpler than exact ellipse geometry while satisfying the same
/// endpoints-at-the-foci / max-offset-at-the-centre shape.
List<(double, double)> ellipseWaypoints({
  required (double, double) a,
  required (double, double) b,
  required double detourM,
  required int count,
  required bool mirrored,
}) {
  assert(count > 0, 'count must be positive');
  final (aLat, aLon) = a;
  final (bLat, bLon) = b;
  final axisBearing = _initialBearing(aLat, aLon, bLat, bLon);
  final axisDistanceM = _metersBetween(aLat, aLon, bLat, bLon);
  final perpBearing = axisBearing + (mirrored ? -90 : 90);

  return List<(double, double)>.generate(count, (i) {
    final t = (i + 1) / (count + 1);
    final onAxis = destinationPoint(aLat, aLon, axisBearing, axisDistanceM * t);
    final bulgeM = detourM * math.sin(math.pi * t);
    final (onAxisLat, onAxisLon) = onAxis;
    return destinationPoint(onAxisLat, onAxisLon, perpBearing, bulgeM);
  });
}
