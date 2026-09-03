import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// The native still/moving signal source `TripTaskHandler` drives
/// [MotionPolicy] from — an interface (rather than [MotionChannel] used
/// directly) for the same reason `StepSensor` sits in front of
/// `ChannelStepSensor` (see `steps.dart`): a real platform channel has no
/// way to synthesize a STILL-enter/exit event from a host-run `flutter
/// test`, so `TripTaskHandler`'s own tests swap in a fake implementation to
/// exercise the native-available path — the always-false [MotionChannel]
/// behaviour a bare host test gets for free only covers the *fallback*
/// path (see that class's doc comment).
abstract class MotionSignalSource {
  /// Registers the native listener. Returns whether it actually did.
  Future<bool> start();

  Future<void> stop();

  /// `true` on STILL entered, `false` on STILL exited.
  Stream<bool> get transitions;
}

/// The app's own thin platform channel for the Activity Recognition
/// Transition API (`com.google.android.gms.location.ActivityRecognitionClient`
/// STILL enter/exit), in the same shape as [DeviceChannel]/`TtsChannel` — see
/// `MotionChannel.kt`.
///
/// Unlike those two, this channel is push-based: once [start] has
/// registered the native transition listener, native code calls back into
/// Dart on its own (a still/moving event, whenever the OS actually detects
/// one) rather than answering a single request. [transitions] is that
/// stream — `true` for STILL entered, `false` for STILL exited.
///
/// Degrades quietly by construction, matching every other channel here:
/// [start] returns `false` off Android, on any platform-channel failure, or
/// when Play Services genuinely has no Activity Recognition support on this
/// device — the caller (`TripTaskHandler`) reads that as "use the
/// step/GPS fallback instead" (see `motion_policy.dart`'s
/// `GpsStillnessTracker`), never as a reason to fail the trip. This is also
/// exactly the emulator's path in CI: the integration test's emulator has no
/// real Activity Recognition, so [start] returning `false` there is the
/// expected, silent degradation the task brief asks for, not a bug.
class MotionChannel implements MotionSignalSource {
  static const channel = MethodChannel('randomwalk/motion');

  /// Shared across every [MotionChannel] instance, deliberately: the
  /// underlying [channel] is itself a single static `MethodChannel` (its
  /// `setMethodCallHandler` accepts exactly one handler at a time, same as
  /// every other channel in this app), so two instances each keeping their
  /// own controller would just have the second one's [transitions] getter
  /// silently steal native's callbacks away from the first.
  static final StreamController<bool> _transitions =
      StreamController<bool>.broadcast();
  static bool _handlerWired = false;

  const MotionChannel();

  /// Registers the native STILL enter/exit transition listener. Returns
  /// `true` once actually registered, `false` off Android, on any channel
  /// failure, or if Play Services/the device refused the registration
  /// (missing Activity Recognition support, permission not granted, no
  /// Play Services at all).
  @override
  Future<bool> start() async {
    if (!Platform.isAndroid) return false;
    try {
      return await channel.invokeMethod<bool>('start') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Nothing to release, or the engine is already gone.
    } on MissingPluginException {
      // Nothing to release, or the engine is already gone.
    }
  }

  /// The native → Dart pushes — `true` on STILL entered, `false` on STILL
  /// exited. Wires the method-call handler lazily, on first access, rather
  /// than at construction (a `const MotionChannel()` built before [start]
  /// is ever called — e.g. to just call [stop] — must not install a
  /// handler nothing is listening to).
  @override
  Stream<bool> get transitions {
    if (!_handlerWired) {
      _handlerWired = true;
      channel.setMethodCallHandler((call) async {
        if (call.method != 'onTransition') return;
        final args = call.arguments;
        if (args is Map && args['stillEntered'] is bool) {
          if (!_transitions.isClosed) {
            _transitions.add(args['stillEntered'] as bool);
          }
        }
      });
    }
    return _transitions.stream;
  }
}
