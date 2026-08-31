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

/// The three planning modes shown by the `SegmentedButton` above the search
/// bar. Persisted verbatim (`.name`) — see [PlanModeStore].
enum PlanMode { itinerary, loop, duration }

// ---- Boucle: distance target ----------------------------------------------

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
/// [clampLoopTargetKm] holds the Boucle slider to (final review item 4). The
/// two modes plan through the identical [LoopRequest]/`LoopPlanner` pipeline,
/// so a target Boucle cannot even express must not reach it from Durée
/// either: 4 h at a 25 km/h cycling pace is 100 km, which the planner would
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
LoopRequest? buildLoopRequest({
  required PlanMode mode,
  required double loopTargetKm,
  required Duration durationTarget,
  required double speedKmh,
  required RoutingProfile profile,
  required (double, double) start,
  (double, double)? destination,
  required int seed,
}) {
  if (mode == PlanMode.itinerary) return null;

  final targetKm = mode == PlanMode.loop
      ? loopTargetKm
      : durationToTargetKm(durationTarget, speedKmh);
  assert(targetKm > 0, 'targetKm must be positive');

  final kind =
      destination != null ? PlanKind.toDestination : PlanKind.loop;

  return LoopRequest(
    kind: kind,
    start: start,
    end: kind == PlanKind.toDestination ? destination : null,
    targetKm: targetKm,
    profile: profile,
    seed: seed,
  );
}

// ---- Destination pinning across mode switches -------------------------------

/// Fix-round-1 finding: a destination pinned while in [PlanMode.itinerary]
/// (long-press/search) that never turned into a route — a failed plan, or
/// simply one still in flight — used to survive a switch into Boucle/Durée
/// invisibly, silently turning Durée's next « Proposer » into a
/// fixed-duration A→B against a pin the walker never chose for that mode,
/// with no control on screen to see or clear it.
///
/// Final review item 7 makes the rule symmetric: **any** mode change with no
/// route on screen drops an un-routed destination. The original rule only
/// covered Itinéraire→(Boucle|Durée), which left the mirror image of the same
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
}) =>
    from != to && !hasRoute;

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
bool shouldShowPlanDestinationChip({
  required PlanMode mode,
  required bool hasDestination,
}) =>
    mode != PlanMode.itinerary && hasDestination;

// ---- Fullscreen candidate selection (task 8) --------------------------------

/// Task-8 brief point 1: the instant there are candidates to choose from, the
/// mode selector, search bar, profile picker and plan-target panel all step
/// aside for a fullscreen map with only the compact selection row at the
/// bottom — the owner's own words were "cache les menus... pour mieux voir
/// la carte". A single tested fact rather than a scattered `if` in `build()`.
bool shouldShowPlanningTopOverlay({required bool hasCandidates}) =>
    !hasCandidates;

/// « Distance · 5,0 km ▸ » / « Durée · 1 h 30 ▸ » — the plan-target panel's
/// collapsed line (task-8 brief point 2). Uses the renamed « Distance »
/// label (point 3) even though [PlanMode.loop] is the underlying identifier
/// (kept stable for [PlanModeStore] persistence compatibility).
String planPanelCollapsedLabel({
  required PlanMode mode,
  required double loopTargetKm,
  required Duration durationTarget,
}) {
  if (mode == PlanMode.loop) {
    final km = loopTargetKm.toStringAsFixed(1).replaceAll('.', ',');
    return 'Distance · $km km ▸';
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
  final duration =
      speedKmh == null ? r.duration : estimatedDuration(r.distanceKm, speedKmh);
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

/// Below this fraction of self-retracing, a route reads as "barely any
/// out-and-back" rather than "a fair bit of it" — the brief's own two
/// examples for the mini-indicator.
const double kRepeatedRatioNoticeable = 0.15;

String repeatedRatioHint(double repeatedRatio) =>
    repeatedRatio < kRepeatedRatioNoticeable
        ? "peu d'allers-retours"
        : 'quelques allers-retours';

// ---- Mode persistence --------------------------------------------------------

const kPlanModePrefsKey = 'plan_mode';

/// Persists the selected [PlanMode] across app restarts — mirrors
/// `trip_controller.dart`'s `_defaultPersistProfile`/`_defaultLoadProfile`.
/// Only the mode itself is persisted (per the brief); slider targets reset to
/// their profile-based defaults each time Boucle/Durée is (re-)entered.
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
