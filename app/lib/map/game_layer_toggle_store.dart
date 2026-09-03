/// Task 2j: persists whether the "couche Aventure" (fog + POIs + exploration
/// bearings) is shown on the main map — mirrors `plan_mode.dart`'s
/// `PlanModeStore`/`trip_controller.dart`'s profile persistence: a thin
/// `shared_preferences` wrapper around one flag.
library;

import 'package:shared_preferences/shared_preferences.dart';

const kGameLayerEnabledPrefsKey = 'game_layer_enabled';

/// Default ON — the brief's own pin: "le jeu est l'identité du produit,
/// même si ça veut dire respecter le choix persisté" once the walker has
/// actually turned it off.
const kGameLayerEnabledDefault = true;

class GameLayerToggleStore {
  Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kGameLayerEnabledPrefsKey) ?? kGameLayerEnabledDefault;
  }

  Future<void> save(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kGameLayerEnabledPrefsKey, enabled);
  }
}
