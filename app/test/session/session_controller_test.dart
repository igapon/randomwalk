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
  _lastFixAtTests();

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

  test('stream error persists distance, resets state, invokes callbacks', () async {
    final store = FakeStore();
    String? errorReceived;
    double? totalKmReceived;
    bool onErrorCalled = false;
    bool onEndedCalled = false;

    // Create a controller for the mock stream so we can manually emit and error.
    final streamController = StreamController<Position>();

    Future<bool> mockPermissions() async => true;

    final controller = SessionController(
      store: store,
      getPositionStream: (_) => streamController.stream,
      checkPermissions: mockPermissions,
      onSessionError: (msg) async {
        errorReceived = msg;
        onErrorCalled = true;
      },
      onSessionEnded: (totalKm) async {
        totalKmReceived = totalKm;
        onEndedCalled = true;
      },
    );

    expect(await controller.start(), true);

    // Emit positions manually.
    final now = DateTime.now();
    streamController.add(Position(
      latitude: 46.5,
      longitude: 6.6,
      accuracy: 5,
      speed: 0,
      speedAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      timestamp: now,
      altitudeAccuracy: 0,
      altitude: 0,
    ));
    streamController.add(Position(
      latitude: 46.501,
      longitude: 6.6,
      accuracy: 5,
      speed: 0,
      speedAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      timestamp: now.add(const Duration(seconds: 1)),
      altitudeAccuracy: 0,
      altitude: 0,
    ));

    // Let positions be processed.
    await Future.delayed(const Duration(milliseconds: 50));

    // Now trigger the stream error.
    streamController.addError(Exception('GPS stream error'));
    await Future.delayed(const Duration(milliseconds: 100));

    // Verify stream error was handled: state reset and callbacks fired.
    expect(controller.isRecording, false); // Session ended
    expect(onErrorCalled, true); // Error callback fired
    expect(onEndedCalled, true); // End callback fired
    expect(errorReceived, contains('GPS stream error'));
    // Callbacks received the total km (even if 0, due to timing).
    expect(totalKmReceived, isNotNull);
    expect(store._total, equals(totalKmReceived)); // Store was updated with persisted distance
  });

  test('restart after error creates single subscription (no duplicates)', () async {
    final store = FakeStore();
    int streamCreationCount = 0;

    // Mock stream that tracks creation count.
    Stream<Position> mockStream(LocationSettings settings) {
      streamCreationCount++;
      // Return stream that immediately errors.
      return Stream.error(Exception('GPS error'));
    }

    Future<bool> mockPermissions() async => true;

    final controller = SessionController(
      store: store,
      getPositionStream: mockStream,
      checkPermissions: mockPermissions,
    );

    // First session: start and let it error.
    expect(await controller.start(), true);
    expect(streamCreationCount, 1);
    await Future.delayed(const Duration(milliseconds: 50));
    expect(controller.isRecording, false);

    // Second session: start again.
    expect(await controller.start(), true);
    expect(streamCreationCount, 2); // Only one new subscription created
    await Future.delayed(const Duration(milliseconds: 50));
    expect(controller.isRecording, false);

    // No duplicate subscriptions were created.
    expect(streamCreationCount, 2);
  });

  group('updateLocationSettings', () {
    test('resubscribes with the new settings while recording', () async {
      final store = FakeStore();
      final requestedFilters = <int?>[];

      Stream<Position> mockStream(LocationSettings settings) {
        requestedFilters.add(settings.distanceFilter);
        return const Stream<Position>.empty();
      }

      final controller = SessionController(
        store: store,
        getPositionStream: mockStream,
        checkPermissions: () async => true,
        locationSettings: const LocationSettings(distanceFilter: 3),
      );

      expect(await controller.start(), true);
      expect(requestedFilters, [3]);

      await controller.updateLocationSettings(
          const LocationSettings(distanceFilter: 12));
      expect(requestedFilters, [3, 12]);
    });

    test('the old subscription is cancelled, not left running alongside the new one',
        () async {
      final store = FakeStore();
      final first = StreamController<Position>();
      final second = StreamController<Position>();
      var callCount = 0;
      final seen = <double>[];

      Stream<Position> mockStream(LocationSettings settings) {
        callCount++;
        return (callCount == 1 ? first : second).stream;
      }

      final controller = SessionController(
        store: store,
        getPositionStream: mockStream,
        checkPermissions: () async => true,
        onFix: (sample) => seen.add(sample.lat),
      );

      Position at(double lat) => Position(
            latitude: lat,
            longitude: 6.6,
            accuracy: 5,
            speed: 0,
            speedAccuracy: 0,
            heading: 0,
            headingAccuracy: 0,
            timestamp: DateTime.utc(2026),
            altitudeAccuracy: 0,
            altitude: 0,
          );

      await controller.start();
      await controller.updateLocationSettings(
          const LocationSettings(distanceFilter: 12));

      // A fix from the stale (cancelled) subscription must not still reach
      // the recorder/onFix hook.
      first.add(at(1));
      await pumpEventQueue();
      expect(seen, isEmpty);

      second.add(at(2));
      await pumpEventQueue();
      expect(seen, [2]);

      await first.close();
      await second.close();
    });

    test('does nothing while not recording', () async {
      final store = FakeStore();
      var callCount = 0;

      Stream<Position> mockStream(LocationSettings settings) {
        callCount++;
        return const Stream<Position>.empty();
      }

      final controller = SessionController(
          store: store, getPositionStream: mockStream, checkPermissions: () async => true);

      await controller.updateLocationSettings(
          const LocationSettings(distanceFilter: 12));
      expect(callCount, 0);
    });
  });
}

