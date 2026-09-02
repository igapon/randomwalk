/// Default throttle: the fog GeoJSON is regenerated at most once per this
/// interval, regardless of how often the revealed set changes underneath
/// it. Purely defensive — `fog_geometry.dart`'s builder is already bounded
/// (<50ms indicative for 5k cells; see `fog_geometry_test.dart`) and reveal
/// events are already rate-limited by real walking speed and the reducer's
/// own batching — but a hard floor costs nothing and protects against any
/// future caller that fires revealed-set updates faster than that.
const kFogMinRegenInterval = Duration(seconds: 2);

/// Pure decision function for the fog-of-war layer: whether the fog
/// GeoJSON source should be regenerated *now*, given when it was last
/// regenerated ([lastGen]), the current time ([now]), and a version
/// counter for the revealed-cell set ([lastRevealedVersion] vs
/// [revealedVersion] — the caller bumps this counter every time
/// `RevealState`/`GameState.revealedCellKeys` gains new cells; this
/// function never inspects cell sets itself).
///
/// Rules, in order:
/// 1. Never generated yet ([lastGen] is `null`) → always regenerate (there
///    is nothing on screen otherwise).
/// 2. Less than [minInterval] since the last regen → never regenerate,
///    regardless of what else changed.
/// 3. Otherwise, regenerate iff the revealed set actually changed (version
///    counters differ).
///
/// Task 2h (owner bug report: "fog of war seems patchy and changes when i
/// move the map"): this deliberately has NO notion of a map viewport
/// anymore — the previous version of this function (see git history) also
/// weighed how far the camera had panned/zoomed, because the fog geometry
/// itself used to be generated FOR the current viewport. Now that
/// `fog_geometry.dart`'s `fogWorldGeoJson` builds one world-in-coordinates
/// polygon that is a pure function of the revealed set alone, panning the
/// camera is no longer a reason to regenerate anything — the fog is simply
/// already there, in world coordinates, wherever the camera looks.
bool shouldRegenFog({
  required DateTime? lastGen,
  required DateTime now,
  required int lastRevealedVersion,
  required int revealedVersion,
  Duration minInterval = kFogMinRegenInterval,
}) {
  if (lastGen == null) return true;
  if (now.difference(lastGen) < minInterval) return false;
  return revealedVersion != lastRevealedVersion;
}
