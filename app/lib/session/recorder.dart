import 'dart:math' as math;
import 'package:shared_preferences/shared_preferences.dart';

class GpsSample {
  final double lat, lon, accuracyM, speedMps;
  final DateTime time;
  const GpsSample(
      {required this.lat,
      required this.lon,
      required this.accuracyM,
      required this.speedMps,
      required this.time});
}

double haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(a.toDouble()));
}

class SessionRecorder {
  static const _maxAccuracyM = 25.0;
  static const _minStepM = 3.0;
  static const _maxSpeedKmh = 90.0;

  GpsSample? _last;
  double _distanceKm = 0;
  DateTime? _startedAt;

  double get distanceKm => _distanceKm;
  Duration elapsed(DateTime now) =>
      _startedAt == null ? Duration.zero : now.difference(_startedAt!);

  void add(GpsSample sample) {
    if (sample.accuracyM > _maxAccuracyM) return;
    _startedAt ??= sample.time;
    final last = _last;
    if (last == null) {
      _last = sample;
      return;
    }
    final stepKm = haversineKm(last.lat, last.lon, sample.lat, sample.lon);
    final dtH = sample.time.difference(last.time).inMilliseconds / 3.6e6;
    if (stepKm * 1000 < _minStepM) return; // jitter: keep _last anchored
    if (dtH <= 0 || stepKm / dtH > _maxSpeedKmh) {
      _last = sample; // resync after an implausible jump
      return;
    }
    _distanceKm += stepKm;
    _last = sample;
  }
}

class TotalDistanceStore {
  static const _key = 'total_km';
  Future<double> totalKm() async =>
      (await SharedPreferences.getInstance()).getDouble(_key) ?? 0;
  Future<double> addAndGetTotalKm(double km) async {
    final prefs = await SharedPreferences.getInstance();
    final total = (prefs.getDouble(_key) ?? 0) + km;
    await prefs.setDouble(_key, total);
    return total;
  }
}
