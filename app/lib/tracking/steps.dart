import 'device_channel.dart';

/// Turns Android's boot-cumulative `TYPE_STEP_COUNTER` readings into a
/// per-session step delta.
///
/// The sensor counts every step since the device booted and is shared by
/// every app on the phone, so a session's steps are the difference against
/// whatever it read when the session began. Two edge cases make this less
/// trivial than a subtraction:
///  - the device can reboot mid-trip, resetting the counter to ~0. The naive
///    delta then goes hugely negative; here it re-anchors and keeps what was
///    already counted.
///  - a trip resumed after the app process was killed must not restart from
///    zero — [seed] carries the steps already banked in the snapshot.
class StepTally {
  int _accumulated;
  int? _baseline;
  int _sinceBaseline = 0;

  StepTally({int seed = 0}) : _accumulated = seed;

  int get steps => _accumulated + _sinceBaseline;

  void record(int cumulativeSteps) {
    final baseline = _baseline;
    if (baseline == null) {
      _baseline = cumulativeSteps;
      _sinceBaseline = 0;
      return;
    }
    if (cumulativeSteps < baseline) {
      // Reboot (or a sensor that restarted): bank what we counted and
      // re-anchor on the new, lower reading.
      _accumulated += _sinceBaseline;
      _baseline = cumulativeSteps;
      _sinceBaseline = 0;
      return;
    }
    _sinceBaseline = cumulativeSteps - baseline;
  }
}

/// The hardware step counter, as a *pull* interface rather than a stream.
///
/// This is the whole reason steps work with the screen off. `TYPE_STEP_
/// COUNTER` is a low-power hardware counter that keeps counting through
/// doze whether or not anyone is listening; what stops during doze is event
/// *delivery* (the open, unanswered `pedometer` bug cph-cachet/flutter-
/// plugins#952 is exactly that). Reading the counter's current value
/// whenever the app is actually on screen, and diffing against the value at
/// trip start, sidesteps delivery entirely: steps taken while the phone was
/// asleep are already in the number when we next look at it.
abstract class StepSensor {
  /// Registers the sensor listener. Returns false when the device has no
  /// step counter or ACTIVITY_RECOGNITION was refused.
  Future<bool> start();

  /// The current since-boot count, or null if no reading is available yet.
  Future<int?> read();

  Future<void> stop();
}

/// One trip's worth of steps: a [StepTally] fed from a [StepSensor].
class SessionStepCounter {
  final StepSensor _sensor;
  final StepTally _tally;
  bool _available = false;

  SessionStepCounter(this._sensor, {int seed = 0})
    : _tally = StepTally(seed: seed);

  int get steps => _tally.steps;
  bool get isAvailable => _available;

  /// Starts the sensor and anchors the baseline on its first reading, so a
  /// trip's steps are counted from the moment it started rather than from
  /// the first time the app happens to be looked at.
  Future<bool> start() async {
    _available = await _safely(() => _sensor.start()) ?? false;
    if (_available) await sample();
    return _available;
  }

  /// Reads the counter and folds it into the tally. Cheap enough to call on
  /// the UI's once-a-second tick; a failed or absent reading simply leaves
  /// the count where it was.
  Future<void> sample() async {
    if (!_available) return;
    final value = await _safely(() => _sensor.read());
    if (value != null) _tally.record(value);
  }

  Future<void> stop() async {
    await _safely(() => _sensor.stop());
    _available = false;
  }

  /// The step count is a nice-to-have signal (brief §5, walk plausibility).
  /// No sensor failure is ever worth interrupting a recording trip for.
  Future<T?> _safely<T>(Future<T> Function() op) async {
    try {
      return await op();
    } catch (_) {
      return null;
    }
  }
}

/// The real sensor, over the app's own platform channel (see
/// `DeviceChannel.kt`).
class ChannelStepSensor implements StepSensor {
  final DeviceChannel _channel;
  ChannelStepSensor([DeviceChannel? channel])
    : _channel = channel ?? const DeviceChannel();

  @override
  Future<bool> start() => _channel.startStepCounter();

  @override
  Future<int?> read() => _channel.stepCount();

  @override
  Future<void> stop() => _channel.stopStepCounter();
}
