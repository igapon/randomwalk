// ignore_for_file: avoid_print
//
// Deterministic generator for the GPX replay fixtures under
// `test/nav/fixtures/`. Run with:
//
//   dart run test/support/make_fixtures.dart
//
// and commit the regenerated files alongside this script — the replay
// tests never regenerate fixtures themselves, they only read what is
// committed here.
import 'dart:io';
import 'dart:math' as math;

import 'package:randomwalk/nav/polyline_math.dart';
import 'package:randomwalk/valhalla/models.dart';

/// Walking speed used to pace every fixture's trace (m/s).
const _speedMps = 1.4;

/// The reference route every fixture is replayed against: ~1.5 km across
/// four legs (three turns) near central Lausanne. 20 vertices, matching the
/// scale of a real Valhalla pedestrian route.
///
/// Kept here (rather than duplicated) so `gpx_replay_test.dart` builds its
/// `RouteFollower` from the exact same route the fixtures were traced
/// against.
RouteResult buildReferenceRoute() {
  final shape = _referenceShape();
  final geometry = RouteGeometry(shape);
  return RouteResult(
    shape: shape,
    distanceKm: geometry.totalKm,
    duration: Duration(seconds: (geometry.totalKm * 1000 / _speedMps).round()),
    // 5 maneuvers, mirroring Valhalla's own structure: an initial "depart"
    // instruction at shape index 0, one per turn, and a final arrival
    // maneuver at the last shape index. Note that `RouteFollower` never
    // *publishes* maneuverIndex 0 once any fix has been processed — index
    // 0 sits at alongKm 0, which is never "strictly ahead" of a
    // non-negative alongKm — so the four *reachable* published indices are
    // 1..4 (one per turn, plus arrival); see route_follower_test.dart's
    // "behavior 4" for the same property on a simpler route.
    maneuvers: const [
      Maneuver(
        instruction: "Marchez vers l'est sur l'avenue de la Gare",
        lengthKm: 0.6,
        beginShapeIndex: 0,
      ),
      Maneuver(
        instruction: 'Tournez à droite sur la rue du Bugnon',
        lengthKm: 0.45,
        beginShapeIndex: 7,
      ),
      Maneuver(
        instruction: 'Tournez à droite sur le chemin des Croix-Rouges',
        lengthKm: 0.3,
        beginShapeIndex: 13,
      ),
      Maneuver(
        instruction: "Tournez à droite sur l'avenue de Rumine",
        lengthKm: 0.15,
        beginShapeIndex: 17,
      ),
      Maneuver(
        instruction: 'Vous êtes arrivé à destination',
        lengthKm: 0.0,
        beginShapeIndex: 19,
      ),
    ],
  );
}

/// Four straight legs (bearings 70°, 160°, 250°, 340° — each a ~90° right
/// turn from the last) of 600 m / 450 m / 300 m / 150 m, evenly subdivided
/// into 7 / 6 / 4 / 2 segments. 1 (start) + 7 + 6 + 4 + 2 = 20 vertices,
/// 600 + 450 + 300 + 150 = 1500 m total. The three turns (vertices 7, 13,
/// 17) each get their own announced maneuver (see [buildReferenceRoute]).
List<(double, double)> _referenceShape() {
  const start = (46.5170, 6.6290); // central Lausanne
  final points = <(double, double)>[start];
  void addLeg(double bearingDeg, double totalM, int steps) {
    final stepM = totalM / steps;
    for (var i = 0; i < steps; i++) {
      points.add(_offset(points.last, bearingDeg, stepM));
    }
  }

  addLeg(70, 600, 7);
  addLeg(160, 450, 6);
  addLeg(250, 300, 4);
  addLeg(340, 150, 2);
  return points;
}

/// Offsets [from] by [distanceM] along compass bearing [bearingDeg], using
/// the same equirectangular approximation the app's own route geometry
/// uses internally — adequate for sub-km steps.
(double, double) _offset(
  (double, double) from,
  double bearingDeg,
  double distanceM,
) {
  final bearingRad = bearingDeg * math.pi / 180;
  final northM = distanceM * math.cos(bearingRad);
  final eastM = distanceM * math.sin(bearingRad);
  final lat = from.$1 + northM / 110540.0;
  final lon = from.$2 + eastM / (111320.0 * math.cos(from.$1 * math.pi / 180));
  return (lat, lon);
}

/// A single traced fix, before GPX serialization.
class _TracePoint {
  final double lat;
  final double lon;
  final DateTime time;
  const _TracePoint(this.lat, this.lon, this.time);
}

