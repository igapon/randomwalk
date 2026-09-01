/// One navigation tick, in the exact shape the tracking snapshot carries it.
///
/// Produced by [NavigationRuntime.onFix] inside the foreground service, and
/// folded into the [TripSnapshot] the UI reads (live, or off disk in a
/// process that has never seen the trip). Deliberately a plain value with no
/// behaviour beyond formatting: it crosses an isolate boundary as JSON, and
/// the objects it is derived from ([RouteFollower], the routing engine) do
/// not exist on the reading side.
///
/// Every field is optional or defaulted, because a trip that is not
/// route-bound produces none of them and its snapshot must stay exactly what
/// it was before navigation existed.
class NavFields {
  /// The instruction for the maneuver being approached, e.g. « Tournez à
  /// gauche sur la rue de Bourg ».
  final String? instruction;
  final double? distanceToManeuverM;
  final double? remainingKm;
  final int? etaSeconds;
  final bool offRoute;
  final bool arrived;

  /// True on the tick a replan is attempted (successful or not) and while
  /// one is in flight — a transient, unlike [offRoute], which a
  /// *successful* same-tick replan already clears back to false before
  /// this [NavFields] is even built (`NavigationRuntime.onFix` replaces the
  /// off-route update with the new follower's on-route one). Without this,
  /// the off-route alert and the « Recalcul… » card (both keyed on
  /// [offRoute]) would only ever fire when a replan *fails* — a successful
  /// recalculation happens too fast for either to ever see the moment the
  /// walker actually left the route. Callers key those two off
  /// `offRoute || replanning` instead of [offRoute] alone.
  final bool replanning;

  /// How many times the route has been recomputed since the trip started.
  /// Persisted so a UI attaching mid-trip can tell that the line it is
  /// drawing is not the one the user originally planned.
  final int replanCount;

  /// Polyline6 of the route *currently* being followed — the planned one
  /// until the first replan, and each replacement after that. Carried in the
  /// snapshot so the map can redraw the line the notification is describing
  /// without asking the service for it.
  final String? routeShapeEnc;

  /// The last replan failed (no tiles for where the walker now is, or no
  /// routing engine in this isolate) and the runtime is still following a
  /// route the walker has left. The one field here that is *not* persisted:
  /// it phrases a notification, and a UI rebuilding a trip from disk has
  /// [offRoute] and [replanCount] to work from.
  final bool degraded;

  /// Whether the [RouteFollower] behind this tick has latched having
  /// genuinely left the destination's vicinity at least once (see
  /// `RouteFollower.leftArrivalRadius`'s doc comment) — persisted (via
  /// `TripSnapshot.navLeftArrivalRadius`) so a service restart can seed a
  /// fresh follower with it instead of every restart resetting the latch and
  /// permanently blocking arrival for a trip that had already earned it
  /// (final review item 2).
  final bool leftArrivalRadius;

  const NavFields({
    this.instruction,
    this.distanceToManeuverM,
    this.remainingKm,
    this.etaSeconds,
    this.offRoute = false,
    this.arrived = false,
    this.replanCount = 0,
    this.routeShapeEnc,
    this.degraded = false,
    this.replanning = false,
    this.leftArrivalRadius = false,
  });
}

/// The foreground-service notification for a route-bound trip.
///
/// Minimal by design: Task 7 owns the polished formatter (`guidance_text`)
/// that the on-screen guidance banner and this notification will eventually
/// share. Two lines — what to do next, then what is left of the trip —
/// because that is what a glance at a locked screen has room for.
///
/// French formatting throughout: decimal comma, thin separator « · ».
String navNotificationText(NavFields f) {
  final lines = <String>[_headline(f)];
  final remaining = _remainingLine(f);
  if (remaining != null) lines.add(remaining);
  return lines.join('\n');
}

String _headline(NavFields f) {
  // Arrival outranks everything, including a lost route: a walker standing at
  // their destination does not need to be told to go back to the line.
  if (f.arrived) return 'Arrivé à destination';
  if (f.degraded) return 'Itinéraire perdu — revenez sur le tracé';
  final instruction = (f.instruction == null || f.instruction!.isEmpty)
      ? "Suivez l'itinéraire"
      : '↰ ${f.instruction}';
  final distance = f.distanceToManeuverM;
  return distance == null
      ? instruction
      : '$instruction · ${formatDistance(distance)}';
}

String? _remainingLine(NavFields f) {
  final remainingKm = f.remainingKm;
  if (remainingKm == null) return null;
  final km = remainingKm.toStringAsFixed(1).replaceAll('.', ',');
  final eta = f.etaSeconds;
  // No ETA rather than a made-up one: the estimator withholds a figure until
  // it has seen enough movement to mean anything (see `SpeedEstimator`).
  return eta == null ? '$km km' : '$km km · ${(eta / 60).round()} min';
}

/// Distance to the next maneuver, rounded to something a walker can act on:
/// 10 m steps while the turn is close, 50 m steps beyond 100 m, kilometres
/// past 1 km. Announcing « 137 m » implies a precision GPS does not have.
String formatDistance(double meters) {
  if (meters >= 1000) {
    return '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
  }
  final step = meters < 100 ? 10 : 50;
  return '${(meters / step).round() * step} m';
}
