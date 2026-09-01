/// Pure state for the map's plan-mode selector (« Itinéraire » / « Distance »
/// / « Durée » — task 6, renamed from « Boucle » per the device-QA brief:
/// a loop is simply the no-destination case of the same distance target).
/// Everything here is Flutter- and async-free (save for [PlanModeStore], a
/// thin `shared_preferences` wrapper mirroring `trip_controller.dart`'s
/// profile persistence): mode transitions, slider clamping/stepping, the
/// duration→distance conversion via `SpeedHistoryStore`, candidate seed
/// stepping and selection, the small per-candidate display helpers the
/// compact selection row reads (gap badge, repeated-segment hint), and the
/// top-overlay/panel visibility rules for the device-QA fullscreen-selection
/// overhaul (task 8).
///
/// The widgets themselves (`map_screen.dart`, `candidate_chips_bar.dart`)
/// hold no planning logic of their own — they call into this file and render
/// whatever it returns, the same split `replan_line.dart` and
/// `nav_camera_state.dart` already use for their own pure decisions.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../loop/loop_planner.dart';
import '../valhalla/models.dart';

/// The planning modes shown by the `SegmentedButton` above the search bar —
/// Task 7 adds [explore] (« Explorer »), a fourth mode biased toward
/// unrevealed ground. Persisted verbatim (`.name`) — see [PlanModeStore].
enum PlanMode {
  itinerary,
  loop,
  duration,

  /// « Explorer » (task 7): loops biased toward the walker's unrevealed
  /// grid cells (`exploration/explore_planner.dart`'s `exploreBearings`,
  /// fed `GameState.revealedCellKeys`). Shares Distance's slider/floor
  /// rules verbatim ([buildLoopRequest] routes it through the exact same
  /// `loopTargetKm` branch as [loop]) — the only behavioral differences are
  /// the bearing bias and that a pinned destination is never honored (see
  /// [buildLoopRequest]'s doc comment and [shouldShowPlanDestinationChip]).
  explore,
}

// ---- Distance (PlanMode.loop): distance target -----------------------------

const double kLoopTargetMinKm = 1.0;
const double kLoopTargetMaxKm = 30.0;
const double kLoopTargetStepKm = 0.5;

/// The slider's starting value: a brisk walk's loop is a lot shorter than a
/// comfortable ride's.
double defaultLoopTargetKm(RoutingProfile profile) =>
    profile == RoutingProfile.walk ? 5.0 : 15.0;

/// Snaps [km] to the nearest [kLoopTargetStepKm] increment and clamps it to
/// `[kLoopTargetMinKm, kLoopTargetMaxKm]` — what the slider's `onChanged` runs
/// every value through before it ever reaches state, so a target that would
/// make [LoopRequest] throw (`<= 0`) can never be constructed here.
double clampLoopTargetKm(double km) {
  final snapped = (km / kLoopTargetStepKm).round() * kLoopTargetStepKm;
  return snapped.clamp(kLoopTargetMinKm, kLoopTargetMaxKm);
}

// ---- Durée: duration target ------------------------------------------------

const Duration kDurationTargetMin = Duration(minutes: 15);
const Duration kDurationTargetMax = Duration(hours: 4);
const Duration kDurationTargetStep = Duration(minutes: 15);
const Duration kDurationTargetDefault = Duration(hours: 1);

/// Snaps [duration] to the nearest [kDurationTargetStep] and clamps it to
/// `[kDurationTargetMin, kDurationTargetMax]`.
Duration clampDurationTarget(Duration duration) {
  final stepMinutes = kDurationTargetStep.inMinutes;
  final snappedMinutes =
      (duration.inMinutes / stepMinutes).round() * stepMinutes;
  final snapped = Duration(minutes: snappedMinutes);
  if (snapped < kDurationTargetMin) return kDurationTargetMin;
  if (snapped > kDurationTargetMax) return kDurationTargetMax;
  return snapped;
}

