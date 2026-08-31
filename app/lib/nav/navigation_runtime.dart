import '../valhalla/models.dart';
import 'nav_fields.dart';
import 'route_follower.dart';

/// How long a failed replan is left alone before another is attempted.
///
/// The failure this protects against is a walker who has wandered off the
/// downloaded tile set: every fix would otherwise spend a full Valhalla
/// round trip (tile reads, CPU, battery) to fail again a second later.
const kReplanRetryInterval = Duration(seconds: 30);

/// Turn-by-turn navigation as a plain object: fixes in, [NavFields] out,
/// with route recalculation folded in.
///
/// This is the whole of the navigation logic that runs inside the tracking
/// foreground service, deliberately extracted from the service handler so it
/// can be tested without an isolate, a GPS or a routing engine. The handler
/// around it is glue: it feeds fixes in and writes the fields out.
///
/// Two rules drive the design:
///
///  - **A replan always builds a fresh [RouteFollower].** The follower
///    cannot recover from a large divergence on its own (a fix more than
///    200 m off the line is treated as a spike and frozen out, by design),
///    so continuing to feed the old follower after the user has taken a
///    different road would leave progress stuck for the rest of the trip.
///  - **A failed replan is not an error.** Out of tile coverage is a normal
///    state for an offline router; the runtime keeps following the route it
///    has, flags itself [NavFields.degraded] so the notification can say so,
///    and tries again no more than once per [kReplanRetryInterval].
///  - **A loop is never replanned at all.** See [isLoop].
class NavigationRuntime {
  final Future<RouteResult?> Function(double lat, double lon) _requestRoute;
  final DateTime Function() _now;

  /// The route being followed is a closed loop (M3 « Distance » / « Durée »
  /// without a pinned destination — see `ActiveRoute.isLoop`), and must
  /// therefore never be recalculated.
  ///
  /// Final review item 1: a loop has no destination distinct from its start,
  /// so the only thing a replan can route to is the start itself. Doing that
  /// replaces the walker's 10 km loop with the shortest way home, and the
  /// fresh follower — already standing at its own last shape point — latches
  /// arrival immediately, ending the trip on the first wrong turn.
  ///
  /// Skipping the recalculation is not a degraded state and not a failure:
  /// off-route is still published exactly as before (so the walker is told,
  /// once, with the « rejoignez la boucle » phrasing — see `alertText`), but
  /// [NavFields.replanning] stays false, [NavFields.degraded] stays false,
  /// and no router call is ever made.
  final bool isLoop;

  RouteFollower _follower;
  String _routeShapeEnc;
  int _replanCount = 0;
  bool _inFlight = false;
  bool _degraded = false;
  NavUpdate? _lastUpdate;

  /// When the last *failed* replan was attempted, and null whenever the
  /// runtime is not in a failed state. Successes are not throttled: the
  /// follower's own off-route grace already puts a floor of several seconds
  /// between two legitimate recalculations, and a walker taking two wrong
  /// turns in a row deserves the second route as promptly as the first.
  DateTime? _lastFailureAt;

  NavigationRuntime({
    required RouteFollower follower,
    required Future<RouteResult?> Function(double lat, double lon) replan,
    DateTime Function()? now,
    this.isLoop = false,
  })  : _follower = follower,
        _requestRoute = replan,
        _now = now ?? DateTime.now,
        _routeShapeEnc = encodePolyline6(follower.route.shape);

  /// The route being followed right now — the planned one until the first
  /// successful replan, each replacement after that.
  RouteResult get route => _follower.route;

  int get replanCount => _replanCount;

  /// The raw follower update behind the last [NavFields] this runtime
  /// produced. [NavFields] deliberately drops `maneuverIndex` — it crosses an
  /// isolate boundary into the persisted snapshot, and the UI has no use for
  /// which maneuver a distance belongs to, only the distance itself.
  /// `AlertPolicy` needs the index too (to tell "still approaching the same
  /// maneuver" from "a new one"), so the tracking handler reads it from here
  /// rather than from the snapshot. Null before the first [onFix].
  NavUpdate? get lastUpdate => _lastUpdate;

