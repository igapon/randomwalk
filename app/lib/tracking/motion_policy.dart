/// Low-power mode (M5 Task 2d, owner brief): "si le téléphone ne bouge pas,
/// mets en pause le GPS". A trip whose walker has been genuinely stationary
/// for a while gains nothing from a GPS fix every couple of seconds — this
/// is the pure decision layer that says when to stop asking for them, and
/// when to start again.
library;

/// What a caller must do in response to a [MotionPolicy] transition.
enum MotionAction {
  /// Nothing to do.
  none,

  /// Sustained stillness has crossed the threshold — stop the continuous
  /// GPS stream (keep the service and its notification alive).
  pause,

  /// Movement was detected — reopen the GPS stream immediately.
  resume,

  /// Still paused, and [MotionPolicy.safetyFixInterval] has elapsed since
  /// the last one — take one isolated GPS fix as a guard against a missed
  /// resume signal (a dropped native transition broadcast, in particular).
  takeSafetyFix,
}

/// Movement threshold for [GpsStillnessTracker] — a GPS fix farther than
/// this from the anchor established at the start of the current still spell
/// reads as movement. Loose enough to absorb ordinary GPS jitter while
/// genuinely stationary (a parked phone can easily drift several metres
/// between fixes on nothing but noise) without being loose enough to miss an
/// actual walk-off.
const kMotionMovementThresholdM = 15.0;

/// Sustained-stillness threshold for a free (or not-yet-guided) trip —
/// pinned by the owner brief: "pause seulement après immobilité soutenue
/// ≥ 3 min (un feu rouge ne doit JAMAIS suspendre)".
const kMotionStillThreshold = Duration(minutes: 3);

/// Sustained-stillness threshold while [MotionPolicy.navGuided] is true —
/// pinned: "en navigation guidée active, seuil doublé (6 min)". Turn-by-turn
/// guidance means more legitimate stationary pauses (reading an instruction,
/// waiting to cross at a junction with a longer light), so the same 3
/// minutes that is generous for a free walk is trigger-happy here.
const kMotionNavGuidedStillThreshold = Duration(minutes: 6);

/// How often a safety fix is taken while paused — pinned: "un fix de
/// sécurité isolé toutes les 3 min (garde-fou contre un STILL-exit raté)".
const kMotionSafetyFixInterval = Duration(minutes: 3);

/// Turn-by-turn state machine behind low-power mode: still/active, and
/// paused/not.
///
/// **Fix round 1, I5**: [_clock] is the *sole* time authority for every
/// threshold computation this class makes. Earlier this class took an
/// explicit `DateTime` on every call instead, trusting whatever timestamp
/// each caller happened to have to hand — a GPS fix's own `sample.time` for
/// [stillEntered]/[stillExited], the foreground-task framework's own
/// `timestamp` for [tick]. Those are two different clocks (the device
/// location provider's vs. the system's), and comparing a provider-supplied
/// instant against a system-supplied one in the same subtraction can shorten
/// the pinned 3/6 minute window under nothing more exotic than ordinary
/// clock skew — silently breaking the brief's absolute "un feu rouge ne doit
/// JAMAIS suspendre" pin. Reading [_clock] internally, on every signal, at
/// the moment this class actually processes it, makes that skew structurally
/// impossible: whatever timestamp a fix or a native event carries is used
/// for everything *except* deciding how long the walker has been still.
/// Defaults to `DateTime.now` in production; tests inject a controllable
/// one, same pattern as `AdaptiveGpsRateLimiter`/`ThrottledSnapshotWriter`.
class MotionPolicy {
  final Duration stillThreshold;
  final Duration navGuidedStillThreshold;
  final Duration safetyFixInterval;
  final DateTime Function() _clock;

  /// Whether this trip is under active turn-by-turn guidance right now —
  /// doubles [stillThreshold] to [navGuidedStillThreshold] (brief: "en
  /// navigation guidée active, seuil doublé"). Set once by the caller
  /// (`TripTaskHandler` sets it from whether a `NavigationRuntime` exists),
  /// not toggled per-fix.
  bool navGuided;

  DateTime? _stillSince;
  bool _paused = false;
  DateTime? _nextSafetyFixAt;

