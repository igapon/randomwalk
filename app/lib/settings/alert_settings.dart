import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the two maneuver-alert toggles — « Guidage vocal » (spoken
/// French instructions) and « Vibrations et alertes » (the guidance
/// notification's sound/vibration) — reachable from the settings screen.
///
/// Both default to on: a walker who bothered to plan a route wants to know
/// when a turn is coming, and nothing here fires at all unless the trip is
/// route-bound in the first place (see `AlertPolicy`/`TripTaskHandler`).
class AlertSettingsStore {
  static const _ttsKey = 'tts_enabled';
  static const _hapticsKey = 'haptics_enabled';

  Future<bool> ttsEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_ttsKey) ?? true;

  Future<void> setTtsEnabled(bool value) async =>
      (await SharedPreferences.getInstance()).setBool(_ttsKey, value);

  Future<bool> hapticsEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_hapticsKey) ?? true;

  Future<void> setHapticsEnabled(bool value) async =>
      (await SharedPreferences.getInstance()).setBool(_hapticsKey, value);
}

final alertSettingsStoreProvider = Provider<AlertSettingsStore>(
  (ref) => AlertSettingsStore(),
);