/// Interpolates a position [distanceM] along [shape], given its
/// precomputed cumulative distances (meters, same length as [shape]).
(double, double) _positionAtDistance(
  List<(double, double)> shape,
  List<double> cumulativeM,
  double distanceM,
) {
  final clamped = distanceM.clamp(0.0, cumulativeM.last);
  var i = 0;
  while (i < cumulativeM.length - 2 && cumulativeM[i + 1] < clamped) {
    i++;
  }
  final segStart = cumulativeM[i];
  final segEnd = cumulativeM[i + 1];
  final t = segEnd > segStart
      ? (clamped - segStart) / (segEnd - segStart)
      : 0.0;
  final a = shape[i];
  final b = shape[i + 1];
  return (a.$1 + (b.$1 - a.$1) * t, a.$2 + (b.$2 - a.$2) * t);
}

/// Compass bearing (degrees) of the shape segment covering [distanceM],
/// used to pick a perpendicular direction for the detour fixture.
double _bearingAtDistance(
  List<(double, double)> shape,
  List<double> cumulativeM,
  double distanceM,
) {
  var i = 0;
  while (i < cumulativeM.length - 2 && cumulativeM[i + 1] < distanceM) {
    i++;
  }
  final a = shape[i];
  final b = shape[i + 1];
  final dNorth = (b.$1 - a.$1) * 110540.0;
  final dEast = (b.$2 - a.$2) * 111320.0 * math.cos(a.$1 * math.pi / 180);
  return math.atan2(dEast, dNorth) * 180 / math.pi;
}

List<double> _cumulativeMeters(List<(double, double)> shape) {
  final geometry = RouteGeometry(shape);
  return [for (final km in geometry.cumulativeKm) km * 1000.0];
}

/// Standard-normal pair via the Box-Muller transform, consuming exactly two
/// uniform draws from [rng] — used to jitter one trace point (east, north)
/// per call, so the whole fixture is reproducible from a single seed.
(double, double) _gaussianPair(math.Random rng) {
  final u1 = rng.nextDouble().clamp(1e-12, 1.0);
  final u2 = rng.nextDouble();
  final r = math.sqrt(-2 * math.log(u1));
  return (r * math.cos(2 * math.pi * u2), r * math.sin(2 * math.pi * u2));
}

DateTime _epoch() => DateTime.utc(2026, 1, 1, 8, 0, 0);

/// Walks the reference route at [_speedMps], one fix per second, from the
/// start to the exact final vertex (the last fix always lands precisely on
/// it, regardless of rounding, so arrival always latches).
List<_TracePoint> _nominalTrace(RouteResult route) {
  final shape = route.shape;
  final cumulativeM = _cumulativeMeters(shape);
  final totalM = cumulativeM.last;
  final totalSeconds = (totalM / _speedMps).floor();
  final start = _epoch();

  final points = <_TracePoint>[];
  for (var t = 0; t <= totalSeconds; t++) {
    final (lat, lon) = _positionAtDistance(shape, cumulativeM, t * _speedMps);
    points.add(_TracePoint(lat, lon, start.add(Duration(seconds: t))));
  }
  // Exact final vertex, one second after the last regular sample, so the
  // trace always ends within the arrival radius.
  final last = shape.last;
  points.add(
    _TracePoint(
      last.$1,
      last.$2,
      start.add(Duration(seconds: totalSeconds + 1)),
    ),
  );
  return points;
}

/// Nominal trace with ±8 m gaussian noise (Box-Muller, seed 42) applied to
/// every fix independently in local east/north meters.
List<_TracePoint> _jitterTrace(RouteResult route) {
  final base = _nominalTrace(route);
  final rng = math.Random(42);
  const sigmaM = 8.0;
  return [
    for (final p in base)
      () {
        final (dz, nz) = _gaussianPair(rng);
        final (lat, lon) = _offset((p.lat, p.lon), 90, dz * sigmaM); // east
        final (lat2, lon2) = _offset((lat, lon), 0, nz * sigmaM); // north
        return _TracePoint(lat2, lon2, p.time);
      }(),
  ];
}

