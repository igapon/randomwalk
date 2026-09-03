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
/// `GameState.revealedCellKeys` gains new cells; this function never
/// inspects cell sets itself).
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

/// Single-flight, latest-wins coalescing around a slow, single-key-input
/// async operation — e.g. a `compute()`-backed fog regeneration that can
/// take hundreds of ms on a realistic revealed-cell history (see
/// `fog_geometry_test.dart`'s adversarial perf tests).
///
/// Task 2l review fix round 1: without this, [shouldRegenFog]'s own
/// "never generated yet -> always regenerate" rule can only ever see the
/// last *completed* generation, never one still in flight — so every
/// trigger that fires WHILE the very first (never-yet-completed) fog build
/// is still running independently re-passes that rule and spawns its own,
/// fully redundant `compute()` isolate for what is very often the exact
/// same input. `GameLayer`'s `onCameraIdle` (initial camera settle),
/// `ref.listen<GameState>`, `ref.listen<PoiStore>`, and `_installGameLayer`
/// itself can all fire within the same ~200-750ms window a heavy first
/// build takes. This class is the fix: at most ONE [regen] call is ever in
/// flight; every request arriving while one is running either coalesces to
/// nothing (its `version` matches whatever is already in flight or already
/// queued — nothing has actually changed) or overwrites a single pending
/// slot (latest-wins) — never queues, never grows unbounded. Exactly one
/// follow-up [regen] call runs once the in-flight one completes, and only
/// if something genuinely different is still pending at that point.
///
/// Deliberately generic and free of any MapLibre/Flutter dependency — [P]
/// is whatever payload [regen] actually needs (a `Set<CellId>` for
/// `GameLayer`'s use), [C] is whatever "target" it runs against (a
/// `MapLibreMapController`) — so this is fully unit-testable with a plain,
/// `Completer`-gated fake [regen] and no native map involved at all (see
/// `fog_regen_test.dart`).
class SingleFlightCoalescer<P, C> {
  SingleFlightCoalescer({required this.regen});

  /// The actual (slow) work. Exactly one call is ever in flight — see the
  /// class doc comment.
  final Future<void> Function(P payload, int version, C target) regen;

  bool _inFlight = false;
  int? _inFlightVersion;
  P? _pendingPayload;
  int? _pendingVersion;
  C? _pendingTarget;

  /// True while a [regen] call is in flight (including any chained
  /// follow-up — see the class doc comment).
  bool get isInFlight => _inFlight;

  /// How many times [regen] has actually run — the direct, test-observable
  /// evidence of coalescing (or its absence): N requests during one
  /// in-flight call collapse to exactly 1 (all identical) or 2 (at least
  /// one genuinely different), never N.
  int get regenCallCount => _regenCallCount;
  int _regenCallCount = 0;

  /// Requests a regeneration for [payload], tagged with [version] (a
  /// cheap, comparable stand-in for "did the input actually change" —
  /// `GameLayer` uses `revealedCellKeys.length`). Runs immediately if
  /// nothing is in flight; otherwise coalesces per the class doc comment.
  /// The returned future settles once whatever work THIS request actually
  /// caused has fully landed — immediately, for a request that coalesced
  /// to a no-op.
  Future<void> request(P payload, int version, C target) async {
    if (_inFlight) {
      if (version != (_pendingVersion ?? _inFlightVersion)) {
        _pendingPayload = payload;
        _pendingVersion = version;
        _pendingTarget = target;
      }
      return;
    }
    await _run(payload, version, target);
  }

  Future<void> _run(P payload, int version, C target) async {
    _inFlight = true;
    _inFlightVersion = version;
    _regenCallCount++;
    try {
      await regen(payload, version, target);
    } catch (_) {
      // A failing regen must not wedge future requests — best-effort,
      // same contract every caller's own regen closure already follows.
    } finally {
      _inFlight = false;
      _inFlightVersion = null;
    }

    final pendingPayload = _pendingPayload;
    final pendingVersion = _pendingVersion;
    final pendingTarget = _pendingTarget;
    _pendingPayload = null;
    _pendingVersion = null;
    _pendingTarget = null;
    // The `pendingVersion != version` re-check matters for a "reverted
    // back to what was already in flight" sequence (in flight v5 -> a
    // request for v6 gets queued -> a later request for v5 again
    // overwrites the pending slot back to v5): by the time v5 finishes,
    // the just-completed regen already reflects the pending request's own
    // target state, so chasing it again would be pure waste.
    if (pendingPayload != null &&
        pendingTarget != null &&
        pendingVersion != version) {
      await _run(pendingPayload, pendingVersion!, pendingTarget);
    }
  }
}
