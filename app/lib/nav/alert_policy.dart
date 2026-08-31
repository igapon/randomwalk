import '../valhalla/models.dart';
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
  bool shouldAlert(NavUpdate u) {
    if (u.arrived) {
      final isNew = !_wasArrived;
      _wasArrived = true;
      return isNew;
    }
    // Arrived is expected to latch permanently once RouteFollower sets it,
    // but the policy stays correct even if a caller feeds it a
    // resurrected-false update.
    _wasArrived = false;

    if (u.offRoute) {
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
}

/// The text an alert carries — spoken aloud and/or shown in the guidance
/// notification, depending on which of « Guidage vocal »/« Vibrations et
/// alertes » are on. Arrival and off-route each have their own fixed
/// phrasing; an ordinary maneuver alert reads the instruction itself.
String alertText(NavUpdate u) {
  if (u.arrived) return 'Arrivé !';
  if (u.offRoute) return "Écart d'itinéraire — recalcul";
  return u.instruction.isEmpty ? "Suivez l'itinéraire" : u.instruction;
}