/// Turns a duration target into a distance target at the walker's own pace.
/// [speedKmh] is threaded in by the caller (`SpeedHistoryStore.speedKmh`)
/// rather than read here — this file stays free of async/IO so it can be
/// tested as plain functions.
///
/// Clamped to `[kLoopTargetMinKm, kLoopTargetMaxKm]` — the same bounds
/// [clampLoopTargetKm] holds the Distance slider to (final review item 4).
/// The two modes plan through the identical [LoopRequest]/`LoopPlanner`
/// pipeline, so a target Distance cannot even express must not reach it from
/// Durée either: 4 h at a 25 km/h cycling pace is 100 km, which the planner would
/// spend its entire router-call budget bisecting toward and never reach,
/// handing back a candidate ~70 % short with no explanation. At the other
/// end, a slow walker's 15 minutes converts to well under a kilometre.
///
/// Always positive as a result — the clamp guarantees it, so a [LoopRequest]
/// built from this can never throw on a non-positive target regardless of
/// what [speedKmh] the history store learned.
double durationToTargetKm(Duration duration, double speedKmh) {
  assert(speedKmh > 0, 'speedKmh must be positive');
  final raw = duration.inSeconds / 3600 * speedKmh;
  return raw.clamp(kLoopTargetMinKm, kLoopTargetMaxKm);
}

/// « ≈ 3,8 km à votre rythme » — French decimal comma, one decimal place.
///
/// Reads « ≈ 30,0 km (maximum) à votre rythme » on a target sitting at a
/// bound (item 4). [durationToTargetKm] clamps, and without saying so the
/// label would look like an ordinary pace conversion while lengthening the
/// duration slider silently stopped changing the distance — the one reading
/// of that screen a walker cannot debug for themselves.
String formatConversionLabel(double km) {
  final formatted = km.toStringAsFixed(1).replaceAll('.', ',');
  final bound = km >= kLoopTargetMaxKm
      ? ' (maximum)'
      : km <= kLoopTargetMinKm
      ? ' (minimum)'
      : '';
  return '≈ $formatted km$bound à votre rythme';
}

// ---- Candidate seed stepping -----------------------------------------------

/// Starting seed for a fresh plan. Not a fixed constant — that would make
/// every walker's very first « Proposer » of a session probe the exact same
/// three bearings — but still perfectly reproducible for a given [now]
/// (tests pass a fixed clock).
int initialSeed(DateTime now) => now.millisecondsSinceEpoch ~/ 1000;

/// « Autres propositions »: same request, next candidate set. See
/// [LoopRequest.seed]'s doc comment — sub-seeds are spaced by
/// `LoopPlanner.candidateCount` internally, so consecutive seeds never repeat
/// a candidate.
int nextSeed(int seed) => seed + 1;

// ---- Request building -------------------------------------------------------

