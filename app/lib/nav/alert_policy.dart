import '../valhalla/models.dart';
import 'guidance_text.dart';
import 'route_follower.dart';

/// Distance (metres) to the next maneuver at which a walker gets an alert.
const kWalkAlertThresholdM = 80.0;

/// Distance (metres) to the next maneuver at which a cyclist gets an alert —
/// larger than the walking one because a bike closes the same distance in a
/// fraction of the time.
const kBikeAlertThresholdM = 200.0;

/// Decides when a turn-by-turn tick is worth interrupting the walker for —
/// a vibration, a sound, maybe a spoken instruction — as opposed to the
/// silent, every-fix stream [NavigationRuntime] otherwise produces.
///
/// Three kinds of moment are alert-worthy, in priority order:
///
///  1. **Arrival.** Once, on the tick that first reports [NavUpdate.arrived].
///     Nothing else is worth alerting for afterwards — there is no next
///     maneuver, and a walker standing at their destination does not need a
///     recalculation notice for having wandered off a route they have
///     finished (mirrors [NavigationRuntime]'s own "arrival outranks
///     everything" rule, see `nav_fields.dart`).
///  2. **Leaving the route.** Once, on the tick where [NavUpdate.offRoute]
///     first turns true. Fixes while still off-route repeat nothing; a
///     second, separate excursion (back on the route, then off again) alerts
///     again. While off-route, a maneuver-distance crossing underneath it is
///     suppressed — `distanceToManeuverM` describes a route the walker has
///     just left, and stacking a second alert on top of the recalculation
///     notice would be noise, not information.
///  3. **Approaching a maneuver.** Once per [NavUpdate.maneuverIndex], the
///     first tick its `distanceToManeuverM` is at or under the profile's
///     threshold — [kWalkAlertThresholdM] walking, [kBikeAlertThresholdM] on
///     a bike. Re-armed the moment the index advances to the next maneuver;
///     a fix that wobbles back above threshold for the *same* index never
///     re-triggers it.
///
/// Purely a decision function over the stream of [NavUpdate]s a single trip
/// produces — no timers, no I/O — so the foreground-service handler that
/// owns the actual notification/TTS call is free to be untestable glue
/// around it.
class AlertPolicy {
  final RoutingProfile profile;
  final double _thresholdM;

  bool _wasArrived = false;
  bool _wasOffRoute = false;
  int? _alertedManeuverIndex;

  AlertPolicy({required this.profile})
      : _thresholdM = profile == RoutingProfile.bike
            ? kBikeAlertThresholdM
            : kWalkAlertThresholdM;

  /// Whether [u] is worth alerting the walker for. Stateful — call once per
  /// fix, in order; calling it twice for the same fix double-latches nothing
  /// (idempotent within a tick) but consumes the "once" for real ticks that
  /// never arrive.
  ///
  /// [replanning] is [NavFields.replanning] for this same tick: a
  /// successful same-tick replan already rewrites [u] to the new,
  /// on-route reading before this is ever called, so `u.offRoute` alone
  /// can no longer tell "never left the route" from "left it and was
  /// already routed back" — [replanning] is what still can. Off-route
  /// alerting below reads `u.offRoute || replanning` for exactly that
  /// reason; every other branch keys on [u] alone.
  bool shouldAlert(NavUpdate u, {bool replanning = false}) {
    if (u.arrived) {
      final isNew = !_wasArrived;
      _wasArrived = true;
      return isNew;
    }
    // Arrived is expected to latch permanently once RouteFollower sets it,
    // but the policy stays correct even if a caller feeds it a
    // resurrected-false update.
    _wasArrived = false;

    final offRoute = u.offRoute || replanning;
    if (offRoute) {
      final isNew = !_wasOffRoute;
      _wasOffRoute = true;
      return isNew;
    }
    _wasOffRoute = false;

    if (u.maneuverIndex != _alertedManeuverIndex &&
        u.distanceToManeuverM <= _thresholdM) {
      _alertedManeuverIndex = u.maneuverIndex;
      return true;
    }
    return false;
  }

  /// Clears which maneuver has already been alerted for. Call this whenever
  /// the route being followed changes — a replan always builds a fresh
  /// [RouteFollower] (see `NavigationRuntime`'s own doc comment), which
  /// renumbers maneuvers from its own index 0. Without this, a
  /// `maneuverIndex` that happens to coincide with the one last alerted on
  /// the *previous* route — index 0 is the common case, since a fresh
  /// follower's first published maneuver is almost always 0 — would be
  /// silently treated as already handled, and the new route's early
  /// maneuvers would never alert.
  ///
  /// Off-route/arrived state is deliberately left alone: both are driven
  /// entirely by the update passed to [shouldAlert] and already
  /// self-correct on the very next call regardless of a replan (see the
  /// `_wasOffRoute = false` / `_wasArrived = false` fallthrough above).
  void reset() {
    _alertedManeuverIndex = null;
  }
}

/// The text an alert carries — spoken aloud and/or shown in the guidance
/// notification, depending on which of « Guidage vocal »/« Vibrations et
/// alertes » are on. Arrival and off-route each have their own fixed
/// phrasing; an ordinary maneuver alert reads the instruction itself.
///
/// [replanning] (see [AlertPolicy.shouldAlert]'s doc comment) says this
/// same tick left the route and was already recalculated onto a new one —
/// [u] itself already reads on-route by the time this is called, so
/// without it the walker would hear the *new* route's first instruction
/// with no mention of ever having left the old one.
///
/// [isLoop] (final review item 1) says the route is a closed loop, which
/// `NavigationRuntime` deliberately never recalculates — so the off-route
/// line drops the « recalcul » promise for [kNavRejoinLoopLabel]'s honest
/// « rejoignez la boucle ». Everything else, arrival included, is unchanged.
String alertText(NavUpdate u, {bool replanning = false, bool isLoop = false}) {
  if (u.arrived) return 'Arrivé !';
  if (u.offRoute || replanning) {
    return isLoop ? kNavRejoinLoopLabel : "Écart d'itinéraire — recalcul";
  }
  return u.instruction.isEmpty ? "Suivez l'itinéraire" : u.instruction;
}
