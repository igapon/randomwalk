import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/tracking/permissions.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/tracking/trip_snapshot.dart';
import 'package:randomwalk/trip/trip_controller.dart';
import 'package:randomwalk/valhalla/models.dart';

import '../support/trip_fakes.dart';

void main() {
  late FakeTripTracker tracker;
  late MemoryRouteStore routes;
  late FakeTotalDistanceStore totals;
  late FakeStepSensor sensor;
  late TripPermissions permissions;
  late int permissionCalls;
  late DateTime now;

  TripController build({
    Future<void> Function(RoutingProfile)? persistProfile,
    Future<RoutingProfile?> Function()? loadProfile,
    void Function(bool)? onCameraFollowChanged,
    Future<TrackingMode> Function()? readTrackingMode,
  }) =>
      TripController(
        tracker: tracker,
        routeStore: routes,
        totalStore: totals,
        ensurePermissions: () async {
          permissionCalls++;
          return permissions;
        },
        createStepCounter: (seed) => SessionStepCounter(sensor, seed: seed),
        readTrackingMode: readTrackingMode,
        clock: () => now,
        persistProfile: persistProfile ?? (_) async {},
        loadProfile: loadProfile ?? () async => null,
        onCameraFollowChanged: onCameraFollowChanged,
      );

  setUp(() {
    tracker = FakeTripTracker();
    routes = MemoryRouteStore();
    totals = FakeTotalDistanceStore();
    sensor = FakeStepSensor();
    permissionCalls = 0;
    permissions = const TripPermissions(
        outcome: TripPermissionOutcome.ready,
        mode: TrackingMode.background,
        stepsAvailable: true);
    now = DateTime.utc(2026, 8, 30, 10, 0, 0);
  });

  TripSnapshot recordingSnapshot({
    double distanceKm = 2.4,
    int steps = 3100,
    bool routeBound = false,
  }) =>
      TripSnapshot(
        status: TripStatus.recording,
        distanceKm: distanceKm,
        steps: steps,
        startedAt: DateTime.utc(2026, 8, 30, 9, 30, 0),
        updatedAt: DateTime.utc(2026, 8, 30, 9, 58, 0),
        profile: RoutingProfile.walk,
        routeBound: routeBound,
      );

  group('cold-start restore', () {
    test('nothing persisted leaves the app idle', () async {
      final trip = build();
      await trip.restore();
      expect(trip.state, TripState.idle);
      expect(trip.activeRoute, isNull);
    });

    test('the planned route comes back even with no trip running', () async {
      routes.current = fakeActiveRoute();
      final trip = build();
      await trip.restore();
      expect(trip.state, TripState.idle);
      expect(trip.activeRoute, isNotNull);
      expect(trip.route!.distanceKm, closeTo(1.2, 1e-9));
    });

    test('a live service is adopted as a recording trip', () async {
      tracker
        ..persisted = recordingSnapshot()
        ..running = true;
      final trip = build();
      await trip.restore();

      expect(trip.state, TripState.recording);
      expect(trip.distanceKm, closeTo(2.4, 1e-9));
      expect(trip.steps, 3100);
    });

    test('a recording snapshot with no service means the process was killed',
        () async {
      tracker
        ..persisted = recordingSnapshot()
        ..running = false;
      final trip = build();
      await trip.restore();

      expect(trip.state, TripState.interrupted);
      expect(trip.distanceKm, closeTo(2.4, 1e-9));
      expect(trip.steps, 3100);
    });

    test('a stale idle snapshot is cleared rather than shown', () async {
      tracker.persisted = recordingSnapshot().copyWith(status: TripStatus.idle);
      final trip = build();
      await trip.restore();
      expect(trip.state, TripState.idle);
      expect(tracker.clears, 1);
    });

    test('restoring a route-bound trip turns camera follow back on', () async {
      bool? follow;
      tracker
        ..persisted = recordingSnapshot(routeBound: true)
        ..running = true;
      final trip = build(onCameraFollowChanged: (v) => follow = v);
      await trip.restore();
      expect(follow, true);
    });
  });

  group('starting a trip', () {
    test('idle -> recording, remembering the chosen profile', () async {
      final saved = <RoutingProfile>[];
      final trip = build(persistProfile: (p) async => saved.add(p));

      expect(await trip.startTrip(profile: RoutingProfile.bike), isTrue);
      expect(trip.state, TripState.recording);
      expect(trip.profile, RoutingProfile.bike);
      expect(saved, [RoutingProfile.bike]);
      expect(tracker.startedWith.single.distanceKm, 0);
      expect(tracker.startedWith.single.startedAt, now);
    });

    test('falls back to the last remembered profile', () async {
      final trip = build(loadProfile: () async => RoutingProfile.bike);
      await trip.startTrip();
      expect(trip.profile, RoutingProfile.bike);
    });

    test('a planned route makes the trip route-bound and follows the camera',
        () async {
      bool? follow;
      final trip = build(onCameraFollowChanged: (v) => follow = v);
      await trip.saveActiveRoute(fakeActiveRoute());

      expect(await trip.startTrip(route: fakeRoute()), isTrue);
      expect(trip.isRouteBound, isTrue);
      expect(tracker.startedWith.single.routeBound, isTrue);
      expect(follow, isTrue);
    });

    test('a free trip is not route-bound', () async {
      final trip = build();
      await trip.startTrip();
      expect(trip.isRouteBound, isFalse);
      expect(tracker.startedWith.single.routeBound, isFalse);
    });

    test('double start is ignored', () async {
      final trip = build();
      expect(await trip.startTrip(), isTrue);
      expect(await trip.startTrip(), isFalse);
      expect(tracker.startedWith, hasLength(1));
    });

    test('refused location blocks the trip and is reported', () async {
      permissions =
          const TripPermissions(outcome: TripPermissionOutcome.locationDenied);
      final trip = build();

      expect(await trip.startTrip(), isFalse);
      expect(trip.state, TripState.idle);
      expect(trip.lastOutcome, TripPermissionOutcome.locationDenied);
      expect(tracker.startedWith, isEmpty);
    });

    test('being sent to the settings screen does not start the service',
        () async {
      permissions =
          const TripPermissions(outcome: TripPermissionOutcome.openedSettings);
      final trip = build();

      expect(await trip.startTrip(), isFalse);
      expect(trip.lastOutcome, TripPermissionOutcome.openedSettings);
      expect(tracker.startedWith, isEmpty);
    });

    test('a refused "allow all the time" still records, degraded', () async {
      permissions = const TripPermissions(
          outcome: TripPermissionOutcome.ready,
          mode: TrackingMode.foregroundOnly,
          stepsAvailable: false);
      final trip = build();

      expect(await trip.startTrip(), isTrue);
      expect(trip.trackingMode, TrackingMode.foregroundOnly);
      expect(trip.state, TripState.recording);
    });

    test('a service that refuses to start leaves the app idle', () async {
      tracker.startSucceeds = false;
      final trip = build();
      expect(await trip.startTrip(), isFalse);
      expect(trip.state, TripState.idle);
    });

    test('permissions are asked once per start, not per rebuild', () async {
      final trip = build();
      await trip.startTrip();
      await trip.startTrip();
      expect(permissionCalls, 1);
    });
  });

  group('live progress', () {
    test('a snapshot from the service updates the visible distance', () async {
      final trip = build();
      await trip.startTrip();
      var notifications = 0;
      trip.addListener(() => notifications++);

      tracker.emit(recordingSnapshot(distanceKm: 3.5, steps: 4200));
      await pumpEventQueue();

      expect(trip.distanceKm, closeTo(3.5, 1e-9));
      expect(trip.steps, 4200);
      expect(notifications, greaterThan(0));
    });

    test('elapsed counts from the trip start, not from the last update',
        () async {
      final trip = build();
      await trip.startTrip();
      now = now.add(const Duration(minutes: 32));
      expect(trip.elapsed, const Duration(minutes: 32));
    });

    test('elapsed is zero when idle', () {
      expect(build().elapsed, Duration.zero);
    });

    test('a tick samples the step sensor and publishes it to the service',
        () async {
      sensor.value = 1000;
      final trip = build();
      await trip.startTrip();

      sensor.value = 1120;
      await trip.tick();

      expect(trip.steps, 120);
      expect(tracker.publishedSteps.last, 120);
    });

    test('ticking while idle is a no-op', () async {
      final trip = build();
      await trip.tick();
      expect(tracker.publishedSteps, isEmpty);
    });

    test('a GPS stream failure reaches the shell', () async {
      final trip = build();
      String? reported;
      trip.onSessionError = (m) async => reported = m;
      await trip.startTrip();

      tracker.emitError('stream closed');
      await pumpEventQueue();

      expect(reported, 'stream closed');
    });

    test('granting "allow all the time" later clears the degraded mode',
        () async {
      permissions = const TripPermissions(
          outcome: TripPermissionOutcome.ready,
          mode: TrackingMode.foregroundOnly);
      var mode = TrackingMode.foregroundOnly;
      final trip = build(readTrackingMode: () async => mode);
      await trip.startTrip();
      expect(trip.trackingMode, TrackingMode.foregroundOnly);

      mode = TrackingMode.background;
      await trip.refreshTrackingMode();
      expect(trip.trackingMode, TrackingMode.background);
    });

    test('the walk-plausibility flag is surfaced', () async {
      final trip = build();
      await trip.startTrip();
      tracker.emit(recordingSnapshot(distanceKm: 4, steps: 5));
      await pumpEventQueue();
      expect(trip.needsReview, isTrue);
    });
  });

  group('stopping a trip', () {
    test('banks the distance, submits the cumulative total, goes idle',
        () async {
      double? submitted;
      final trip = build()..onSessionEnded = (t) async => submitted = t;
      totals.total = 10;
      await trip.startTrip();
      tracker.emit(recordingSnapshot(distanceKm: 2.4));

      final distance = await trip.stopTrip();

      expect(distance, closeTo(2.4, 1e-9));
      expect(totals.total, closeTo(12.4, 1e-9));
      expect(submitted, closeTo(12.4, 1e-9));
      expect(trip.state, TripState.idle);
      expect(tracker.stops, 1);
      expect(tracker.clears, greaterThan(0));
    });

    test('releases camera follow', () async {
      bool? follow;
      final trip = build(onCameraFollowChanged: (v) => follow = v);
      await trip.startTrip(route: fakeRoute());
      await trip.stopTrip();
      expect(follow, isFalse);
      expect(trip.isRouteBound, isFalse);
    });

    test('keeps the planned route on screen after the trip ends', () async {
      final trip = build();
      await trip.saveActiveRoute(fakeActiveRoute());
      await trip.startTrip(route: fakeRoute());
      await trip.stopTrip();
      expect(trip.activeRoute, isNotNull);
    });

    test('prefers the freshest of the live and persisted snapshots', () async {
      final trip = build();
      await trip.startTrip();

      // The service published 2.4 km, then died before persisting 3.9 km.
      tracker.emit(recordingSnapshot(distanceKm: 2.4)
          .copyWith(updatedAt: DateTime.utc(2026, 8, 30, 10, 5)));
      tracker.persisted = recordingSnapshot(distanceKm: 1.0)
          .copyWith(updatedAt: DateTime.utc(2026, 8, 30, 10, 1));
      await pumpEventQueue();

      expect(await trip.stopTrip(), closeTo(2.4, 1e-9));
    });

    test('stopping when idle is a no-op', () async {
      final trip = build();
      expect(await trip.stopTrip(), 0);
      expect(trip.state, TripState.idle);
      expect(tracker.stops, 0);
    });
  });

  group('interrupted trip', () {
    setUp(() {
      tracker
        ..persisted = recordingSnapshot(distanceKm: 2.4, steps: 3100)
        ..running = false;
    });

    test('"Reprendre" keeps the accumulated distance and steps', () async {
      final trip = build();
      await trip.restore();

      expect(await trip.resumeInterrupted(), isTrue);
      expect(trip.state, TripState.recording);

      final seed = tracker.startedWith.single;
      expect(seed.distanceKm, closeTo(2.4, 1e-9));
      expect(seed.steps, 3100);
    });

    test('"Reprendre" keeps the original start time, so elapsed is continuous',
        () async {
      final trip = build();
      await trip.restore();
      await trip.resumeInterrupted();

      expect(tracker.startedWith.single.startedAt,
          DateTime.utc(2026, 8, 30, 9, 30, 0));
      expect(trip.elapsed, const Duration(minutes: 30));
    });

    test('"Reprendre" keeps counting steps on from the saved total', () async {
      sensor.value = 50000;
      final trip = build();
      await trip.restore();
      await trip.resumeInterrupted();

      sensor.value = 50100;
      await trip.tick();
      expect(trip.steps, 3200);
    });

    test('"Terminer" finalises through the normal path', () async {
      double? submitted;
      totals.total = 10;
      final trip = build()..onSessionEnded = (t) async => submitted = t;
      await trip.restore();

      final distance = await trip.finishInterrupted();

      expect(distance, closeTo(2.4, 1e-9));
      expect(totals.total, closeTo(12.4, 1e-9));
      expect(submitted, closeTo(12.4, 1e-9));
      expect(trip.state, TripState.idle);
      expect(tracker.clears, greaterThan(0));
    });

    test('"Reprendre" re-checks permissions before restarting the service',
        () async {
      permissions =
          const TripPermissions(outcome: TripPermissionOutcome.locationDenied);
      final trip = build();
      await trip.restore();

      expect(await trip.resumeInterrupted(), isFalse);
      expect(trip.state, TripState.interrupted);
      expect(tracker.startedWith, isEmpty);
    });

    test('resuming when nothing was interrupted is a no-op', () async {
      tracker.persisted = null;
      final trip = build();
      await trip.restore();
      expect(await trip.resumeInterrupted(), isFalse);
    });
  });

  group('planned route state', () {
    test('saving a route persists it and notifies', () async {
      final trip = build();
      var notified = 0;
      trip.addListener(() => notified++);

      await trip.saveActiveRoute(fakeActiveRoute());

      expect(routes.current, isNotNull);
      expect(trip.activeRoute!.destination, const (46.51, 6.61));
      expect(notified, 1);
    });

    test('clearing a route removes it from disk too', () async {
      final trip = build();
      await trip.saveActiveRoute(fakeActiveRoute());
      await trip.clearActiveRoute();
      expect(trip.activeRoute, isNull);
      expect(routes.current, isNull);
    });

    test('the profile is part of the persisted planning state', () async {
      final trip = build();
      await trip.saveActiveRoute(fakeActiveRoute());
      await trip.setProfile(RoutingProfile.bike);
      expect(trip.profile, RoutingProfile.bike);
      expect(routes.current!.profile, RoutingProfile.bike);
    });

    test('setting the profile without a planned route still remembers it',
        () async {
      final saved = <RoutingProfile>[];
      final trip = build(persistProfile: (p) async => saved.add(p));
      await trip.setProfile(RoutingProfile.bike);
      expect(trip.profile, RoutingProfile.bike);
      expect(saved, [RoutingProfile.bike]);
      expect(routes.current, isNull);
    });
  });
}
