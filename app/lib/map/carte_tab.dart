/// Task 2i: the Carte tab's own tiny router — swaps its body between the
/// trip-start wizard (`wizard_home_screen.dart`) and [MapScreen], reactively,
/// with no `Navigator.push` between the two: `MapScreen` owns a real native
/// map view, and a pushed route would leave a second, hidden one alive
/// underneath for as long as a plan/trip persists (see this class's own doc
/// comment below for why that matters). One `CarteTabRoot` instance lives for
/// the app's whole session — it is `HomeShell.defaultScreens[0]`, kept
/// mounted by the tab `IndexedStack` exactly like `MapScreen` itself used to
/// be — so its own `_showMap` flag survives tab switches and backgrounding,
/// resetting only on a genuine cold start (a fresh `CarteTabRoot` State),
/// which is exactly when the wizard should be the very first thing shown.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../trip/trip_controller.dart';
import 'map_screen.dart';
import 'plan_mode.dart';
import 'wizard_home_screen.dart';

/// Decides Wizard vs. [MapScreen] for the Carte tab.
///
/// Two independent signals feed the decision, ORed together:
///
///  * **Persisted state** (`trip.state`/`trip.activeRoute`) — survives a
///    cold start, since [TripController.restore] runs before the first
///    frame. This alone is what makes "an active trip opens straight onto
///    the nav map" and "a mid-plan app-switch returns to where you left it"
///    both true with zero code here beyond reading them: it is exactly the
///    same [TripController] state `MapScreen` itself has always read.
///  * **`_showMap`**, this widget's own in-memory flag — set the instant the
///    wizard hands off (Destination, Promenade, « Repartir », or plain
///    « Explorer la carte »), and the only signal for the one case the
///    persisted state cannot see at all: free exploration, or a Promenade
///    still mid-candidate-selection, where nothing has been saved into
///    [ActiveRoute] yet (a loop has no destination to persist, and the
///    fullscreen candidates themselves are `MapScreen`'s own private,
///    intentionally ephemeral UI state — see `map_screen.dart`'s
///    `_candidateResult`). Without it, the tab would flip straight back to
///    the wizard on the very next unrelated rebuild.
///
/// Why not *only* the sticky flag: a cold start has no flag to read (a fresh
/// `CarteTabRoot` always starts `_showMap = false`) — the persisted check is
/// what still recovers an in-progress plan or a recording trip in that case.
/// Why not *only* the persisted check: it is blind to the two ephemeral cases
/// above.
class CarteTabRoot extends ConsumerStatefulWidget {
  const CarteTabRoot({super.key});

  @override
  ConsumerState<CarteTabRoot> createState() => _CarteTabRootState();
}

class _CarteTabRootState extends ConsumerState<CarteTabRoot> {
  bool _showMap = false;

  /// Consumed by [MapScreen.autoPlan] on the very next build — see
  /// [_enterMap]'s doc comment.
  WizardHandoff? _pendingAutoPlan;

  /// Called by the wizard's own screens (Destination, Promenade, «
  /// Repartir ») once they have already persisted everything `MapScreen`
  /// needs (destination/profile via [TripController], the mode via
  /// `PlanModeStore` — see `wizard_actions.dart`) — and by « Explorer la
  /// carte », which persists nothing at all, hence `handoff` staying null
  /// there.
  ///
  /// [handoff] is read exactly once: [build] hands it to a freshly-built
  /// [MapScreen] and immediately forgets it, so a *later* rebuild — while
  /// `_showMap` is still true, `MapScreen`'s own State instance kept alive
  /// the whole time by this widget staying mounted — can never replay a
  /// stale plan into `initState` a second time (`initState` itself only
  /// ever runs once per State instance regardless, but forgetting it here
  /// too is what keeps a *later* `_showMap` cycle — exit, then some other
  /// entry point — from starting with a leftover target from a previous
  /// one).
  void _enterMap([WizardHandoff? handoff]) {
    setState(() {
      _showMap = true;
      _pendingAutoPlan = handoff;
    });
  }

  /// The « Accueil » affordance `MapScreen` shows whenever
  /// [MapScreen.onExitToWizard] is non-null (see [build]) — discards
  /// whatever is planned, the same as the result banner's own ✕, and hands
  /// control back to the wizard. Deliberately unconditional about clearing
  /// [ActiveRoute]: without it, a still-persisted plan would make the
  /// `hasPersistedPlanOrTrip` check in [build] immediately override
  /// `_showMap = false` right back to showing `MapScreen` again, and the
  /// button would silently do nothing.
  void _exitToWizard() {
    // Fire-and-forget, like every other `TripController` write this file
    // doesn't need to await UI-visibly — `clearActiveRoute` notifies
    // listeners (hence flips `activeRoute` to null) synchronously, before
    // its own `routeStore.clear()` await, so the `setState` right below is
    // never racing a stale read of it.
    unawaited(ref.read(tripControllerProvider).clearActiveRoute());
    setState(() {
      _showMap = false;
      _pendingAutoPlan = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final trip = ref.watch(tripControllerProvider);
    if (shouldShowWizardHome(
      showMapSticky: _showMap,
      tripState: trip.state,
      activeRouteEmpty: trip.activeRoute?.isEmpty ?? true,
    )) {
      return WizardHomeScreen(onEnterMap: _enterMap);
    }
    final handoff = _pendingAutoPlan;
    _pendingAutoPlan = null;
    // Brief's own pinned rule: an active trip's nav map is unchanged — no
    // new "Accueil" affordance appears mid-trip, or while a « Trajet
    // interrompu » banner is the only way out of `TripState.interrupted`.
    final showExit = !trip.isRecording && !trip.isInterrupted;
    return MapScreen(
      autoPlan: handoff,
      onExitToWizard: showExit ? _exitToWizard : null,
    );
  }
}

/// The pure decision behind [CarteTabRoot.build] — see that class's own doc
/// comment for what each input means and why both are needed. Pulled out as
/// a plain function so the branching itself is unit-testable without
/// pumping `MapScreen` — which, owning a real native map view, cannot be
/// widget-tested at all (see `map_screen_widgets_test.dart`'s own doc
/// comment).
bool shouldShowWizardHome({
  required bool showMapSticky,
  required TripState tripState,
  required bool activeRouteEmpty,
}) => !showMapSticky && tripState == TripState.idle && activeRouteEmpty;