/// Builds the [LoopRequest] for the current mode, or `null` for
/// [PlanMode.itinerary] (which never plans a loop — the existing A→B flow
/// owns that entirely). [destination] is the long-press/search pin, if any:
/// its presence is what switches the request from a closed loop to a
/// fixed-target A→B ([PlanKind.toDestination]) — task-8 brief point 3 makes
/// this true for **both** [PlanMode.loop] and [PlanMode.duration], not just
/// Durée: a distance-mode walker who also drops a pin wants that distance
/// spent getting *there*, the same way a duration-mode one already could. A
/// loop (no pin) is simply the other case of the same target.
///
/// [targetKm] is asserted positive rather than left for [LoopRequest]'s own
/// `ArgumentError` to catch: the slider/duration clamps above already
/// guarantee it, and an assertion here catches a caller that bypasses them
/// before the request ever reaches the planner.
///
/// [preferredBearingsDeg] and [explorationBonus] pass straight through to
/// the identically-named [LoopRequest] fields — task 7's caller
/// (`map_screen.dart`'s `_proposeCandidates`) only ever supplies them for
/// [PlanMode.explore], having computed them itself from `exploreBearings`
/// and `GameState.revealedCellKeys`; every other mode leaves them `null`,
/// which is exactly what made every pre-task-7 call site (and every
/// pre-task-7 test) keep working unchanged.
///
/// **Explorer never honours a pinned destination.** A walker in Explorer
/// mode wants a loop biased toward the unknown, not a fixed-target A→B
/// through whatever pin happens to still be set (possibly left over from
/// another mode) — see [shouldShowPlanDestinationChip], which hides the chip
/// that would otherwise show/clear that pin for exactly this mode. [mode]
/// `== `[PlanMode.explore] therefore always builds a [PlanKind.loop] request
/// regardless of [destination]; [PlanMode.loop] and [PlanMode.duration] keep
/// the existing task-8 behavior of honouring it.
LoopRequest? buildLoopRequest({
  required PlanMode mode,
  required double loopTargetKm,
  required Duration durationTarget,
  required double speedKmh,
  required RoutingProfile profile,
  required (double, double) start,
  (double, double)? destination,
  required int seed,
  List<double>? preferredBearingsDeg,
  double Function(RouteResult route)? explorationBonus,
}) {
  if (mode == PlanMode.itinerary) return null;

  // Explorer shares Distance's slider/target — both read loopTargetKm
  // verbatim; only Durée converts its own duration slider into a distance.
  final targetKm = mode == PlanMode.duration
      ? durationToTargetKm(durationTarget, speedKmh)
      : loopTargetKm;
  assert(targetKm > 0, 'targetKm must be positive');

  final honoursDestination = mode != PlanMode.explore && destination != null;
  final kind = honoursDestination ? PlanKind.toDestination : PlanKind.loop;

  return LoopRequest(
    kind: kind,
    start: start,
    end: kind == PlanKind.toDestination ? destination : null,
    targetKm: targetKm,
    profile: profile,
    seed: seed,
    preferredBearingsDeg: preferredBearingsDeg,
    explorationBonus: explorationBonus,
  );
}

/// Distance-mode slider floor for a pinned destination — fix-round-1, point
/// 3: a target *below* the direct start→destination distance builds a
/// [PlanKind.toDestination] request with a non-positive detour budget (see
/// `LoopPlanner._surplusM`), so the planner has nothing to pad the route
/// with — it hands back the direct route itself as the only candidate,
/// badged a wildly off-target `+140 %`-style gap, with "Autres propositions"
/// a deterministic no-op on the same seed-less direct geometry (see
/// [shouldHideOtherProposals], which hides it for exactly this case).
///
/// Returns the loop-slider target [_proposeCandidates] should seed before
/// building the request: [directKm] itself, rounded *up* to the nearest
/// [kLoopTargetStepKm] and clamped to the slider's bounds, whenever
/// [currentTargetKm] sits below it — [currentTargetKm] unchanged otherwise
/// (already enough budget for a real detour). `null` when [directKm] itself
/// exceeds [kLoopTargetMaxKm]: no slider position can express a target that
/// far, so the caller shows "Destination trop éloignée pour ce mode" and
/// skips planning entirely rather than seeding a value the slider could
/// never actually reach.
double? loopTargetFloorForDestination({
  required double directKm,
  required double currentTargetKm,
}) {
  if (directKm > kLoopTargetMaxKm) return null;
  if (directKm <= currentTargetKm) return currentTargetKm;
  final stepped = (directKm / kLoopTargetStepKm).ceil() * kLoopTargetStepKm;
  return stepped.clamp(kLoopTargetMinKm, kLoopTargetMaxKm);
}

/// « Destination trop éloignée pour ce mode » — shown instead of planning
/// when [loopTargetFloorForDestination] returns `null` (fix-round-1, point
/// 3).
const kDestinationTooFarMessage = 'Destination trop éloignée pour ce mode';

