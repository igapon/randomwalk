import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/session/recorder.dart';

GpsSample s(
  double lat,
  double lon, {
  double acc = 5,
  double speed = 1.4,
  int t = 0,
}) => GpsSample(
  lat: lat,
  lon: lon,
  accuracyM: acc,
  speedMps: speed,
  time: DateTime(2026, 1, 1).add(Duration(seconds: t)),
);

void main() {
  test('accumulates haversine distance over a straight walk', () {
    final r = SessionRecorder();
    // ~111 m per 0.001° latitude step
    for (var i = 0; i <= 10; i++) {
      r.add(s(46.5 + i * 0.001, 6.6, t: i * 60));
    }
    expect(r.distanceKm, closeTo(1.11, 0.02));
  });

  test('ignores inaccurate fixes', () {
    final r = SessionRecorder();
    r.add(s(46.5, 6.6));
    r.add(s(46.6, 6.6, acc: 80, t: 60)); // 11 km in one jump, 80 m accuracy
    expect(r.distanceKm, 0);
  });

  test('ignores implausible jumps (over 90 km/h)', () {
    final r = SessionRecorder();
    r.add(s(46.5, 6.6));
    r.add(s(46.6, 6.6, t: 60)); // 11 km in 1 min = 660 km/h
    expect(r.distanceKm, 0);
  });

  test('ignores sub-3m jitter', () {
    final r = SessionRecorder();
    r.add(s(46.5, 6.6));
    r.add(s(46.500001, 6.6, t: 10));
    expect(r.distanceKm, 0);
  });
}