  MotionPolicy({
    this.stillThreshold = kMotionStillThreshold,
    this.navGuidedStillThreshold = kMotionNavGuidedStillThreshold,
    this.safetyFixInterval = kMotionSafetyFixInterval,
    this.navGuided = false,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The single, authoritative "now" this policy has ever used for a
  /// threshold — see the class doc comment's I5 account. `_reconcileStream`
  /// (`tracking_service.dart`) reads this for its own bookkeeping (e.g.
  /// resetting the GPS-silence clock on resume) rather than a second,
  /// separately-sourced `DateTime.now()`, for the same reason.
  DateTime get now => _clock();

  bool get isPaused => _paused;

  /// Exposed for tests: whether a sustained-stillness timer is currently
  /// running (started, not yet cancelled by movement, not yet crossed the
  /// threshold into [isPaused]).
  bool get isStillTimerRunning => _stillSince != null;

  Duration get _threshold =>
      navGuided ? navGuidedStillThreshold : stillThreshold;

  /// A still signal — native STILL-enter, or [GpsStillnessTracker] reading
  /// "no movement" against its anchor. Idempotent: a second call while the
  /// timer is already running does not push its start time later, which is
  /// what lets a walker who is *already* past the still threshold but kept
  /// producing "still" fixes stay paused rather than having the countdown
  /// perpetually restart.
  ///
  /// A no-op while already [isPaused] — pausing again would gain nothing,
  /// and must never disturb [_nextSafetyFixAt]'s schedule.
  MotionAction stillEntered() {
    if (!_paused) _stillSince ??= _clock();
    return MotionAction.none;
  }

  /// A moving signal — native STILL-exit, a step-counter delta (fallback),
  /// or [GpsStillnessTracker] reading genuine movement against its anchor
  /// (including a safety fix's).
  ///
  /// Always cancels a running still timer (brief: a red light under the
  /// threshold must never have paused in the first place — this is what
  /// keeps it from doing so), and, while [isPaused], resumes immediately
  /// (brief: "reprise IMMÉDIATE sur STILL-exit"/"delta de pas en fallback").
  MotionAction stillExited() {
    _stillSince = null;
    if (_paused) {
      _paused = false;
      _nextSafetyFixAt = null;
      return MotionAction.resume;
    }
    return MotionAction.none;
  }

  /// Periodic evaluation — call on every tick of whatever cadence the
  /// caller already runs (`TripTaskHandler.onRepeatEvent`'s 2 s repeat, in
  /// production).
  ///
  /// While active: pauses once the running still timer has been alive for
  /// at least [_threshold] — `>=`, not `>`, so a test walking the clock in
  /// exact-threshold steps observes the pause on the tick that reaches it
  /// rather than one tick later.
  ///
  /// While paused: fires [MotionAction.takeSafetyFix] once
  /// [safetyFixInterval] has elapsed since the pause began (or since the
  /// last safety fix), then reschedules the next one [safetyFixInterval]
  /// after *this* tick — cadenced off of whenever the fix actually happens
  /// to be taken, not off a fixed schedule from the original pause moment,
  /// so a delayed tick does not make every subsequent fix late forever.
  MotionAction tick() {
    final now = _clock();
    if (_paused) {
      final due = _nextSafetyFixAt;
      if (due != null && !now.isBefore(due)) {
        _nextSafetyFixAt = now.add(safetyFixInterval);
        return MotionAction.takeSafetyFix;
      }
      return MotionAction.none;
    }
    final since = _stillSince;
    if (since != null && now.difference(since) >= _threshold) {
      _paused = true;
      _stillSince = null;
      _nextSafetyFixAt = now.add(safetyFixInterval);
      return MotionAction.pause;
    }
    return MotionAction.none;
  }
}

/// Turns GPS fixes into [MotionPolicy.stillEntered]/[MotionPolicy.stillExited]
/// calls by comparing each one against a rolling anchor position — two
/// distinct roles, both the same anchor+threshold comparison:
///
///  - the step/GPS **fallback**, used for every accepted fix while
///    recording when the native Activity Recognition Transition API is
///    unavailable (`MotionChannel.start()` returned false): this is the
///    *sole* still/moving signal source in that mode, standing in for the
///    native transition events end to end (brief §1's fallback: "pas de
///    déplacement GPS > seuil pendant la fenêtre = immobile" — the "fenêtre"
///    is [MotionPolicy]'s own sustained-stillness timer, not a separate one
///    here, since re-anchoring on every non-moving fix and letting the
///    policy's timer run is equivalent and needs no second window);
///  - the **safety fix** [MotionPolicy] schedules every [
///    MotionPolicy.safetyFixInterval] while paused, in *either* mode: fed
///    just that one fix, checked against the anchor recorded (via [seed])
///    at the moment the pause began, as a guard against a missed native
///    STILL-exit broadcast.
///
/// Purely spatial — no timestamp involved (fix round 1, I5: [MotionPolicy]
/// itself sources every "now" it needs from its own injected clock, so a
/// fix's own timestamp is no longer threaded through here at all).
class GpsStillnessTracker {
  final MotionPolicy policy;
  final double movementThresholdM;
  final double Function(double lat1, double lon1, double lat2, double lon2)
  distance;

  (double, double)? _anchor;

  GpsStillnessTracker(
    this.policy, {
    required this.distance,
    this.movementThresholdM = kMotionMovementThresholdM,
  });

  /// Resets the anchor to [lat]/[lon] without judging movement — called
  /// when a pause begins, so the first safety fix afterwards has a real
  /// anchor to compare against rather than reading as "moved" purely
  /// because none existed yet.
  void seed(double lat, double lon) => _anchor = (lat, lon);

  /// Feeds one fix (a continuous-stream fix in fallback mode, or a safety
  /// fix in either mode). Returns the [MotionAction] [policy] produced.
  ///
  /// No anchor yet (the very first fix ever fed in) seeds one and reads as
  /// still — not moved — from that fix's own position: if the walker
  /// genuinely stays there, the sustained-stillness timer should count from
  /// this first reading, not wait for a second one to confirm it.
  MotionAction onFix(double lat, double lon) {
    final anchor = _anchor;
    if (anchor == null) {
      _anchor = (lat, lon);
      return policy.stillEntered();
    }
    if (distance(lat, lon, anchor.$1, anchor.$2) > movementThresholdM) {
      _anchor = (lat, lon);
      return policy.stillExited();
    }
    return policy.stillEntered();
  }
}