// ---- Destination pinning across mode switches -------------------------------

/// Fix-round-1 finding: a destination pinned while in [PlanMode.itinerary]
/// (long-press/search) that never turned into a route — a failed plan, or
/// simply one still in flight — used to survive a switch into Distance/Durée
/// invisibly, silently turning Durée's next « Proposer » into a
/// fixed-duration A→B against a pin the walker never chose for that mode,
/// with no control on screen to see or clear it.
///
/// Final review item 7 makes the rule symmetric: **any** mode change with no
/// route on screen drops an un-routed destination. The original rule only
/// covered Itinéraire→(Distance|Durée), which left the mirror image of the same
/// bug — a pin set in Durée and carried into Itinéraire, where the Durée
/// destination chip that could clear it is no longer on screen and no result
/// banner exists either, so the next long-press or « Planifier » plans
/// against a target the walker can neither see nor cancel. A destination
/// belongs to the panel it was set in; switching panels orphans it.
///
/// Two things the rule deliberately still protects:
///
///  * `hasRoute` — a computed route *is* visible, with the result banner's
///    own ✕ to clear it. This must not race or duplicate that.
///  * `from == to` — a no-op switch clears nothing, so the rule does not
///    depend on `_onPlanModeChanged`'s early return to avoid dropping a pin
///    the user just set in the mode they are already in.
bool shouldClearDestinationOnModeSwitch({
  required PlanMode from,
  required PlanMode to,
  required bool hasRoute,
}) => from != to && !hasRoute;

/// Coordinate fallback label for a pinned destination the UI has no
/// reverse-geocoded name for (a long-press pin, or a search result whose
/// label wasn't kept past selection) — four decimals is ~11 m of precision,
/// plenty for an "is this the pin I meant" glance at the Durée chip.
String formatDestinationLabel((double, double) point) {
  final (lat, lon) = point;
  return '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}';
}

/// Whether the clearable destination chip should be shown in the plan-target
/// panel — task-8 brief point 3: a pinned destination is honoured (and must
/// stay visible/clearable) in **both** [PlanMode.loop] and
/// [PlanMode.duration], not only Durée. [PlanMode.itinerary] has its own
/// result banner/✕ for a routed destination and never reaches this panel at
/// all, but the check is still explicit here rather than assumed by the
/// caller, so the rule is the same single tested fact
/// [shouldClearDestinationOnModeSwitch] already is.
///
/// [PlanMode.explore] (task 7) is the one further exception: Explorer never
/// honours a pin (see [buildLoopRequest]'s doc comment), so showing a
/// chip — implying the pin is in effect and offering to clear something
/// that was never being used — would just be confusing.
bool shouldShowPlanDestinationChip({
  required PlanMode mode,
  required bool hasDestination,
}) =>
    mode != PlanMode.itinerary &&
    mode != PlanMode.explore &&
    hasDestination;

// ---- Fullscreen candidate selection (task 8) --------------------------------

/// Task-8 brief point 1: the instant there are candidates to choose from, the
/// mode selector, search bar, profile picker and plan-target panel all step
/// aside for a fullscreen map with only the compact selection row at the
/// bottom — the owner's own words were "cache les menus... pour mieux voir
/// la carte". A single tested fact rather than a scattered `if` in `build()`.
bool shouldShowPlanningTopOverlay({required bool hasCandidates}) =>
    !hasCandidates;

/// Fix-round-1, point 1: `MapScreen` stays mounted behind an `IndexedStack`
/// tab switch, so a walker can propose loop/duration candidates, flip to the
/// Session tab and start a *free* trip there, then come back to the Map tab
/// with a recording already running — while the stale candidates (and their
/// preview polylines) are still sitting on screen with no ✕ reachable to
/// dismiss them until the trip ends (the compact row that owns that ✕ only
/// shows when [shouldShowCandidateChips] says so, and a recording always
/// wins that check). A recording session takes priority: this is the signal
/// `map_screen.dart`'s `build()` uses to clear them itself, the same way
/// `_clearCandidates` (the ✕ handler) already would.
bool shouldClearCandidatesForRecording({
  required bool isRecording,
  required bool hasCandidates,
}) => isRecording && hasCandidates;

