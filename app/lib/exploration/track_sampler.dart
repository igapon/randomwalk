import '../nav/polyline_math.dart';

/// Minimum distance, in meters, between two consecutive points kept in a
/// [TrackSampler] — a GPS fix arrives every couple of seconds (every few
/// meters at walking pace), and keeping all of them would make the on-disk
/// track file (and the map-matching request built from it) grow far larger
/// than corridor/fog geometry (75 m corridor half-width) needs.
const kTrackMinStepM = 25.0;

/// Hard cap on how many points a [TrackSampler] ever holds. At
/// [kTrackMinStepM] this covers a 50 km trip before any thinning kicks in —
/// comfortably above any single walk or ride this app expects — while
/// keeping the bound in place for the pathological case (GPS jitter that
/// defeats the distance filter, or an unusually long ride) rather than
/// letting the on-disk track grow without limit for the lifetime of a trip.
const kTrackMaxPoints = 2000;

/// Bounded, distance-thinned accumulator for a trip's raw GPS track.
///
/// This is deliberately pure (no I/O, no clock): `tracking_service.dart`
/// feeds it fixes and persists whichever ones [add] reports as kept, and
/// `exploration_recorder.dart` reads back exactly what was persisted. Kept
/// as its own class specifically so the thinning behaviour (both the
/// per-point minimum step, and what happens once [kTrackMaxPoints] is
/// reached) is unit-testable without a fake GPS stream or a temp file.
class TrackSampler {
  final double minStepM;
  final int maxPoints;
  final List<(double, double)> _points = [];

  TrackSampler({this.minStepM = kTrackMinStepM, this.maxPoints = kTrackMaxPoints});

  /// Every point kept so far, in order.
  List<(double, double)> get points => List.unmodifiable(_points);

  int get length => _points.length;

  /// Considers a freshly-arrived fix. Returns `true` (and keeps the point)
  /// when it is the very first point, or at least [minStepM] meters from the
  /// last kept point; returns `false` (and keeps state unchanged) otherwise
  /// — the caller should only persist a point when this returns `true`.
  ///
  /// When accepting a point would exceed [maxPoints], the buffer is thinned
  /// first (see [_thin]) rather than refusing new points outright: an
  /// unusually long trip should keep tracing its whole route at coarser
  /// resolution, not stop recording new ground after some arbitrary prefix.
  bool add(double lat, double lon) {
    if (_points.isNotEmpty) {
      final (lastLat, lastLon) = _points.last;
      if (metersBetween(lastLat, lastLon, lat, lon) < minStepM) return false;
    }
    if (_points.length >= maxPoints) _thin();
    _points.add((lat, lon));
    return true;
  }

  /// Restores a point read back from disk (e.g. a service restart resuming
  /// an interrupted trip's already-persisted track) without applying the
  /// distance filter — the point was already accepted once, by an earlier
  /// call to [add], and re-filtering it against whatever the buffer's last
  /// point happens to be after a restart would silently drop real track
  /// data. Still respects [maxPoints] via the same thinning as [add].
  void seed(double lat, double lon) {
    if (_points.length >= maxPoints) _thin();
    _points.add((lat, lon));
  }

  /// Halves the buffer by keeping every other point (indices 0, 2, 4, ...).
  /// Preserves the first and, when the buffer has an odd length, the last
  /// point's general vicinity; the corridor/fog geometry built from the
  /// result only needs "close enough to the real path", not every sample.
  void _thin() {
    final thinned = <(double, double)>[
      for (var i = 0; i < _points.length; i += 2) _points[i],
    ];
    _points
      ..clear()
      ..addAll(thinned);
  }
}
