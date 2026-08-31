import 'dart:math' as math;

/// Exponential moving average of instantaneous speed samples, used to derive
/// an ETA for [RouteFollower].
///
/// Each sample decays the previous average by `exp(-dt/halfLife)`, so recent
/// movement dominates while brief GPS noise is smoothed out. The estimate is
/// withheld ([speedMps] returns null) until at least 3 samples have been
/// recorded, so an ETA is never shown from a single noisy reading.
class SpeedEstimator {
  final double halfLife;
  SpeedEstimator({this.halfLife = 30});

  double? _speedMps;
  DateTime? _lastSampleTime;
  int _sampleCount = 0;

  void add(double speedMps, DateTime time) {
    final previous = _speedMps;
    final previousTime = _lastSampleTime;
    if (previous == null || previousTime == null) {
      _speedMps = speedMps;
      _lastSampleTime = time;
      _sampleCount++;
      return;
    }
    final dtSeconds = time.difference(previousTime).inMicroseconds / 1e6;
    if (dtSeconds <= 0) {
      // A non-advancing or out-of-order timestamp contributes nothing: it
      // neither moves the average nor counts toward the 3-sample minimum.
      return;
    }
    final f = math.exp(-dtSeconds / halfLife);
    _speedMps = previous * f + speedMps * (1 - f);
    _lastSampleTime = time;
    _sampleCount++;
  }

  /// Null until at least 3 samples have been recorded.
  double? get speedMps => _sampleCount >= 3 ? _speedMps : null;
}
