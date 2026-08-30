import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:randomwalk/session/recorder.dart';
import 'package:randomwalk/session/session_controller.dart';
import 'package:randomwalk/trip/trip_controller.dart';
import 'package:randomwalk/valhalla/models.dart';

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

/// Builds a real [SessionController] (it is already unit-testable via its
/// own injectable deps — see session_controller_test.dart) wired to a mock
/// position stream that never emits, so sessions stay "recording" until
/// explicitly stopped.
SessionController _fakeSessionController({
  TotalDistanceStore? store,
  Future<void> Function(double totalKm)? onSessionEnded,
}) {
  Stream<Position> mockStream(LocationSettings settings) =>
      StreamController<Position>().stream;
  Future<bool> mockPermissions() async => true;
  return SessionController(
    store: store ?? FakeStore(),
    getPositionStream: mockStream,
    checkPermissions: mockPermissions,
    onSessionEnded: onSessionEnded,
  );
}

RouteResult _fakeRoute() => const RouteResult(
    shape: [(46.5, 6.6), (46.51, 6.61)],
    distanceKm: 1.2,
    duration: Duration(minutes: 15),
    maneuvers: []);

/// Builds a [TripController] with no-op profile persistence by default, so
/// tests that don't care about it never touch the real shared_preferences
/// plugin (which needs a widget binding).
TripController _fakeTrip(
  SessionController session, {
  void Function(bool follow)? onCameraFollowChanged,
  Future<void> Function(RoutingProfile profile)? persistProfile,
  Future<RoutingProfile?> Function()? loadProfile,
}) =>
    TripController(
      session,
      onCameraFollowChanged: onCameraFollowChanged,
      persistProfile: persistProfile ?? (_) async {},
      loadProfile: loadProfile ?? () async => null,
    );

void main() {
  test('idle -> recording without a route, remembering the chosen profile', () async {
    final saved = <String, RoutingProfile>{};
    final trip = TripController(
      _fakeSessionController(),
      persistProfile: (p) async => saved['trip_profile'] = p,
      loadProfile: () async => saved['trip_profile'],
    );

    expect(trip.state, TripState.idle);
    final started = await trip.startTrip(profile: RoutingProfile.bike);
    expect(started, true);
    expect(trip.state, TripState.recording);
    expect(trip.isRouteBound, false);
    expect(trip.profile, RoutingProfile.bike);
    expect(saved['trip_profile'], RoutingProfile.bike);
  });

  test('startTrip loads the last remembered profile when none is given', () async {
    final trip = TripController(
      _fakeSessionController(),
      loadProfile: () async => RoutingProfile.bike,
    );

    await trip.startTrip();
    expect(trip.profile, RoutingProfile.bike);
  });

  test('startTrip with a planned route is route-bound and enables camera follow', () async {
    bool? followState;
    final trip = _fakeTrip(
      _fakeSessionController(),
      onCameraFollowChanged: (on) => followState = on,
    );

    final route = _fakeRoute();
    final started = await trip.startTrip(route: route);
    expect(started, true);
    expect(trip.state, TripState.recording);
    expect(trip.isRouteBound, true);
    expect(trip.route, same(route));
    expect(followState, true);
  });

  test('startTrip without a route is not route-bound and leaves camera follow off', () async {
    bool? followState;
    final trip = _fakeTrip(
      _fakeSessionController(),
      onCameraFollowChanged: (on) => followState = on,
    );

    await trip.startTrip();
    expect(trip.isRouteBound, false);
    expect(trip.route, isNull);
    expect(followState, isNot(true));
  });

  test('double start is ignored', () async {
    final trip = _fakeTrip(_fakeSessionController());
    expect(await trip.startTrip(), true);
    expect(await trip.startTrip(), false);
    expect(trip.state, TripState.recording);
  });

  test('stopTrip finishes the session, releases camera follow, returns to idle', () async {
    bool? followState;
    final session = _fakeSessionController();
    final trip = _fakeTrip(session, onCameraFollowChanged: (on) => followState = on);

    await trip.startTrip(route: _fakeRoute());
    final distance = await trip.stopTrip();

    expect(distance, isA<double>());
    expect(trip.state, TripState.idle);
    expect(trip.isRouteBound, false);
    expect(trip.route, isNull);
    expect(followState, false);
    expect(session.isRecording, false);
  });

  test('stopTrip when idle is a no-op', () async {
    final trip = _fakeTrip(_fakeSessionController());
    final distance = await trip.stopTrip();
    expect(distance, 0);
    expect(trip.state, TripState.idle);
  });

  test('stop finishes via the same SessionController path used by leaderboard submit', () async {
    double? endedTotal;
    final store = FakeStore();
    final session = _fakeSessionController(store: store, onSessionEnded: (totalKm) async {
      endedTotal = totalKm;
    });
    final trip = _fakeTrip(session);

    await trip.startTrip();
    await trip.stopTrip();

    expect(endedTotal, isNotNull);
    expect(endedTotal, store._total);
  });
}
