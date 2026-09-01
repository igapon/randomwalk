import 'dart:async';

import 'package:randomwalk/loop/speed_history.dart';
import 'package:randomwalk/session/recorder.dart';
import 'package:randomwalk/tracking/nav_seed.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/tracking/tracking_service.dart';
import 'package:randomwalk/tracking/trip_snapshot.dart';
import 'package:randomwalk/trip/active_route_store.dart';
import 'package:randomwalk/trip/finalised_trip_memory.dart';
import 'package:randomwalk/valhalla/models.dart';

/// Fakes shared by the trip controller's own tests and by any widget test
/// that has to stand up a [TripController] (the real one is built in
/// `main()` against the app support directory and a foreground service).
class FakeTotalDistanceStore implements TotalDistanceStore {
  double total = 0;

  /// How many times [addAndGetTotalKm] has actually run — a double-banked
  /// trip (see the trip_controller `stopTrip` re-entrancy test) shows up as
  /// this being 2 for what should be a single stop.
  int calls = 0;

  @override
  Future<double> totalKm() async => total;
  @override
  Future<double> addAndGetTotalKm(double km) async {
    calls++;
    return total += km;
  }
}

/// In-memory [FinalisedTripMemory]: remembers which trips have already been
/// banked, so a snapshot resurrected by a late write cannot be banked twice.
class MemoryFinalisedTripMemory implements FinalisedTripMemory {
  final banked = <DateTime>{};

  @override
  Future<bool> wasFinalised(DateTime startedAt) async =>
      banked.contains(startedAt.toUtc());

  @override
  Future<void> markFinalised(DateTime startedAt) async =>
      banked.add(startedAt.toUtc());
}

/// Records every [recordSession] call this fake has seen — unconditionally,
/// unlike the real store, which silently drops short or implausible
/// sessions. That filtering is the real [SpeedHistoryStore]'s job and is
/// covered by its own tests; a controller test that needs to see a session
/// actually get ignored should use a real store (see trip_controller_test's
/// "speed history" group) rather than duplicate the threshold policy here.
class FakeSpeedHistoryStore implements SpeedHistoryStore {
  final calls = <(RoutingProfile, double, Duration)>[];

  @override
  Future<void> recordSession(
    RoutingProfile profile,
    double sessionKm,
    Duration elapsed,
  ) async {
    calls.add((profile, sessionKm, elapsed));
  }

  @override
  Future<double> speedKmh(RoutingProfile profile) async =>
      profile == RoutingProfile.walk ? 4.5 : 16.0;
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
///
/// Models *attachment* faithfully, which the first version did not: the real
/// tracker only receives live snapshots once it has registered a task-data
/// callback, so a fake whose `updates` stream is always live hides the whole
/// class of "the UI reattached to a running service and never heard from it
/// again" bugs.
class FakeTripTracker implements TripTracker {
  TripSnapshot? persisted;
  bool running = false;
  bool startSucceeds = true;
  bool attached = false;
  final startedWith = <TripSnapshot>[];

  /// The navigation handover each start was given, positionally matching
  /// [startedWith] — null for a free trip.
  final startedNav = <NavSeed?>[];

  /// The `poisFilePath` each start was given (M4 Task 5), positionally
  /// matching [startedWith].
  final startedPoisFilePath = <String?>[];
  final publishedSteps = <int>[];
  int stops = 0;
  int clears = 0;
  int attaches = 0;
  final _updates = StreamController<TripSnapshot>.broadcast();
  final _errors = StreamController<String?>.broadcast();

  void emitError(String message) => _errors.add(message);

  /// The service publishing progress: it always lands on disk, but only
  /// reaches the UI's stream while the UI is attached.
  void emit(TripSnapshot snapshot) {
    persisted = snapshot;
    if (attached) _updates.add(snapshot);
  }

  @override
  Future<void> attach() async {
    attaches++;
    attached = true;
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
  Future<bool> start(
    TripSnapshot seed, {
    NavSeed? nav,
    String? poisFilePath,
  }) async {
    if (!startSucceeds) return false;
    startedWith.add(seed);
    startedNav.add(nav);
    startedPoisFilePath.add(poisFilePath);
    persisted = seed;
    running = true;
    attached = true;
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

  /// Every [TripTracker.updateAlertSettings] call this fake has seen, in
  /// order.
  final alertSettingsUpdates = <({bool ttsEnabled, bool hapticsEnabled})>[];

  @override
  Future<void> updateAlertSettings({
    required bool ttsEnabled,
    required bool hapticsEnabled,
  }) async => alertSettingsUpdates.add((
    ttsEnabled: ttsEnabled,
    hapticsEnabled: hapticsEnabled,
  ));

  @override
  Future<void> dispose() async {
    attached = false;
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
  maneuvers: [],
);

ActiveRoute fakeActiveRoute() => ActiveRoute(
  route: fakeRoute(),
  destination: const (46.51, 6.61),
  profile: RoutingProfile.walk,
);
