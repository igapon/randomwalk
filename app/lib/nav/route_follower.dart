import 'dart:math' as math;

import '../valhalla/models.dart';
import 'eta.dart';
import 'polyline_math.dart';

/// A GPS fix whose cross-track distance exceeds this is treated as an
/// aberrant single-sample spike (e.g. multipath): it is reported but never
/// allowed to move progress backward.
const _aberrantCrossTrackM = 200.0;

/// Below this speed the EMA is noise-dominated (e.g. stationary GPS jitter),
/// not a usable pace: no ETA is reported rather than an ever-growing one.
const _minEtaSpeedMps = 0.3;

/// Upper bound on a reported ETA. A stopped walker's decaying EMA never
/// reaches exactly zero, so remaining/speed would otherwise grow without
/// bound (and, left uncapped, the resulting Duration could overflow into a
/// bogus negative value).
const _maxEtaSeconds = 24 * 60 * 60;

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
/// Progress never regresses by more than 2 segments per update (absorbing
/// projection wobble while resisting real backward snaps on self-crossing
/// routes), a single wildly-off fix (cross-track > 200 m) is reported but
/// frozen rather than applied, off-route/arrival state is latched sensibly
/// (arrival additionally requires real progress along the route — see
/// [_minProgressForArrivalKm], without which a closed loop arrives at its own
/// departure), and an ETA is derived from an EMA of recent speed once enough
/// samples exist. `alongKm` itself stays non-monotonic by design (it can wobble
/// backward within that 2-segment tolerance); only the *published*
/// `maneuverIndex` (and the instruction/distance derived from it) is floored
/// so a brief wobble right after passing a maneuver never un-announces it.
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
  late int _publishedManeuverIndex;

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
    _publishedManeuverIndex = _lastManeuverIndex;
  }

  /// How far along the route the walker must have got before arrival is
  /// allowed to latch at all (final review item 5).
  ///
  /// The bug this closes: arrival used to be "the last maneuver is active
  /// *and* we are within [arrivalRadiusM] of the final shape point", and the
  /// first half of that is true from the very first fix whenever the route
  /// has no maneuvers, or its last maneuver begins at shape index 0 — while
  /// the second half is *always* true at the departure of a **closed loop**,
  /// whose end point is its start. A loop therefore announced « Arrivé ! »
  /// before the walker had taken a step, and the trip was over. Relying on
  /// the maneuver index to rule that out was only ever a coincidence of the
  /// A→B routes Valhalla happens to return.
  ///
  /// The floor is `max(arrivalRadiusM, 2 % of the route)` — an absolute
  /// margin so GPS noise around a short route's start cannot cross it, and a
  /// relative one so a long route is not declared finished 25 m in — but
  /// never more than *half* the route, so a route shorter than the arrival
  /// radius itself (degenerate, but constructible) stays arrivable instead of
  /// becoming a trip that can never end.
  double get _minProgressForArrivalKm {
    final total = _geometry.totalKm;
    final floor = math.max(arrivalRadiusM / 1000, total * 0.02);
    return math.min(floor, total / 2);
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

    // The internal, recomputed maneuverIndex may decrease (e.g. GPS wobble
    // dropping alongKm back below a maneuver we already passed), but the
    // index/instruction we publish never un-announces a maneuver.
    _publishedManeuverIndex = math.max(_publishedManeuverIndex, _lastManeuverIndex);

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
        _publishedManeuverIndex == route.maneuvers.length - 1;
    final remainingKm = _geometry.totalKm - _lastAlongKm;
    final distanceToManeuverM = isLastManeuver
        ? remainingKm * 1000
        : (_maneuverAlongKm[_publishedManeuverIndex] - _lastAlongKm) * 1000;

    final lastPoint = route.shape.last;
    final distanceToEndM = metersBetween(lat, lon, lastPoint.$1, lastPoint.$2);
    if (!_arrived &&
        isLastManeuver &&
        distanceToEndM < arrivalRadiusM &&
        _lastAlongKm > _minProgressForArrivalKm) {
      _arrived = true;
    }

    final currentSpeed = speed.speedMps;
    Duration? eta;
    if (currentSpeed != null && currentSpeed >= _minEtaSpeedMps) {
      final rawSeconds = remainingKm * 1000 / currentSpeed;
      final cappedSeconds = math.min(rawSeconds, _maxEtaSeconds.toDouble());
      eta = Duration(seconds: cappedSeconds.round());
    }

    return NavUpdate(
      snappedLat: _lastSnappedLat,
      snappedLon: _lastSnappedLon,
      alongKm: _lastAlongKm,
      remainingKm: remainingKm,
      crossTrackM: projection.crossTrackM,
      maneuverIndex: _publishedManeuverIndex,
      instruction: route.maneuvers.isEmpty
          ? ''
          : route.maneuvers[_publishedManeuverIndex].instruction,
      distanceToManeuverM: distanceToManeuverM,
      offRoute: _offRoute,
      arrived: _arrived,
      eta: eta,
    );
  }
}
