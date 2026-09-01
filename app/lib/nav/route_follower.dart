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

  /// Whether the follower has, as of this update, latched having genuinely
  /// left the destination's vicinity — [RouteFollower.leftArrivalRadius]'s
  /// value at the moment this update was produced. Carried here (rather
  /// than only readable off the [RouteFollower] instance) so a caller that
  /// only sees updates — `NavigationRuntime`, hence the persisted
  /// [TripSnapshot] — can persist it across a process restart without
  /// reaching into the follower directly.
  final bool leftArrivalRadius;

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
    this.leftArrivalRadius = false,
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
/// departure — and having genuinely left the destination's vicinity at least
/// once, see [_leftArrivalRadius], without which a loop whose path merely
/// passes close to its own start early on can arrive before the walker has
/// gone anywhere), and an ETA is derived from an EMA of recent speed once enough
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

  /// Set once and never cleared, the first time a fix's geographic distance
  /// to the route's end exceeds `arrivalRadiusM * 2` (task-8 backlog item 1).
  ///
  /// [_minProgressForArrivalKm] alone still leaves a narrow window open: it
  /// gates arrival on *path*-distance travelled (`_lastAlongKm`), not on
  /// ever having geographically left the destination's vicinity. A loop
  /// whose shape happens to pass close to its own start again early on — a
  /// short out-and-back switchback right after departure, or simply a loop
  /// route whose start and end are the same point — can rack up enough
  /// along-route distance to clear the progress floor while the walker's
  /// actual GPS fix never moved more than a few metres from that shared
  /// start/end point. `isLastManeuver` and the progress floor both still
  /// read as satisfied at that moment, so arrival would latch on a walker
  /// who has, geographically, gone nowhere.
  ///
  /// Requiring a genuine departure closes that: arrival additionally needs
  /// at least one earlier fix that was unambiguously away from the end,
  /// not just past the progress floor. The threshold is `2 *
  /// arrivalRadiusM` rather than `arrivalRadiusM` itself for hysteresis — if
  /// "left" and "arrived" used the same radius, a fix sitting almost exactly
  /// on that boundary could flicker between the two on ordinary GPS jitter;
  /// doubling it puts a dead zone between "definitely still near the
  /// destination" and "definitely left", so a real departure is unambiguous
  /// before it counts. See [_leaveArrivalRadiusThresholdM] for the same
  /// degenerate-route cap [_minProgressForArrivalKm] uses.
  bool _leftArrivalRadius;

  /// Whether this follower already considers the walker to have genuinely
  /// left the destination's vicinity — see [_leftArrivalRadius]'s own doc
  /// comment. Exposed so a caller building a *replacement* follower (a
  /// service restart seeding from a persisted [TripSnapshot], or
  /// `NavigationRuntime._adopt` after a replan) can carry the latch forward
  /// instead of every fresh instance starting from scratch.
  bool get leftArrivalRadius => _leftArrivalRadius;

  DateTime? _lastSampleTime;
  double _lastSampleAlongKm = 0;

  RouteFollower(
    this.route, {
    this.offRouteThresholdM = 30,
    this.offRouteGrace = const Duration(seconds: 10),
    this.arrivalRadiusM = 25,
    SpeedEstimator? speed,

    /// Seeds [_leftArrivalRadius] — final review item 2 (task-8's latch was
    /// per-instance and never persisted, so a service restart near the end
    /// of a trip could never latch "left" again and the trip could never
    /// arrive). Defaults to `false`, exactly the old always-fresh behaviour,
    /// so every existing call site (a brand-new trip, or one not threading
    /// this through) is unaffected; a caller resuming an in-flight trip
    /// passes the persisted value instead.
    bool leftArrivalRadius = false,
  }) : speed = speed ?? SpeedEstimator(),
       // The public parameter name (`leftArrivalRadius`) deliberately does
       // not carry the private field's underscore, so this cannot be an
       // initializing formal.
       // ignore: prefer_initializing_formals
       _leftArrivalRadius = leftArrivalRadius,
       _lastSnappedLat = route.shape.first.$1,
       _lastSnappedLon = route.shape.first.$2 {
    _geometry = RouteGeometry(route.shape);
    _maneuverAlongKm = [
      for (final m in route.maneuvers)
        _geometry.cumulativeKm[m.beginShapeIndex.clamp(
          0,
          route.shape.length - 1,
        )],
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

  /// The geographic-distance threshold [_leftArrivalRadius] latches on
  /// (task-8 backlog item 1): `2 * arrivalRadiusM`, capped at half the
  /// route's total length in metres.
  ///
  /// Without the cap, a route shorter than `2 * arrivalRadiusM` end to end
  /// (degenerate, but constructible — the same case
  /// [_minProgressForArrivalKm] already caps) could never produce a fix far
  /// enough from the end to set the flag at all, making it permanently
  /// unarrivable. Capping at half the route mirrors that guard exactly: a
  /// walker who has covered the first half of such a short route is as
  /// "departed" as this route can ever make them.
  double get _leaveArrivalRadiusThresholdM {
    final totalM = _geometry.totalKm * 1000;
    return math.min(arrivalRadiusM * 2, totalM / 2);
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
    _publishedManeuverIndex = math.max(
      _publishedManeuverIndex,
      _lastManeuverIndex,
    );

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

    final isLastManeuver =
        route.maneuvers.isEmpty ||
        _publishedManeuverIndex == route.maneuvers.length - 1;
    final remainingKm = _geometry.totalKm - _lastAlongKm;
    final distanceToManeuverM = isLastManeuver
        ? remainingKm * 1000
        : (_maneuverAlongKm[_publishedManeuverIndex] - _lastAlongKm) * 1000;

    final lastPoint = route.shape.last;
    final distanceToEndM = metersBetween(lat, lon, lastPoint.$1, lastPoint.$2);
    if (distanceToEndM > _leaveArrivalRadiusThresholdM) {
      _leftArrivalRadius = true;
    }
    if (!_arrived &&
        isLastManeuver &&
        distanceToEndM < arrivalRadiusM &&
        _lastAlongKm > _minProgressForArrivalKm &&
        _leftArrivalRadius) {
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
      leftArrivalRadius: _leftArrivalRadius,
    );
  }
}