/// The single flag both the compact candidate row (`bottomBanner`) and the
/// top overlay's "hide everything" branch key off — fix-round-1, point 1:
/// keeps the two in lockstep so a recording trip can never show one without
/// the other (a `StatsBanner` with a blank top, or the fullscreen selection
/// UI with the recording pill nowhere to be seen). `hasCandidates` alone,
/// without the `!isRecording` guard, is exactly the bug this replaces.
bool shouldShowCandidateChips({
  required bool hasCandidates,
  required bool isRecording,
}) => hasCandidates && !isRecording;

/// Fix-round-2: the companion to [shouldClearCandidatesForRecording] for the
/// other half of the same window — a `_proposeCandidates` request still
/// *in flight* (`candidatePlanning` true, before `_candidateResult` itself
/// exists) when a recording starts elsewhere (Session tab, `MapScreen` still
/// mounted). Left uncancelled, that request can still land afterwards and
/// resurrect exactly the stale-candidates bug
/// [shouldClearCandidatesForRecording] fixes — one frame late, and via a
/// route that check alone cannot see (`hasCandidates` is still false while
/// planning). `map_screen.dart`'s `build()` cancels it (bumping the
/// generation via `_cancelCandidatePlanning`) the instant this is true.
bool shouldCancelCandidatePlanningForRecording({
  required bool isRecording,
  required bool candidatePlanning,
}) => isRecording && candidatePlanning;

/// Fix-round-2: whether Android back should be intercepted to leave
/// candidate selection (`PopScope.canPop == false`) rather than popping the
/// route or exiting the app. Recording-aware, unlike a raw check of
/// `hasCandidates`/`candidatePlanning` alone: a recording that starts while
/// candidates are shown, or a proposal is still in flight, must not leave
/// back silently swallowed by a plan the walker can no longer see behind the
/// recording pill (the gap the fix-round-1 re-review found — `canPop` used
/// to read those two flags raw, one frame ahead of the post-frame effects
/// above that actually clear/cancel them). True the instant a recording
/// starts, in the very same frame [shouldShowCandidateChips] already stops
/// showing the chip row in — not deferred to the next frame the way the
/// post-frame cleanup above necessarily is.
bool shouldInterceptBackForCandidates({
  required bool hasCandidates,
  required bool candidatePlanning,
  required bool isRecording,
}) => !isRecording && (hasCandidates || candidatePlanning);

/// « Distance · 5,0 km ▸ » / « Durée · 1 h 30 ▸ » / « Explorer · 5,0 km ▸ »
/// — the plan-target panel's collapsed line (task-8 brief point 2). Uses the
/// renamed « Distance » label (point 3) even though [PlanMode.loop] is the
/// underlying identifier (kept stable for [PlanModeStore] persistence
/// compatibility); [PlanMode.explore] (task 7) gets its own « Explorer »
/// prefix on the same km formatting, since it shares Distance's slider/
/// target but is a visibly different mode to the walker.
String planPanelCollapsedLabel({
  required PlanMode mode,
  required double loopTargetKm,
  required Duration durationTarget,
}) {
  if (mode == PlanMode.loop || mode == PlanMode.explore) {
    final km = loopTargetKm.toStringAsFixed(1).replaceAll('.', ',');
    final label = mode == PlanMode.explore ? 'Explorer' : 'Distance';
    return '$label · $km km ▸';
  }
  final hours = durationTarget.inHours;
  final minutes = durationTarget.inMinutes % 60;
  final label = hours <= 0
      ? '$minutes min'
      : minutes == 0
      ? '$hours h'
      : '$hours h $minutes';
  return 'Durée · $label ▸';
}

