import 'dart:async';

import 'package:randomwalk/session/recorder.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/tracking/tracking_service.dart';
import 'package:randomwalk/tracking/trip_snapshot.dart';
import 'package:randomwalk/trip/active_route_store.dart';
import 'package:randomwalk/valhalla/models.dart';

/// Fakes shared by the trip controller's own tests and by any widget test
/// that has to stand up a [TripController] (the real one is built in
/// `main()` against the app support directory and a foreground service).
class FakeTotalDistanceStore implements TotalDistanceStore {
  double total = 0;
  @override
  Future<double> totalKm() async => total;
  @override
  Future<double> addAndGetTotalKm(double km) async => total += km;
}

class MemoryRouteStore implements ActiveRouteStore {
  ActiveRoute? current;
  int saves = 0;

  @override
  Future<ActiveRoute?> load() async => current;

  @override
  Future<void> save(ActiveRoute route) async {
    current = route;
    saves++;
  }

  @override
  Future<void> clear() async => current = null;
}

/// Stands in for the foreground service: everything the real tracker does
/// asynchronously across an isolate boundary, done synchronously here.
class FakeTripTracker implements TripTracker {
  TripSnapshot? persisted;
  bool running = false;
  bool startSucceeds = true;
  final startedWith = <TripSnapshot>[];
  final publishedSteps = <int>[];
  int stops = 0;
  int clears = 0;
  final _updates = StreamController<TripSnapshot>.broadcast();
  final _errors = StreamController<String?>.broadcast();

  void emitError(String message) => _errors.add(message);

  void emit(TripSnapshot snapshot) {
    persisted = snapshot;
    _updates.add(snapshot);
  }

  @override
  Stream<TripSnapshot> get updates => _updates.stream;

  @override
  Stream<String?> get errors => _errors.stream;

  @override
  Future<bool> isRunning() async => running;

  @override
  Future<TripSnapshot?> readSnapshot() async => persisted;

  @override
  Future<void> clearSnapshot() async {
    clears++;
    persisted = null;
  }

  @override
  Future<bool> start(TripSnapshot seed) async {
    if (!startSucceeds) return false;
    startedWith.add(seed);
    persisted = seed;
    running = true;
    return true;
  }

  @override
  Future<TripSnapshot?> stop() async {
    stops++;
    running = false;
    return persisted;
  }

  @override
  Future<void> publishSteps(int steps) async => publishedSteps.add(steps);

  @override
  Future<void> dispose() async {
    await _updates.close();
    await _errors.close();
  }
}

class FakeStepSensor implements StepSensor {
  FakeStepSensor({this.available = true, this.value = 0});
  bool available;
  int value;

  @override
  Future<bool> start() async => available;

  @override
  Future<int?> read() async => available ? value : null;

  @override
  Future<void> stop() async {}
}

RouteResult fakeRoute() => const RouteResult(
    shape: [(46.5, 6.6), (46.51, 6.61)],
    distanceKm: 1.2,
    duration: Duration(minutes: 15),
    maneuvers: []);

ActiveRoute fakeActiveRoute() => ActiveRoute(
    route: fakeRoute(),
    destination: const (46.51, 6.61),
    profile: RoutingProfile.walk);
