import 'dart:math' as math;

const _earthRadiusKm = 6371.0;

double metersBetween(double lat1, double lon1, double lat2, double lon2) {
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * _earthRadiusKm * 1000 * math.asin(math.sqrt(a.toDouble()));
}

/// Local equirectangular projection: adequate for sub-km route segments.
(double x, double y) _toLocalMeters(
    double lat, double lon, double refLat, double refLon) {
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
      cum[i] = cum[i - 1] +
          metersBetween(shape[i - 1].$1, shape[i - 1].$2, shape[i].$1,
                  shape[i].$2) /
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
  const Projection(
      {required this.segmentIndex,
      required this.t,
      required this.crossTrackM,
      required this.alongKm});
}

Projection projectOntoRoute(RouteGeometry g, double lat, double lon,
    {int searchFrom = 0, int searchWindow = 40}) {
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
          alongKm: g.cumulativeKm[i] + t * segKm);
    }
  }
  return best!;
}