// ---- Candidate selection ----------------------------------------------------

/// Clamps a candidate-card selection to the current candidate list, falling
/// back to 0 (the best-scored, first-shown candidate) whenever the previous
/// selection no longer exists — a fresh plan, or « Autres propositions »
/// coming back with fewer candidates than before (dedup can drop offers).
int clampSelection(int index, int candidateCount) {
  if (candidateCount <= 0) return 0;
  if (index < 0 || index >= candidateCount) return 0;
  return index;
}

// ---- Candidate display helpers ----------------------------------------------

/// Estimated duration for [distanceKm] at the walker's own learned pace
/// ([speedKmh]) — deliberately not `RouteResult.duration`, which is
/// Valhalla's generic profile estimate, not this user's.
Duration estimatedDuration(double distanceKm, double speedKmh) {
  if (speedKmh <= 0) return Duration.zero;
  final hours = distanceKm / speedKmh;
  return Duration(seconds: (hours * 3600).round());
}

/// « 2,4 km · ~32 min » for the A→B result banner — [speedKmh]'s personal
/// pace when it is known (same [estimatedDuration] the candidate cards
/// already use), or [RouteResult.duration] — Valhalla's generic profile
/// estimate — as the fallback while `SpeedHistoryStore`'s async load is
/// still in flight (owner-requested micro-feature, task 8: "il faut que la
/// durée affichée soit la vôtre, pas celle de Valhalla").
String formatRouteResultLabel(RouteResult r, double? speedKmh) {
  final km = r.distanceKm.toStringAsFixed(1).replaceAll('.', ',');
  final duration = speedKmh == null
      ? r.duration
      : estimatedDuration(r.distanceKm, speedKmh);
  final min = (duration.inSeconds / 60).round();
  return '$km km · ~$min min';
}

/// Whether [candidate] itself is within the planner's own tolerance of the
/// target — [LoopPlanner.targetTolerance], the same bound the planner checks
/// against `candidates.first` for `LoopPlanResult.targetMet` — applied
/// per-card so every card's badge reflects its own gap, not only the top
/// one's.
bool candidateOnTarget(LoopCandidate candidate) =>
    candidate.gapRatio.abs() <= LoopPlanner.targetTolerance + 1e-9;

/// « +12 % » / « -8 % » — signed, from [LoopCandidate.gapRatio] — or `null`
/// when the candidate is already on target (nothing to badge).
String? gapBadgeLabel(LoopCandidate candidate) {
  if (candidateOnTarget(candidate)) return null;
  final percent = (candidate.gapRatio * 100).round();
  final sign = percent > 0 ? '+' : '';
  return '$sign$percent %';
}

/// Whether "Autres propositions" should be hidden from the compact row —
/// fix-round-1, point 3: a single [PlanKind.toDestination] candidate is the
/// direct route the planner fell back to when it had no detour budget to
/// work with (see [loopTargetFloorForDestination]'s doc comment) — asking
/// again would deterministically hand back the exact same route, so the
/// action is hidden rather than offered as a no-op.
bool shouldHideOtherProposals({
  required int candidateCount,
  required PlanKind kind,
}) => candidateCount == 1 && kind == PlanKind.toDestination;

// ---- Mode persistence --------------------------------------------------------

const kPlanModePrefsKey = 'plan_mode';

/// Persists the selected [PlanMode] across app restarts — mirrors
/// `trip_controller.dart`'s `_defaultPersistProfile`/`_defaultLoadProfile`.
/// Only the mode itself is persisted (per the brief); slider targets reset to
/// their profile-based defaults each time Distance/Durée is (re-)entered.
class PlanModeStore {
  Future<PlanMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kPlanModePrefsKey);
    for (final mode in PlanMode.values) {
      if (mode.name == raw) return mode;
    }
    return PlanMode.itinerary;
  }

  Future<void> save(PlanMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPlanModePrefsKey, mode.name);
  }
}
