import '../game/grid.dart' show cellSizeM;
import '../nav/polyline_math.dart' show metersBetween;

/// A map viewport's south-west/north-east corners, as `(lat, lon)` pairs —
/// the same shape `fogGeoJson` (reveal.dart) already takes, given its own
/// name here so [shouldRegenFog]'s signature reads clearly.
class FogViewport {
  final (double, double) sw;
  final (double, double) ne;

  const FogViewport(this.sw, this.ne);

  (double, double) get center => ((sw.$1 + ne.$1) / 2, (sw.$2 + ne.$2) / 2);

  @override
  bool operator ==(Object other) =>
      other is FogViewport && other.sw == sw && other.ne == ne;

  @override
  int get hashCode => Object.hash(sw, ne);
}

/// Default throttle: the fog GeoJSON is regenerated at most once per this
/// interval, regardless of how much else changed (Task 6 perf constraint:
/// "reveal GeoJSON régénéré au plus 1×/2 s").
const kFogMinRegenInterval = Duration(seconds: 2);

/// Default move threshold before a viewport change alone justifies a
/// regen — "~1 cell" per the plan (one ~150 m grid cell).
const kFogMoveThresholdM = cellSizeM;

/// Pure decision function for the Aventure map's fog-of-war layer: whether
/// the fog GeoJSON source should be regenerated *now*, given when it was
/// last regenerated ([lastGen]), the current time ([now]), the viewport it
/// was last regenerated for ([lastViewport]) vs. the current one
/// ([viewport]), and a version counter for the revealed-cell set
/// ([lastRevealedVersion] vs [revealedVersion] — the caller bumps this
/// counter every time `RevealState`/`GameState.revealedCellKeys` gains new
/// cells; this function never inspects cell sets itself).
///
/// Rules, in order:
/// 1. Never generated yet ([lastGen] is `null`) → always regenerate (there
///    is nothing on screen otherwise).
/// 2. Less than [minInterval] since the last regen → never regenerate,
///    regardless of what else changed. This is the hard throttle: "au plus
///    1×/2 s" is unconditional, not "at most every 2s unless something big
///    happened".
/// 3. Otherwise, regenerate only if the revealed set changed (version
///    counters differ) or the viewport moved at least [moveThresholdM]
///    meters (its center did) since [lastViewport] — a `null`
///    [lastViewport] at this point (regenerated once before but somehow
///    with no viewport recorded) is treated as "moved", i.e. regenerate.
///    A viewport that panned/zoomed by less than the threshold with an
///    unchanged revealed set produces no regen at all — this is what keeps
///    a lingering map from regenerating every frame for no reason.
bool shouldRegenFog({
  required DateTime? lastGen,
  required DateTime now,
  required FogViewport? lastViewport,
  required FogViewport viewport,
  required int lastRevealedVersion,
  required int revealedVersion,
  Duration minInterval = kFogMinRegenInterval,
  double moveThresholdM = kFogMoveThresholdM,
}) {
  if (lastGen == null) return true;
  if (now.difference(lastGen) < minInterval) return false;
  if (revealedVersion != lastRevealedVersion) return true;
  if (lastViewport == null) return true;

  final movedM = metersBetween(
    lastViewport.center.$1,
    lastViewport.center.$2,
    viewport.center.$1,
    viewport.center.$2,
  );
  return movedM >= moveThresholdM;
}