/// Nominal trace, except between vertex 8 and 90 s later the walker
/// steps 60 m off the route (ramping out over 5 s, holding, ramping back
/// over the final 5 s) instead of continuing forward — then rejoins the
/// route exactly where they left it and resumes.
List<_TracePoint> _detourTrace(RouteResult route) {
  final shape = route.shape;
  final cumulativeM = _cumulativeMeters(shape);
  final totalM = cumulativeM.last;
  final start = _epoch();

  const detourVertex = 8;
  final leaveDistanceM = cumulativeM[detourVertex];
  final leaveT = (leaveDistanceM / _speedMps).round();
  const detourSeconds = 90;
  const rampSeconds = 5;
  const detourOffsetM = 60.0;

  final perpendicularBearing =
      _bearingAtDistance(shape, cumulativeM, leaveDistanceM) + 90;
  final (onRouteLat, onRouteLon) = _positionAtDistance(
    shape,
    cumulativeM,
    leaveDistanceM,
  );

  final totalSeconds = (totalM / _speedMps).floor();
  final points = <_TracePoint>[];

  for (var t = 0; t <= leaveT; t++) {
    final (lat, lon) = _positionAtDistance(shape, cumulativeM, t * _speedMps);
    points.add(_TracePoint(lat, lon, start.add(Duration(seconds: t))));
  }

  for (var d = 1; d <= detourSeconds; d++) {
    double offsetM;
    if (d <= rampSeconds) {
      offsetM = detourOffsetM * d / rampSeconds;
    } else if (d >= detourSeconds - rampSeconds) {
      offsetM = detourOffsetM * (detourSeconds - d) / rampSeconds;
    } else {
      offsetM = detourOffsetM;
    }
    final (lat, lon) = _offset(
      (onRouteLat, onRouteLon),
      perpendicularBearing,
      offsetM,
    );
    points.add(_TracePoint(lat, lon, start.add(Duration(seconds: leaveT + d))));
  }

  // Resume forward progress from the point the walker left the route,
  // shifted by the 90 s spent detouring.
  final resumeT = leaveT + detourSeconds;
  for (var t = leaveT + 1; t <= totalSeconds; t++) {
    final (lat, lon) = _positionAtDistance(shape, cumulativeM, t * _speedMps);
    points.add(
      _TracePoint(
        lat,
        lon,
        start.add(Duration(seconds: resumeT + (t - leaveT))),
      ),
    );
  }
  final last = shape.last;
  final lastT = resumeT + (totalSeconds + 1 - leaveT);
  points.add(
    _TracePoint(last.$1, last.$2, start.add(Duration(seconds: lastT))),
  );
  return points;
}

/// Nominal trace with a 45 s hole (no fixes at all) opened up around the
/// midpoint of the walk — as if GPS were lost in a tunnel — while the
/// timestamps either side of the hole keep counting continuously.
List<_TracePoint> _tunnelTrace(RouteResult route) {
  final base = _nominalTrace(route);
  final midIndex = base.length ~/ 2;
  final gapStart = base[midIndex].time;
  final gapEnd = gapStart.add(const Duration(seconds: 45));
  return [
    for (final p in base)
      if (p.time.isBefore(gapStart) || !p.time.isBefore(gapEnd)) p,
  ];
}

String _toGpx(String name, List<_TracePoint> points) {
  final buffer = StringBuffer();
  buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
  buffer.writeln(
    '<gpx version="1.1" creator="randomwalk-fixtures" xmlns="http://www.topografix.com/GPX/1/1">',
  );
  buffer.writeln('  <trk>');
  buffer.writeln('    <name>$name</name>');
  buffer.writeln('    <trkseg>');
  for (final p in points) {
    buffer.writeln(
      '      <trkpt lat="${p.lat.toStringAsFixed(7)}" lon="${p.lon.toStringAsFixed(7)}">',
    );
    buffer.writeln('        <time>${p.time.toUtc().toIso8601String()}</time>');
    buffer.writeln('      </trkpt>');
  }
  buffer.writeln('    </trkseg>');
  buffer.writeln('  </trk>');
  buffer.writeln('</gpx>');
  return buffer.toString();
}

void main() {
  final route = buildReferenceRoute();
  final fixtures = <String, List<_TracePoint>>{
    'nominal': _nominalTrace(route),
    'jitter': _jitterTrace(route),
    'detour': _detourTrace(route),
    'tunnel': _tunnelTrace(route),
  };

  final dir = Directory('test/nav/fixtures');
  dir.createSync(recursive: true);
  for (final entry in fixtures.entries) {
    final file = File('${dir.path}/${entry.key}.gpx');
    file.writeAsStringSync(_toGpx(entry.key, entry.value));
    print('wrote ${file.path} (${entry.value.length} points)');
  }
}
