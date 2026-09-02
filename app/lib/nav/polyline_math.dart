import 'dart:math' as math;

const _earthRadiusKm = 6371.0;

double metersBetween(double lat1, double lon1, double lat2, double lon2) {
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * _earthRadiusKm * 1000 * math.asin(math.sqrt(a.toDouble()));
}

/// Local equirectangular projection: adequate for sub-km route segments.
(double x, double y) _toLocalMeters(
  double lat,
  double lon,
  double refLat,
  double refLon,
) {
  final x = (lon - refLon) * 111320.0 * math.cos(refLat * math.pi / 180);
  final y = (lat - refLat) * 110540.0;
  return (x, y);
}

class RouteGeometry {
  final List<(double, double)> shape;
  late final List<double> cumulativeKm;
  RouteGeometry(this.shape)
    : assert(shape.length >= 2, 'route shape needs at least 2 points') {
    final cum = List<double>.filled(shape.length, 0);
    for (var i = 1; i < shape.length; i++) {
      cum[i] =
          cum[i - 1] +
          metersBetween(
                shape[i - 1].$1,
                shape[i - 1].$2,
                shape[i].$1,
                shape[i].$2,
              ) /
              1000.0;
    }
    cumulativeKm = cum;
  }
  double get totalKm => cumulativeKm.last;
}

class Projection {
  final int segmentIndex;
  final double t; // 0..1 along the segment
  final double crossTrackM;
  final double alongKm;
  const Projection({
    required this.segmentIndex,
    required this.t,
    required this.crossTrackM,
    required this.alongKm,
  });
}

Projection projectOntoRoute(
  RouteGeometry g,
  double lat,
  double lon, {
  int searchFrom = 0,
  int searchWindow = 40,
}) {
  final start = searchFrom.clamp(0, g.shape.length - 2);
  final end = math.min(start + searchWindow, g.shape.length - 2);
  Projection? best;
  for (var i = start; i <= end; i++) {
    final a = g.shape[i];
    final b = g.shape[i + 1];
    final (px, py) = _toLocalMeters(lat, lon, a.$1, a.$2);
    final (bx, by) = _toLocalMeters(b.$1, b.$2, a.$1, a.$2);
    final segLen2 = bx * bx + by * by;
    final t = segLen2 == 0
        ? 0.0
        : ((px * bx + py * by) / segLen2).clamp(0.0, 1.0);
    final dx = px - t * bx;
    final dy = py - t * by;
    final cross = math.sqrt(dx * dx + dy * dy);
    if (best == null || cross < best.crossTrackM) {
      final segKm = g.cumulativeKm[i + 1] - g.cumulativeKm[i];
      best = Projection(
        segmentIndex: i,
        t: t,
        crossTrackM: cross,
        alongKm: g.cumulativeKm[i] + t * segKm,
      );
    }
  }
  return best!;
}

/// Douglas-Peucker line simplification for DISPLAY purposes only — never
/// for navigation math. [RouteFollower]/[NavigationRuntime]/[Projection]
/// above all keep consuming the full-resolution `route.shape` untouched;
/// this exists purely for what gets drawn on the map.
///
/// Task 2l (owner: "la carte freeze au début" / "aussi après l'écart
/// d'itinéraire"): `map_screen.dart`'s `_drawOverlays` (route restore at
/// startup) and `_redrawRouteLine` (every replan mid-navigation) both
/// convert the FULL route shape to `LatLng` and hand it to
/// `MapLibreMapController.addLine`/`updateLine` — the one code path that
/// runs identically in both of the owner's reported freeze moments. A
/// walking route's Valhalla shape can carry many thousands of closely-
/// spaced points; simplifying it for display cuts that point count (and
/// therefore the Dart-side conversion cost and the platform-channel
/// payload) drastically while staying visually identical at normal map
/// zoom.
///
/// [toleranceM] is the maximum perpendicular deviation (meters, via a
/// local equirectangular projection — plenty accurate at route scale, same
/// approximation [projectOntoRoute] already relies on) a dropped point may
/// have strayed from the simplified line. The 3m default is tighter than a
/// phone GPS fix's own typical accuracy, so the simplified line is
/// visually indistinguishable from the full-resolution one on screen.
List<(double, double)> simplifyForDisplay(
  List<(double, double)> shape, {
  double toleranceM = 3.0,
}) {
  if (shape.length <= 2) return shape;
  final keep = List<bool>.filled(shape.length, false);
  keep[0] = true;
  keep[shape.length - 1] = true;
  _douglasPeucker(shape, 0, shape.length - 1, toleranceM, keep);
  return [
    for (var i = 0; i < shape.length; i++)
      if (keep[i]) shape[i],
  ];
}

void _douglasPeucker(
  List<(double, double)> pts,
  int first,
  int last,
  double toleranceM,
  List<bool> keep,
) {
  if (last <= first + 1) return;
  final (lat1, lon1) = pts[first];
  final (lat2, lon2) = pts[last];
  // Project the whole span into local meters around the segment's own
  // start point — same approximation `projectOntoRoute` above already uses,
  // adequate for one simplification span (never remotely close to the
  // equirectangular projection's validity limits at these distances).
  final (ex, ey) = _toLocalMeters(lat2, lon2, lat1, lon1);
  var maxDist = -1.0;
  var maxIndex = -1;
  for (var i = first + 1; i < last; i++) {
    final (lat, lon) = pts[i];
    final (px, py) = _toLocalMeters(lat, lon, lat1, lon1);
    final dist = _perpendicularDistanceM(px, py, ex, ey);
    if (dist > maxDist) {
      maxDist = dist;
      maxIndex = i;
    }
  }
  if (maxDist > toleranceM && maxIndex != -1) {
    keep[maxIndex] = true;
    _douglasPeucker(pts, first, maxIndex, toleranceM, keep);
    _douglasPeucker(pts, maxIndex, last, toleranceM, keep);
  }
}

/// Distance from local-meters point ([px], [py]) to the segment from the
/// origin to ([ex], [ey]).
double _perpendicularDistanceM(double px, double py, double ex, double ey) {
  final segLen2 = ex * ex + ey * ey;
  if (segLen2 == 0) return math.sqrt(px * px + py * py);
  final t = ((px * ex + py * ey) / segLen2).clamp(0.0, 1.0);
  final dx = px - t * ex;
  final dy = py - t * ey;
  return math.sqrt(dx * dx + dy * dy);
}
