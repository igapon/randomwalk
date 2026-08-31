import 'dart:math' as math;

import '../valhalla/models.dart';
import 'eta.dart';
import 'polyline_math.dart';

/// A GPS fix whose cross-track distance exceeds this is treated as an
/// aberrant single-sample spike (e.g. multipath): it is reported but never
/// allowed to move progress backward.
const _aberrantCrossTrackM = 200.0;

/// One turn-by-turn navigation tick, derived from a raw GPS fix by
/// [RouteFollower.update].
class NavUpdate {
  final double snappedLat, snappedLon;
  final double alongKm, remainingKm, crossTrackM;
  final int maneuverIndex;
  final String instruction;
  final double distanceToManeuverM;
  final bool offRoute;
  final bool arrived;
  final Duration? eta;

  const NavUpdate({
    required this.snappedLat,
    required this.snappedLon,
    required this.alongKm,
    required this.remainingKm,
    required this.crossTrackM,
    required this.maneuverIndex,
    required this.instruction,
    required this.distanceToManeuverM,
    required this.offRoute,
    required this.arrived,
    this.eta,
  });
}

/// Tracks a walker's/rider's progress along a planned [RouteResult],
/// turning raw GPS fixes into [NavUpdate]s.
///
/// Progress never regresses by more than 2 segments (absorbing projection
/// wobble while resisting real backward snaps on self-crossing routes), a
/// single wildly-off fix (cross-track > 200 m) is reported but frozen rather
/// than applied, off-route/arrival state is latched sensibly, and an ETA is
/// derived from an EMA of recent speed once enough samples exist.
class RouteFollower {
  final RouteResult route;
  final double offRouteThresholdM;
  final Duration offRouteGrace;
  final double arrivalRadiusM;
  final SpeedEstimator speed;

  late final RouteGeometry _geometry;
  late final List<double> _maneuverAlongKm;

  int _lastSegmentIndex = 0;
  double _lastAlongKm = 0;
  double _lastSnappedLat;
  double _lastSnappedLon;
  late int _lastManeuverIndex;

  DateTime? _offRouteSince;
  bool _offRoute = false;
  bool _arrived = false;

  DateTime? _lastSampleTime;
  double _lastSampleAlongKm = 0;

  RouteFollower(
    this.route, {
    this.offRouteThresholdM = 30,
    this.offRouteGrace = const Duration(seconds: 10),
    this.arrivalRadiusM = 25,
    SpeedEstimator? speed,
  })  : speed = speed ?? SpeedEstimator(),
        _lastSnappedLat = route.shape.first.$1,
        _lastSnappedLon = route.shape.first.$2 {
    _geometry = RouteGeometry(route.shape);
    _maneuverAlongKm = [
      for (final m in route.maneuvers)
        _geometry.cumulativeKm[m.beginShapeIndex.clamp(0, route.shape.length - 1)],
    ];
    _lastManeuverIndex = _maneuverIndexFor(0);
  }

  /// First maneuver whose position is strictly ahead of [alongKm]; if none
  /// is (we're past every maneuver's begin position), the last maneuver.
  int _maneuverIndexFor(double alongKm) {
    for (var i = 0; i < _maneuverAlongKm.length; i++) {
      if (_maneuverAlongKm[i] > alongKm) return i;
    }
    return route.maneuvers.isEmpty ? 0 : route.maneuvers.length - 1;
  }

  NavUpdate update(double lat, double lon, DateTime time) {
    final projection = projectOntoRoute(
      _geometry,
      lat,
      lon,
      searchFrom: math.max(0, _lastSegmentIndex - 2),
      searchWindow: 40,
    );

    final aberrant = projection.crossTrackM > _aberrantCrossTrackM;

    if (!aberrant) {
      _lastSegmentIndex = projection.segmentIndex;
      _lastAlongKm = projection.alongKm;

      final a = route.shape[projection.segmentIndex];
      final b = route.shape[projection.segmentIndex + 1];
      _lastSnappedLat = a.$1 + (b.$1 - a.$1) * projection.t;
      _lastSnappedLon = a.$2 + (b.$2 - a.$2) * projection.t;
      _lastManeuverIndex = _maneuverIndexFor(_lastAlongKm);

      final lastSampleTime = _lastSampleTime;
      if (lastSampleTime != null) {
        final dtSeconds = time.difference(lastSampleTime).inMicroseconds / 1e6;
        if (dtSeconds > 0) {
          final metersMoved = (_lastAlongKm - _lastSampleAlongKm) * 1000;
          speed.add(math.max(0.0, metersMoved / dtSeconds), time);
        }
      }
      _lastSampleTime = time;
      _lastSampleAlongKm = _lastAlongKm;
    }

    // Off-route timing is based on every fix's cross-track reading —
    // including aberrant ones, which are themselves evidence of being off
    // route — and only on the timestamps passed to update().
    if (projection.crossTrackM > offRouteThresholdM) {
      _offRouteSince ??= time;
      _offRoute = time.difference(_offRouteSince!) > offRouteGrace;
    } else {
      _offRouteSince = null;
      _offRoute = false;
    }

    final isLastManeuver = route.maneuvers.isEmpty ||
        _lastManeuverIndex == route.maneuvers.length - 1;
    final remainingKm = _geometry.totalKm - _lastAlongKm;
    final distanceToManeuverM = isLastManeuver
        ? remainingKm * 1000
        : (_maneuverAlongKm[_lastManeuverIndex] - _lastAlongKm) * 1000;

    final lastPoint = route.shape.last;
    final distanceToEndM = metersBetween(lat, lon, lastPoint.$1, lastPoint.$2);
    if (!_arrived && isLastManeuver && distanceToEndM < arrivalRadiusM) {
      _arrived = true;
    }

    final currentSpeed = speed.speedMps;
    final eta = (currentSpeed != null && currentSpeed > 0)
        ? Duration(seconds: (remainingKm * 1000 / currentSpeed).round())
        : null;

    return NavUpdate(
      snappedLat: _lastSnappedLat,
      snappedLon: _lastSnappedLon,
      alongKm: _lastAlongKm,
      remainingKm: remainingKm,
      crossTrackM: projection.crossTrackM,
      maneuverIndex: _lastManeuverIndex,
      instruction:
          route.maneuvers.isEmpty ? '' : route.maneuvers[_lastManeuverIndex].instruction,
      distanceToManeuverM: distanceToManeuverM,
      offRoute: _offRoute,
      arrived: _arrived,
      eta: eta,
    );
  }
}
