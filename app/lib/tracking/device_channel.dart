import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// The app's own thin platform channel for the two Android facts no pub
/// package gives us cheaply (see `DeviceChannel.kt`, same pattern as
/// `ValhallaChannel`):
///
///  - the running API level, used to gate permission prompts that do not
///    exist on older releases (POST_NOTIFICATIONS is Android 13+,
///    ACTIVITY_RECOGNITION is Android 10+). A whole `device_info_plus`
///    dependency for one integer was not worth it;
///  - the hardware `TYPE_STEP_COUNTER` value. The maintained pub option
///    (`pedometer`) only exposes a *stream*, and has an open, unanswered
///    bug (cph-cachet/flutter-plugins#952) where that stream stops
///    delivering while the screen is off — precisely this feature's
///    requirement. Reading the cumulative counter on demand avoids the
///    problem by construction; see [StepSensor].
///
/// Every method degrades quietly off Android (and on a platform-channel
/// failure): steps are an optional signal, never a reason to fail a trip.
class DeviceChannel {
  // Public (not `_`-prefixed) so tests can mock it directly — see
  // `NativeTtsSpeaker.channel` for the same pattern.
  static const channel = MethodChannel('randomwalk/device');

  const DeviceChannel();

  /// `Build.MANUFACTURER` (e.g. "xiaomi", "samsung"), or null off Android
  /// or on any channel failure. Used by Settings to decide whether to show
  /// the "Suivi fiable en arrière-plan" tile — see
  /// `isAggressiveBatteryOem`.
  Future<String?> manufacturer() async {
    if (!Platform.isAndroid) return null;
    try {
      return await channel.invokeMethod<String>('manufacturer');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<int> sdkInt() async {
    if (!Platform.isAndroid) return 0;
    try {
      return await channel.invokeMethod<int>('sdkInt') ?? 0;
    } on PlatformException {
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  Future<bool> startStepCounter() async {
    if (!Platform.isAndroid) return false;
    try {
      return await channel.invokeMethod<bool>('startStepCounter') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// The since-boot step count, or null when the sensor has not reported
  /// yet (it reports on registration, but that is asynchronous).
  Future<int?> stepCount() async {
    if (!Platform.isAndroid) return null;
    try {
      return await channel.invokeMethod<int>('stepCount');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> stopStepCounter() async {
    if (!Platform.isAndroid) return;
    try {
      await channel.invokeMethod<void>('stopStepCounter');
    } on PlatformException {
      // Nothing to release, or the engine is already gone.
    } on MissingPluginException {
      // Nothing to release, or the engine is already gone.
    }
  }
}
