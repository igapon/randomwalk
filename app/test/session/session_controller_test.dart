import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:randomwalk/session/session_controller.dart';
import 'package:randomwalk/session/recorder.dart';

class FakeStore implements TotalDistanceStore {
  double _total = 0;

  @override
  Future<double> totalKm() async => _total;

  @override
  Future<double> addAndGetTotalKm(double km) async {
    _total += km;
    return _total;
  }
}

void main() {
  test('ignores double-start (re-entrancy guard)', () async {
    final store = FakeStore();

    // Mock permission checker that has a delay to expose the re-entrancy window.
    Future<bool> slowPermissions() async {
      await Future.delayed(const Duration(milliseconds: 50));
      return true;
    }

    // Mock stream that never emits (to keep session alive).
    Stream<Position> mockStream(LocationSettings settings) {
      return StreamController<Position>().stream;
    }

    final controller = SessionController(
      store: store,
      getPositionStream: mockStream,
      checkPermissions: slowPermissions,
    );

    // Start first session (permissions check is delayed).
    final firstStart = controller.start();
    expect(controller.isStarting, true);

    // Try to start while first start is still in progress -> should return false.
    final secondStart = controller.start();

    // First start should eventually succeed.
    final firstResult = await firstStart;
    expect(firstResult, true);
    expect(controller.isRecording, true);

    // Second start should have returned false.
    final secondResult = await secondStart;
    expect(secondResult, false);

    // Stop and verify we can start again.
    await controller.stop();
    expect(controller.isRecording, false);

    final third = await controller.start();
    expect(third, true);
  });

  test('creates fresh recorder per session', () async {
    final store = FakeStore();

    // Create positions with known distance.
    final positions = [
      Position(
        latitude: 46.5,
        longitude: 6.6,
        accuracy: 5,
        speed: 0,
        speedAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        altitudeAccuracy: 0,
        altitude: 0,
      ),
      Position(
        latitude: 46.501,
        longitude: 6.6,
        accuracy: 5,
        speed: 0,
        speedAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        timestamp: DateTime.fromMillisecondsSinceEpoch(60000),
        altitudeAccuracy: 0,
        altitude: 0,
      ),
    ];

    Stream<Position> mockStream(LocationSettings settings) {
      return Stream.fromIterable(positions);
    }

    Future<bool> mockPermissions() async => true;

    final controller = SessionController(
      store: store,
      getPositionStream: mockStream,
      checkPermissions: mockPermissions,
    );

    // Session 1: start and wait for positions to stream.
    expect(await controller.start(), true);
    await Future.delayed(const Duration(milliseconds: 100));
    final dist1 = controller.recorder?.distanceKm ?? 0;
    expect(dist1, greaterThan(0));

    await controller.stop();
    final total1 = store._total;
    expect(total1, greaterThan(0));

    // Session 2: fresh recorder, starts from 0.
    expect(await controller.start(), true);
    expect(controller.recorder?.distanceKm, 0); // Fresh recorder.

    await Future.delayed(const Duration(milliseconds: 100));
    final dist2 = controller.recorder?.distanceKm ?? 0;
    expect(dist2, greaterThan(0)); // Same distance as session 1.

    await controller.stop();
    final total2 = store._total;
    // Total should have accumulated both sessions' distances.
    expect(total2, closeTo(total1 * 2, 0.01));
  });

  test('elapsed is 0 when not recording', () {
    final store = FakeStore();
    final controller = SessionController(store: store);

    expect(controller.elapsed, Duration.zero);
  });

  test('stop when not recording returns 0', () async {
    final store = FakeStore();
    final controller = SessionController(store: store);

    final distance = await controller.stop();
    expect(distance, 0);
  });
}
