/// Task 2i: the two "commit" actions the trip-start wizard's screens end
/// on — persist everything [MapScreen] needs, and hand back the
/// [WizardHandoff] `CarteTabRoot` should build it with. Pulled out of the
/// screens themselves (`wizard_home_screen.dart`,
/// `wizard_destination_flow.dart`, `wizard_promenade_screen.dart`) because
/// both the « Promenade » screen's own "Proposer" button and the home
/// screen's « Repartir » quick-start (brief point 4) end on the *identical*
/// commit — one with the walker's fresh choices, the other replaying the
/// memorized ones.
///
/// Both take a plain [TripController] rather than a `WidgetRef` — callers
/// (every wizard screen) already have one via `ref.read(tripControllerProvider)`,
/// and keeping these functions Riverpod-free makes them testable against a
/// fake `TripController` (see `test/support/trip_fakes.dart`) with no
/// `ProviderContainer`/widget tree involved at all.
library;

import '../trip/active_route_store.dart';
import '../trip/trip_controller.dart';
import '../valhalla/models.dart';
import 'plan_mode.dart';
import 'wizard_defaults_store.dart';

/// Persists a « Promenade » (A→A loop, no pinned destination) plan and
/// returns the [WizardHandoff] `MapScreen.autoPlan` should be built with.
///
/// [mode] is [PlanMode.loop] or [PlanMode.duration] — which constraint the
/// walker picked — never [PlanMode.itinerary] (a promenade never has one).
Future<WizardHandoff> commitPromenadePlan(
  TripController trip, {
  required PlanMode mode,
  required double loopTargetKm,
  required Duration durationTarget,
  required RoutingProfile profile,
  bool autoAcceptBestCandidate = false,
}) async {
  assert(mode == PlanMode.loop || mode == PlanMode.duration);
  await trip.setProfile(profile);
  // A fresh promenade starts from wherever the walker actually is — any
  // departure pin or destination left over from an earlier itinerary
  // belongs to that session, not this one (mirrors `map_screen.dart`'s own
  // `_onPlanModeChanged` mode-switch rule, `shouldClearDestinationOnMode
  // Switch`).
  await trip.saveActiveRoute(ActiveRoute(profile: profile));
  await PlanModeStore().save(mode);
  final defaults = WizardDefaultsStore();
  await defaults.saveMode(mode);
  await defaults.saveLoopTargetKm(loopTargetKm);
  await defaults.saveDurationTarget(durationTarget);
  return WizardHandoff(
    loopTargetKm: mode == PlanMode.loop ? loopTargetKm : null,
    durationTarget: mode == PlanMode.duration ? durationTarget : null,
    autoAcceptBestCandidate: autoAcceptBestCandidate,
  );
}

/// Persists a « Destination » (A→B) plan — an address pin, plus an optional
/// distance/durée constraint — and returns the [WizardHandoff].
///
/// [constraintMode] is `null` for "aucune contrainte" (a direct itinerary —
/// [PlanMode.itinerary], `MapScreen`'s existing `_planRoute` path);
/// otherwise [PlanMode.loop]/[PlanMode.duration], which `map_screen.dart`'s
/// existing [buildLoopRequest] already honours a pinned destination for
/// (task-8 point 3) — see that function's own doc comment.
Future<WizardHandoff> commitDestinationPlan(
  TripController trip, {
  required (double, double) destination,
  PlanMode? constraintMode,
  double? loopTargetKm,
  Duration? durationTarget,
}) async {
  await trip.saveActiveRoute(
    ActiveRoute(profile: trip.profile, destination: destination),
  );
  final mode = constraintMode ?? PlanMode.itinerary;
  await PlanModeStore().save(mode);
  if (mode == PlanMode.loop || mode == PlanMode.duration) {
    final defaults = WizardDefaultsStore();
    await defaults.saveMode(mode);
    if (loopTargetKm != null) await defaults.saveLoopTargetKm(loopTargetKm);
    if (durationTarget != null) {
      await defaults.saveDurationTarget(durationTarget);
    }
  }
  return WizardHandoff(
    loopTargetKm: mode == PlanMode.loop ? loopTargetKm : null,
    durationTarget: mode == PlanMode.duration ? durationTarget : null,
  );
}
