/// Task 2i: the trip-start wizard's own memorized defaults — last constraint
/// kind (Distance or Durée), last target value for each, and last routing
/// profile chosen from the « Promenade » screen — so both the wizard's own
/// sliders (pre-filled next time it opens) and the « Repartir » quick-start
/// (brief point 4: "dernier profil + derniers paramètres mémorisés") land on
/// what the walker actually used last, not a fresh profile-based default
/// every session.
///
/// Deliberately separate from [PlanModeStore] (`plan_mode.dart`): that store
/// persists *only* the mode `MapScreen`'s own segmented button was last left
/// on (by its own long-standing doc comment: "slider targets reset to their
/// profile-based defaults each time Distance/Durée is (re-)entered" — a
/// pre-task-2i behavior this file must not disturb). The wizard's quick-start
/// path needs the slider *values* remembered too, which is a new requirement
/// this task introduces — hence a store of its own rather than repurposing
/// `PlanModeStore`.
///
/// Routing profile itself is NOT duplicated here: `TripController` already
/// persists it (`trip_controller.dart`'s `_defaultPersistProfile`/
/// `_defaultLoadProfile`), and every wizard screen reads/writes it straight
/// through `TripController.profile`/`setProfile` — one source of truth.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../valhalla/models.dart';
import 'plan_mode.dart';

const _kModeKey = 'wizard_promenade_mode';
const _kLoopKmKey = 'wizard_last_loop_km';
const _kDurationMinutesKey = 'wizard_last_duration_min';

/// The wizard's own memorized « Promenade » config: which constraint kind was
/// last used, and the last target value for *each* kind (so switching chips
/// back and forth in the same session — or across sessions — never loses the
/// other one's last value).
class WizardPromenadeDefaults {
  final PlanMode mode;
  final double loopTargetKm;
  final Duration durationTarget;

  const WizardPromenadeDefaults({
    required this.mode,
    required this.loopTargetKm,
    required this.durationTarget,
  });
}

/// SharedPreferences-backed, mirroring [PlanModeStore]'s own thin-wrapper
/// shape.
class WizardDefaultsStore {
  /// The memorized config, or profile/task defaults for whichever part of it
  /// was never saved (e.g. a fresh install, or a walker who has only ever
  /// used the « Destination » branch).
  Future<WizardPromenadeDefaults> load(RoutingProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final rawMode = prefs.getString(_kModeKey);
    final mode = rawMode == PlanMode.duration.name
        ? PlanMode.duration
        : PlanMode.loop;
    final km = prefs.getDouble(_kLoopKmKey) ?? defaultLoopTargetKm(profile);
    final minutes = prefs.getInt(_kDurationMinutesKey);
    final duration = minutes == null
        ? kDurationTargetDefault
        : Duration(minutes: minutes);
    return WizardPromenadeDefaults(
      mode: mode,
      loopTargetKm: clampLoopTargetKm(km),
      durationTarget: clampDurationTarget(duration),
    );
  }

  /// Persists the constraint kind the walker just finished the « Promenade »
  /// screen with — [PlanMode.loop] or [PlanMode.duration] only; any other
  /// value is a caller error and is ignored rather than corrupting the
  /// stored preference with something [load] would silently reinterpret.
  Future<void> saveMode(PlanMode mode) async {
    if (mode != PlanMode.loop && mode != PlanMode.duration) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kModeKey, mode.name);
  }

  Future<void> saveLoopTargetKm(double km) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kLoopKmKey, clampLoopTargetKm(km));
  }

  Future<void> saveDurationTarget(Duration duration) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _kDurationMinutesKey,
      clampDurationTarget(duration).inMinutes,
    );
  }
}
