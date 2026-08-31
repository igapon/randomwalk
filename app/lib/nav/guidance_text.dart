import 'nav_fields.dart' show formatDistance;

/// The on-screen guidance formatters (Task 7) — distinct from
/// `nav_fields.dart`'s `navNotificationText`, which phrases the same
/// underlying state for a locked-screen notification. The two share the
/// distance-rounding rule ([formatDistance]) so a walker never sees the
/// instruction card say one number and the notification say another for the
/// same fix.

/// « Dans 120 m, tournez à gauche » — a maneuver instruction prefixed with
/// how far it is, rounded the same way [formatDistance] rounds everywhere
/// else in the app (10 m steps under 100 m, 50 m above, kilometres past
/// 1 km). Reused rather than re-implemented so the top instruction card and
/// its accessibility label can never disagree with the guidance
/// notification about what a given distance rounds to.
String formatManeuver(String instruction, double distanceM) =>
    'Dans ${formatDistance(distanceM)}, $instruction';

/// « 2,4 km · ~32 min » — what is left of a route-bound trip. The leading
/// `~` (absent from the notification's own remaining-distance line) makes
/// explicit, on a screen with room for it, that the minutes are an estimate
/// from the walker's recent pace rather than a promise. No ETA — rather than
/// a fabricated one — when [eta] is null: the speed estimator withholds a
/// figure until it has seen enough movement to mean anything.
String formatRemaining(double km, Duration? eta) {
  final kmLabel = km.toStringAsFixed(1).replaceAll('.', ',');
  if (eta == null) return '$kmLabel km';
  final minutes = (eta.inSeconds / 60).round();
  return '$kmLabel km · ~$minutes min';
}

/// Copy shared by the map screen's nav overlay and the session screen's
/// plain trip view, so the two cannot drift on what a mid-trip recalculation
/// or an arrival reads like.
const kNavRecalculatingLabel = 'Recalcul…';
const kNavArrivedLabel = 'Arrivé !';

/// What a walker who has left a **loop** is told instead of « Recalcul… »
/// (final review item 1). A loop is never recalculated — there is nowhere to
/// route to but its own start — so promising a recalculation would be a lie;
/// the honest instruction is to go back to the line. Shared by the spoken/
/// notified alert (`alertText`) and the map's off-route card so the two
/// cannot drift.
const kNavRejoinLoopLabel = "Écart d'itinéraire — rejoignez la boucle";