  /// Consumes one accepted GPS fix and returns the navigation state to
  /// publish for it.
  ///
  /// [speedMps] is the device's own instantaneous ground speed. It is
  /// accepted (the service has it, and the interface is fixed) but not fed
  /// to the follower: the ETA is derived from an EMA of *along-route*
  /// progress, which a reported speed — lateral movement, standing still
  /// with GPS noise, and all — would corrupt.
  ///
  /// Completes only once any replan it started has finished, so the fields
  /// returned already describe the new route.
  ///
  /// Calling this again while a replan is in flight is safe — the second
  /// call is answered from the route still being followed and starts no
  /// second recalculation — but that is a property of this class, not a
  /// description of production: the service serializes fixes and simply
  /// drops the ones that arrive mid-replan (see `TripTaskHandler._onNavFix`).
  Future<NavFields> onFix(
      double lat, double lon, double speedMps, DateTime time) async {
    var update = _follower.update(lat, lon, time);
    var replanning = false;

    if (!update.offRoute) {
      // Back on the line: whatever went wrong last time is no longer the
      // user's problem, and a fresh departure deserves an immediate attempt.
      _degraded = false;
      _lastFailureAt = null;
    } else if (_inFlight) {
      // Another (concurrent) onFix call's replan hasn't resolved yet —
      // production serializes fixes so this is only ever exercised as a
      // property of this class (see the class doc comment), but a replan
      // genuinely is in flight, so this tick is "replanning" too.
      replanning = true;
    } else if (_shouldReplan(update)) {
      // Latched *before* awaiting the recalculation: a successful replan
      // below replaces `update` with the new follower's on-route reading,
      // which would otherwise erase every trace of this tick ever having
      // been off-route (see [NavFields.replanning]'s doc comment).
      replanning = true;
      update = await _recalculate(lat, lon, time) ?? update;
    }

    _lastUpdate = update;
    return _fieldsFrom(update, replanning: replanning);
  }

  bool _shouldReplan(NavUpdate update) {
    if (_inFlight) return false;
    // A loop has nowhere to route to but its own start — see [isLoop].
    if (isLoop) return false;
    // An arrived trip has nowhere left to route to: wandering off the line
    // after reaching the destination is not a wrong turn, and the arrival
    // latch means this would otherwise repeat for the rest of the trip.
    if (update.arrived) return false;
    final failedAt = _lastFailureAt;
    return failedAt == null ||
        _now().difference(failedAt) >= kReplanRetryInterval;
  }

  /// Runs one recalculation from the current fix, returning a [NavUpdate]
  /// read off the new follower, or null when nothing usable came back.
  Future<NavUpdate?> _recalculate(double lat, double lon, DateTime time) async {
    _inFlight = true;
    try {
      final route = await _requestRoute(lat, lon);
      if (route == null || route.shape.length < 2) {
        _fail();
        return null;
      }
      _adopt(route);
      _degraded = false;
      _lastFailureAt = null;
      _replanCount++;
      return _follower.update(lat, lon, time);
      // A routing engine that is missing, wedged or out of coverage must
      // never take a recording trip down with it.
    } catch (_) {
      _fail();
      return null;
    } finally {
      _inFlight = false;
    }
  }

  void _fail() {
    _degraded = true;
    _lastFailureAt = _now();
  }

  void _adopt(RouteResult route) {
    _follower = RouteFollower(
      route,
      offRouteThresholdM: _follower.offRouteThresholdM,
      offRouteGrace: _follower.offRouteGrace,
      arrivalRadiusM: _follower.arrivalRadiusM,
      // The pace estimate is a property of the walker, not of the route:
      // handing the estimator over keeps the ETA alive across a replan
      // instead of blanking it for the next three fixes.
      speed: _follower.speed,
    );
    _routeShapeEnc = encodePolyline6(route.shape);
  }

  NavFields _fieldsFrom(NavUpdate u, {bool replanning = false}) => NavFields(
        instruction: u.instruction,
        distanceToManeuverM: u.distanceToManeuverM,
        remainingKm: u.remainingKm,
        etaSeconds: u.eta?.inSeconds,
        offRoute: u.offRoute,
        arrived: u.arrived,
        replanCount: _replanCount,
        routeShapeEnc: _routeShapeEnc,
        degraded: _degraded,
        replanning: replanning,
      );
}
