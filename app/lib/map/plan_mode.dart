/// Pure state for the map's plan-mode selector (« Itinéraire » / « Boucle »
/// / « Durée » — task 6). Everything here is Flutter- and async-free (save
/// for [PlanModeStore], a thin `shared_preferences` wrapper mirroring
/// `trip_controller.dart`'s profile persistence): mode transitions, slider
/// clamping/stepping, the duration→distance conversion via
/// `SpeedHistoryStore`, candidate seed stepping and selection, and the small
/// per-candidate display helpers the bottom sheet reads (gap badge,
/// repeated-segment hint).
///
/// The widgets themselves (`map_screen.dart`, `candidates_sheet.dart`) hold
/// no planning logic of their own — they call into this file and render
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
/// tested as plain functions. Always positive: [speedKmh] is, by
/// `SpeedHistoryStore`'s own contract (default or EMA, never zero/negative),
/// and [kDurationTargetMin] is a positive duration.
double durationToTargetKm(Duration duration, double speedKmh) {
  assert(speedKmh > 0, 'speedKmh must be positive');
  return duration.inSeconds / 3600 * speedKmh;
}

/// « ≈ 3,8 km à votre rythme » — French decimal comma, one decimal place.
String formatConversionLabel(double km) {
  final formatted = km.toStringAsFixed(1).replaceAll('.', ',');
  return '≈ $formatted km à votre rythme';
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
/// in [PlanMode.duration] its presence is what switches the request from a
/// loop to a fixed-duration A→B ([PlanKind.toDestination]).
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

  final kind = mode == PlanMode.duration && destination != null
      ? PlanKind.toDestination
      : PlanKind.loop;

  return LoopRequest(
    kind: kind,
    start: start,
    end: kind == PlanKind.toDestination ? destination : null,
    targetKm: targetKm,
    profile: profile,
    seed: seed,
  );
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