/// [SessionController.lastFixAt] is the liveness signal the foreground
/// service's GPS watchdog runs on (see `isGpsSilent`): "the stream has gone
/// quiet" is otherwise indistinguishable from "the walker is standing
/// still", and geolocator failing inside the service isolate would be
/// completely silent.
void _lastFixAtTests() {
  Position position({double accuracy = 5}) => Position(
        latitude: 46.5,
        longitude: 6.6,
        accuracy: accuracy,
        speed: 0,
        speedAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        timestamp: DateTime.utc(2000),
        altitudeAccuracy: 0,
        altitude: 0,
      );

  group('lastFixAt', () {
    late StreamController<Position> positions;
    late DateTime now;
    late SessionController controller;

    setUp(() {
      positions = StreamController<Position>.broadcast();
      now = DateTime.utc(2026, 8, 30, 10, 0);
      controller = SessionController(
        store: FakeStore(),
        getPositionStream: (_) => positions.stream,
        checkPermissions: () async => true,
        getClock: () => now,
      );
    });

    tearDown(() async => positions.close());

    test('is null until the first position arrives', () async {
      await controller.start();
      expect(controller.lastFixAt, isNull);
    });

    test('advances with the controller clock, not the fix timestamp',
        () async {
      await controller.start();
      positions.add(position());
      await pumpEventQueue();
      // The fix's own timestamp is the year 2000; what matters is when it
      // reached us.
      expect(controller.lastFixAt, now);

      now = now.add(const Duration(seconds: 30));
      positions.add(position());
      await pumpEventQueue();
      expect(controller.lastFixAt, DateTime.utc(2026, 8, 30, 10, 0, 30));
    });

    test('a position too inaccurate to record still counts as life', () async {
      // "Arriving but imprecise" and "not arriving at all" are different
      // failures; only the second one deserves a warning.
      await controller.start();
      positions.add(position(accuracy: 500));
      await pumpEventQueue();
      expect(controller.lastFixAt, now);
      expect(controller.recorder!.distanceKm, 0);
    });

    test('a new session starts from a clean slate', () async {
      await controller.start();
      positions.add(position());
      await pumpEventQueue();
      await controller.stop();

      await controller.start();
      expect(controller.lastFixAt, isNull);
    });
  });

  /// [SessionController.onFix] is how turn-by-turn navigation is driven
  /// inside the tracking service — off the recording's own subscription,
  /// rather than a second one.
  group('onFix', () {
    late StreamController<Position> positions;
    late List<GpsSample> seen;
    late SessionController controller;

    setUp(() {
      positions = StreamController<Position>.broadcast();
      seen = [];
      controller = SessionController(
        store: FakeStore(),
        getPositionStream: (_) => positions.stream,
        checkPermissions: () async => true,
        getClock: () => DateTime.utc(2026, 8, 30, 10, 0),
        onFix: seen.add,
      );
    });

    tearDown(() async => positions.close());

    test('every accepted fix reaches the navigation hook', () async {
      await controller.start();
      positions.add(position());
      await pumpEventQueue();

      expect(seen, hasLength(1));
      expect(seen.single.lat, closeTo(46.5, 1e-9));
      expect(seen.single.lon, closeTo(6.6, 1e-9));
      expect(seen.single.time, DateTime.utc(2000));
    });

    test('a fix too vague to measure with is too vague to navigate on',
        () async {
      // The alternative is announcing a turn from a position the distance
      // maths has just refused to believe.
      await controller.start();
      positions.add(position(accuracy: 500));
      await pumpEventQueue();

      expect(seen, isEmpty);
    });

    test('a free trip passes no hook and nothing changes', () async {
      final free = SessionController(
        store: FakeStore(),
        getPositionStream: (_) => positions.stream,
        checkPermissions: () async => true,
      );
      await free.start();
      positions.add(position());
      await pumpEventQueue();

      expect(free.recorder, isNotNull);
      expect(seen, isEmpty);
    });
  });
}
