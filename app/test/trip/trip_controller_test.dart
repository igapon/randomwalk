import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/exploration/exploration_recorder.dart';
import 'package:randomwalk/loop/speed_history.dart';
import 'package:randomwalk/nav/nav_fields.dart';
import 'package:randomwalk/tracking/permissions.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/tracking/trip_snapshot.dart'
    show TripSnapshot, TripStatus, PendingVisit;
import 'package:randomwalk/trip/trip_controller.dart';
import 'package:randomwalk/trip/trip_messages.dart';
import 'package:randomwalk/valhalla/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/trip_fakes.dart';

/// A [SpeedHistoryStore] whose [recordSession] always throws — task-7 review
/// carry-over item 11: `recordSession`'s own doc comment promises the trip
/// controller it never breaks a trip, but nothing enforced that until
/// `_finalise` actually wrapped the call. A platform-channel-style throw
/// here (SharedPreferences, in production) must not leave `_finalise` stuck
/// mid-state — banking and marking-finalised must already have run, and the
/// trip must still reach idle with its snapshot cleared.
class ThrowingSpeedHistoryStore implements SpeedHistoryStore {
  @override
  Future<void> recordSession(
      RoutingProfile profile, double sessionKm, Duration elapsed) async {
    throw StateError('boom');
  }

  @override
  Future<double> speedKmh(RoutingProfile profile) async => 4.5;
}

void main() {
  late FakeTripTracker tracker;
  late MemoryRouteStore routes;
  late FakeTotalDistanceStore totals;
  late FakeStepSensor sensor;
  late MemoryFinalisedTripMemory banked;
  late FakeSpeedHistoryStore speedHistory;
  late TripPermissions permissions;
  late int permissionCalls;
  late DateTime now;

  TripController build({
    Future<void> Function(RoutingProfile)? persistProfile,
    Future<RoutingProfile?> Function()? loadProfile,
    void Function(bool)? onCameraFollowChanged,
    Future<TrackingMode> Function()? readTrackingMode,
    SpeedHistoryStore? speedHistoryOverride,
    Future<void> Function(FinishedTrip trip)? processTripExploration,
    Future<String?> Function()? resolvePoisFile,
    Future<void> Function(List<PendingVisit> visits)? processGameVisits,
  }) =>
      TripController(
        tracker: tracker,
        routeStore: routes,
        totalStore: totals,
        finalisedTrips: banked,
        speedHistory: speedHistoryOverride ?? speedHistory,
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
        processTripExploration: processTripExploration,
        resolvePoisFile: resolvePoisFile,
        processGameVisits: processGameVisits,
      );

  setUp(() {
    tracker = FakeTripTracker();
    routes = MemoryRouteStore();
    totals = FakeTotalDistanceStore();
    sensor = FakeStepSensor();
    banked = MemoryFinalisedTripMemory();
    speedHistory = FakeSpeedHistoryStore();
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

    test('adopting a live service reattaches to its live updates', () async {
      tracker
        ..persisted = recordingSnapshot()
        ..running = true;
      final trip = build();
      await trip.restore();

      // The service is running and the UI has just come back to it. Without
      // an explicit reattach the plugin's task-data callback is never
      // registered, and the distance sits frozen at its cold-start value for
      // the rest of the trip - silently, because the total banked at stop
      // still comes from the snapshot file.
      tracker.emit(recordingSnapshot(distanceKm: 5.1));
      await pumpEventQueue();

      expect(trip.distanceKm, closeTo(5.1, 1e-9));
    });

    test('adopting an already-silent service shows the warning at once',
        () async {
      // The UI process died and came back mid-trip. The service went quiet
      // while nothing was listening, so there is no transition left to
      // observe — which is exactly the geolocator-in-isolate case the
      // watchdog exists for, and the case a transition-only side channel
      // could never report.
      tracker
        ..persisted = recordingSnapshot().copyWith(gpsSilent: true)
        ..running = true;
      final trip = build();
      await trip.restore();

      expect(trip.isRecording, isTrue);
      expect(trip.gpsSilent, isTrue);
    });

    test('an interrupted trip is not reported as a silent GPS', () async {
      // Nothing is recording, so there is nothing to warn about; the
      // « Trajet interrompu » banner is the whole message.
      tracker
        ..persisted = recordingSnapshot().copyWith(gpsSilent: true)
        ..running = false;
      final trip = build();
      await trip.restore();

      expect(trip.gpsSilent, isFalse);
    });

    test('an interrupted trip does not reattach to anything', () async {
      tracker
        ..persisted = recordingSnapshot()
        ..running = false;
      final trip = build();
      await trip.restore();
      expect(tracker.attaches, 0);
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

    test('double start is ignored, and says why', () async {
      final trip = build();
      expect(await trip.startTrip(), isTrue);
      expect(await trip.startTrip(), isFalse);
      expect(tracker.startedWith, hasLength(1));
      expect(trip.lastStartFailure, TripStartFailure.alreadyRecording);
      expect(startFailureMessage(trip.lastStartFailure),
          contains('déjà en cours'));
    });

    test('refused location blocks the trip and is reported', () async {
      permissions =
          const TripPermissions(outcome: TripPermissionOutcome.locationDenied);
      final trip = build();

      expect(await trip.startTrip(), isFalse);
      expect(trip.state, TripState.idle);
      expect(trip.lastStartFailure, TripStartFailure.locationDenied);
      expect(tracker.startedWith, isEmpty);
    });

    test('being sent to the settings screen does not start the service',
        () async {
      permissions =
          const TripPermissions(outcome: TripPermissionOutcome.openedSettings);
      final trip = build();

      expect(await trip.startTrip(), isFalse);
      expect(trip.lastStartFailure, TripStartFailure.openedSettings);
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

    test('a refused step permission means no sensor is started', () async {
      permissions = const TripPermissions(
          outcome: TripPermissionOutcome.ready,
          mode: TrackingMode.background,
          stepsAvailable: false);
      sensor.value = 1000;
      final trip = build();
      await trip.startTrip();

      sensor.value = 1200;
      await trip.tick();

      expect(trip.stepsAvailable, isFalse);
      expect(trip.steps, 0);
      expect(tracker.publishedSteps, isEmpty);
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

    test('a tick picks up service progress even while detached', () async {
      final trip = build();
      await trip.startTrip();
      tracker.attached = false;

      // The live channel is the fast path, never the only one: the plugin's
      // data port can be down (a reattach, a dropped callback) while the
      // service keeps writing perfectly good snapshots to disk.
      tracker.persisted = recordingSnapshot(distanceKm: 3.9)
          .copyWith(updatedAt: DateTime.utc(2026, 8, 30, 10, 30));
      await trip.tick();

      expect(trip.distanceKm, closeTo(3.9, 1e-9));
    });

    test('a tick never rewinds to a staler snapshot than the live one',
        () async {
      final trip = build();
      await trip.startTrip();
      tracker.emit(recordingSnapshot(distanceKm: 4.0)
          .copyWith(updatedAt: DateTime.utc(2026, 8, 30, 10, 30)));
      await pumpEventQueue();

      tracker.persisted = recordingSnapshot(distanceKm: 1.0)
          .copyWith(updatedAt: DateTime.utc(2026, 8, 30, 10, 10));
      await trip.tick();

      expect(trip.distanceKm, closeTo(4.0, 1e-9));
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

    test('a silent GPS is surfaced to the shell', () async {
      final trip = build();
      await trip.startTrip();
      expect(trip.gpsSilent, isFalse);

      tracker.emit(recordingSnapshot().copyWith(gpsSilent: true));
      await pumpEventQueue();
      expect(trip.gpsSilent, isTrue);

      tracker.emit(recordingSnapshot().copyWith(gpsSilent: false));
      await pumpEventQueue();
      expect(trip.gpsSilent, isFalse);
    });

    test('a silent GPS reaches a detached UI through the poll fallback',
        () async {
      final trip = build();
      await trip.startTrip();
      tracker.attached = false;

      tracker.persisted = recordingSnapshot()
          .copyWith(gpsSilent: true, updatedAt: DateTime.utc(2026, 8, 30, 10, 30));
      await trip.tick();

      expect(trip.gpsSilent, isTrue);
    });

    test('stopping a trip clears the silent-GPS warning', () async {
      final trip = build();
      await trip.startTrip();
      tracker.emit(recordingSnapshot().copyWith(gpsSilent: true));
      await pumpEventQueue();

      await trip.stopTrip();
      expect(trip.gpsSilent, isFalse);
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

    test('a snapshot resurrected after the stop is not banked twice',
        () async {
      totals.total = 10;
      final trip = build();
      await trip.startTrip();
      tracker.emit(recordingSnapshot(distanceKm: 2.4));
      await trip.stopTrip();
      expect(totals.total, closeTo(12.4, 1e-9));

      // stopService() returns before the service isolate's onDestroy has
      // necessarily flushed, so its final write can land *after* we cleared
      // the file - resurrecting a `recording` snapshot for a trip that has
      // already been banked and submitted.
      tracker.persisted = recordingSnapshot(distanceKm: 2.4);

      final next = build();
      await next.restore();

      expect(next.state, TripState.idle);
      expect(totals.total, closeTo(12.4, 1e-9));
    });

    test('a genuinely different trip is still offered after a finalised one',
        () async {
      final trip = build();
      await trip.startTrip();
      tracker.emit(recordingSnapshot(distanceKm: 2.4));
      await trip.stopTrip();

      // A different trip: its start time is its identity.
      tracker.persisted = TripSnapshot(
        status: TripStatus.recording,
        distanceKm: 1.1,
        steps: 900,
        startedAt: DateTime.utc(2026, 8, 30, 11, 0),
        updatedAt: DateTime.utc(2026, 8, 30, 11, 12),
        profile: RoutingProfile.walk,
        routeBound: false,
      );

      final next = build();
      await next.restore();
      expect(next.state, TripState.interrupted);
    });

    test(
        'a double-tap on "Terminer" banks the trip exactly once (final '
        'review item 6)', () async {
      totals.total = 10;
      final trip = build();
      await trip.startTrip();
      tracker.emit(recordingSnapshot(distanceKm: 2.4));

      // Two concurrent calls, neither awaited before the other starts — the
      // shape a double-tap actually produces. `stopTrip`'s synchronous
      // prefix (the `_state`/`_stopping` guard, and setting `_stopping`)
      // runs to completion for `first` before `second` is even invoked —
      // Dart only suspends at `first`'s own first `await` — so the second
      // call deterministically sees `_stopping` already true.
      final first = trip.stopTrip();
      final second = trip.stopTrip();

      expect(await second, 0);
      expect(await first, closeTo(2.4, 1e-9));
      expect(totals.calls, 1);
      expect(totals.total, closeTo(12.4, 1e-9));
      expect(trip.state, TripState.idle);
    });

    test('stopping when idle is a no-op', () async {
      final trip = build();
      expect(await trip.stopTrip(), 0);
      expect(trip.state, TripState.idle);
      expect(tracker.stops, 0);
    });
  });

  group('speed history', () {
    test('a plausible stopped trip records its session speed', () async {
      final trip = build();
      await trip.startTrip();
      // recordingSnapshot()'s startedAt (9:30) replaces the seed's on adopt,
      // so against `now` (10:00) this is a 30-minute, 2.4 km walk.
      tracker.emit(recordingSnapshot(distanceKm: 2.4));

      await trip.stopTrip();

      expect(speedHistory.calls, [
        (RoutingProfile.walk, 2.4, const Duration(minutes: 30)),
      ]);
    });

    test('a bike trip records against the bike history, not the walk one',
        () async {
      final trip = build();
      await trip.startTrip(profile: RoutingProfile.bike);
      tracker.emit(TripSnapshot(
        status: TripStatus.recording,
        distanceKm: 8.0,
        steps: 0,
        startedAt: DateTime.utc(2026, 8, 30, 9, 30, 0),
        updatedAt: DateTime.utc(2026, 8, 30, 9, 58, 0),
        profile: RoutingProfile.bike,
        routeBound: false,
      ));

      await trip.stopTrip();

      expect(speedHistory.calls, [
        (RoutingProfile.bike, 8.0, const Duration(minutes: 30)),
      ]);
    });

    test('a session too short to be meaningful does not move the average',
        () async {
      // Real store, not the recording fake: the point is to observe that
      // the session was actually ignored (the EMA is untouched), not just
      // that some call landed — see writing-good-tests on asserting real
      // behaviour rather than mock behaviour.
      SharedPreferences.setMockInitialValues({});
      final realHistory = SpeedHistoryStore();
      final trip = build(speedHistoryOverride: realHistory);
      // No emitted snapshot: the seed's distance (0 km) and elapsed (0
      // minutes, `now` unchanged since start) are both under the ignore
      // thresholds.
      await trip.startTrip();

      await trip.stopTrip();

      expect(
          await realHistory.speedKmh(RoutingProfile.walk), closeTo(4.5, 1e-9));
    });

    test('finishing an interrupted trip also records its session speed',
        () async {
      tracker
        ..persisted = recordingSnapshot(distanceKm: 2.4)
        ..running = false;
      final trip = build();
      await trip.restore();
      expect(trip.state, TripState.interrupted);

      await trip.finishInterrupted();

      expect(speedHistory.calls, [
        (RoutingProfile.walk, 2.4, const Duration(minutes: 30)),
      ]);
    });

    test(
        'a throwing SpeedHistoryStore does not stop the trip from finalising '
        '(review carry-over item 11)', () async {
      totals.total = 10;
      final trip = build(speedHistoryOverride: ThrowingSpeedHistoryStore());
      await trip.startTrip();
      tracker.emit(recordingSnapshot(distanceKm: 2.4));

      final distance = await trip.stopTrip();

      expect(distance, closeTo(2.4, 1e-9));
      // Banking and marking-finalised — both before the throwing call in
      // `_finalise` — must still have run.
      expect(totals.total, closeTo(12.4, 1e-9));
      expect(await banked.wasFinalised(recordingSnapshot().startedAt), isTrue);
      // And the trip must still reach idle with its snapshot cleared, not
      // get stuck mid-`_finalise`.
      expect(trip.state, TripState.idle);
      expect(trip.snapshot, isNull);
      expect(tracker.clears, greaterThan(0));
    });
  });

  group('exploration wiring (M4)', () {
    test('a stopped trip invokes processTripExploration with this trip\'s '
        'own km, isLoop and navArrived', () async {
      final calls = <FinishedTrip>[];
      final trip = build(processTripExploration: (t) async => calls.add(t));
      await trip.saveActiveRoute(fakeActiveRoute().copyWith(isLoop: true));
      await trip.startTrip(route: fakeRoute());
      tracker.emit(recordingSnapshot(distanceKm: 2.4)
          .copyWith(nav: const NavFields(arrived: true)));

      await trip.stopTrip();
      // processTripExploration is fire-and-forget (`unawaited`): give its
      // microtask a turn to run before asserting on it.
      await Future<void>.delayed(Duration.zero);

      expect(calls, hasLength(1));
      expect(calls.single.km, closeTo(2.4, 1e-9));
      expect(calls.single.isLoop, isTrue);
      expect(calls.single.navArrived, isTrue);
    });

    test('a throwing/never-completing exploration hook never delays or '
        'breaks trip finalisation', () async {
      totals.total = 10;
      final trip = build(
          processTripExploration: (t) async =>
              throw StateError('exploration boom'));
      await trip.startTrip();
      tracker.emit(recordingSnapshot(distanceKm: 2.4));

      final distance = await trip.stopTrip();

      // stopTrip() must resolve immediately (fire-and-forget), independent
      // of the hook's own thrown Future ever settling.
      expect(distance, closeTo(2.4, 1e-9));
      expect(totals.total, closeTo(12.4, 1e-9));
      expect(trip.state, TripState.idle);
      expect(trip.snapshot, isNull);
      expect(tracker.clears, greaterThan(0));

      // Let the hook's rejected future actually run/settle (and be caught
      // by TripController's own catchError) so it doesn't leak as an
      // unhandled async error into a later test.
      await Future<void>.delayed(Duration.zero);
    });

    test('no exploration hook configured is a silent no-op', () async {
      final trip = build(); // processTripExploration left null
      await trip.startTrip();
      tracker.emit(recordingSnapshot(distanceKm: 2.4));

      final distance = await trip.stopTrip();

      expect(distance, closeTo(2.4, 1e-9));
      expect(trip.state, TripState.idle);
    });
  });

  group('game visits wiring (M4 Task 5)', () {
    test('startTrip resolves poisFilePath and hands it to tracker.start',
        () async {
      final trip =
          build(resolvePoisFile: () async => '/tiles/v1/pois.json.gz');
      await trip.startTrip();

      expect(tracker.startedPoisFilePath.single, '/tiles/v1/pois.json.gz');
    });

    test('a null/absent resolvePoisFile still starts the trip with a null '
        'poisFilePath', () async {
      final trip = build(); // resolvePoisFile left null.
      expect(await trip.startTrip(), isTrue);
      expect(tracker.startedPoisFilePath.single, isNull);
    });

    test('a throwing resolvePoisFile never stops the trip from starting',
        () async {
      final trip =
          build(resolvePoisFile: () async => throw StateError('disk error'));
      expect(await trip.startTrip(), isTrue);
      expect(tracker.startedPoisFilePath.single, isNull);
    });

    test('a snapshot carrying pendingVisits invokes processGameVisits',
        () async {
      final calls = <List<PendingVisit>>[];
      final trip = build(processGameVisits: (v) async => calls.add(v));
      await trip.startTrip();

      final visit = PendingVisit(
        poiId: 'node/1',
        kind: 'reveal',
        lat: 46.5,
        lon: 6.6,
        ts: now,
      );
      tracker.emit(recordingSnapshot(distanceKm: 1.0)
          .copyWith(pendingVisits: [visit]));
      // Fire-and-forget (`unawaited`): give its microtask a turn.
      await Future<void>.delayed(Duration.zero);

      expect(calls, hasLength(1));
      expect(calls.single.single.poiId, 'node/1');
    });

    test('an empty pendingVisits list never invokes processGameVisits',
        () async {
      var calls = 0;
      final trip = build(processGameVisits: (v) async => calls++);
      await trip.startTrip();

      tracker.emit(recordingSnapshot(distanceKm: 1.0));
      await Future<void>.delayed(Duration.zero);

      expect(calls, 0);
    });

    test('a throwing processGameVisits never breaks snapshot adoption',
        () async {
      final trip = build(
          processGameVisits: (v) async => throw StateError('consumer boom'));
      await trip.startTrip();

      final visit = PendingVisit(
          poiId: 'node/1', kind: 'coins', lat: 46.5, lon: 6.6, ts: now);
      tracker.emit(recordingSnapshot(distanceKm: 3.0)
          .copyWith(pendingVisits: [visit]));
      await Future<void>.delayed(Duration.zero);

      expect(trip.distanceKm, closeTo(3.0, 1e-9));
      expect(trip.state, TripState.recording);
    });

    test('no processGameVisits configured is a silent no-op', () async {
      final trip = build(); // processGameVisits left null.
      await trip.startTrip();

      final visit = PendingVisit(
          poiId: 'node/1', kind: 'coins', lat: 46.5, lon: 6.6, ts: now);
      tracker.emit(recordingSnapshot(distanceKm: 1.0)
          .copyWith(pendingVisits: [visit]));
      await Future<void>.delayed(Duration.zero);

      expect(trip.state, TripState.recording);
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

    test('"Reprendre" does not inherit a silent-GPS warning from before',
        () async {
      tracker.persisted = recordingSnapshot().copyWith(gpsSilent: true);
      final trip = build();
      await trip.restore();
      await trip.resumeInterrupted();

      expect(trip.gpsSilent, isFalse);
      expect(tracker.startedWith.single.gpsSilent, isFalse);
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

    test(
        '"Reprendre" does not inherit a previous replan\'s route line '
        '(final review item 4)', () async {
      tracker.persisted = recordingSnapshot(routeBound: true).copyWith(
        nav: const NavFields(
          instruction: 'Tournez à gauche sur la rue de Bourg',
          distanceToManeuverM: 42,
          remainingKm: 0.8,
          etaSeconds: 300,
          replanCount: 2,
          routeShapeEnc: '_izlhA~rlgdF',
        ),
      );
      final trip = build();
      await trip.restore();
      await trip.resumeInterrupted();

      final seed = tracker.startedWith.single;
      expect(seed.navReplanCount, 0);
      expect(seed.navRouteShapeEnc, isNull);
      expect(seed.navInstruction, isNull);
      expect(seed.navDistanceToManeuverM, isNull);
      expect(seed.navRemainingKm, isNull);
      expect(seed.navEtaSeconds, isNull);
      // And it is this blanked seed the UI reads immediately, before the
      // resumed service has published anything of its own — otherwise the
      // map would draw the dead session's replanned line in the gap.
      expect(trip.snapshot?.navRouteShapeEnc, isNull);
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

    test('"Terminer" stops the service before banking', () async {
      // allowAutoRestart means the service may be alive again by the time
      // the user answers the banner; banking without stopping would leave it
      // recording with its notification up.
      final trip = build();
      await trip.restore();
      expect(trip.state, TripState.interrupted);

      // Android brought the service back between the cold start and the
      // user answering the banner.
      tracker.running = true;
      await trip.finishInterrupted();

      expect(tracker.stops, 1);
      expect(tracker.running, isFalse);
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

    test(
        'a double-tap on the interrupted banner\'s "Terminer" banks the '
        'trip exactly once (final review item 6, completion)', () async {
      totals.total = 10;
      final trip = build();
      await trip.restore();
      expect(trip.state, TripState.interrupted);

      // Same shape as stopTrip's double-tap test: two concurrent calls,
      // neither awaited before the other starts. finishInterrupted's own
      // synchronous prefix (the `_state`/`_stopping` guard) runs to
      // completion for `first` before `second` is even invoked, so the
      // second call deterministically sees `_stopping` already true.
      final first = trip.finishInterrupted();
      final second = trip.finishInterrupted();

      expect(await second, 0);
      expect(await first, closeTo(2.4, 1e-9));
      expect(totals.calls, 1);
      expect(totals.total, closeTo(12.4, 1e-9));
      expect(trip.state, TripState.idle);
    });

    test(
        'finishInterrupted racing stopTrip cannot double-bank either — the '
        'shared _stopping flag makes the second call a no-op regardless of '
        'which button it came from', () async {
      totals.total = 10;
      final trip = build();
      await trip.restore();
      expect(trip.state, TripState.interrupted);

      // stopTrip itself is a no-op here (trip.state is interrupted, not
      // recording) — the point is that finishInterrupted, which really
      // does bank, is not affected by the other method's guard sharing the
      // same flag when there is nothing for that other call to race.
      final finish = trip.finishInterrupted();
      final stop = trip.stopTrip();

      expect(await finish, closeTo(2.4, 1e-9));
      expect(await stop, 0);
      expect(totals.calls, 1);
      expect(totals.total, closeTo(12.4, 1e-9));
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

    test('Démarrer cannot bin an interrupted trip behind the banner', () async {
      final trip = build();
      await trip.restore();

      expect(await trip.startTrip(), isFalse);
      expect(trip.state, TripState.interrupted);
      expect(trip.distanceKm, closeTo(2.4, 1e-9));
      expect(tracker.startedWith, isEmpty);
      // And it says so, rather than blaming the GPS.
      expect(trip.lastStartFailure, TripStartFailure.interruptedTripPending);
      expect(startFailureMessage(trip.lastStartFailure),
          contains('Trajet interrompu'));
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

    test('changing the profile drops the route it was computed for', () async {
      final trip = build();
      await trip.saveActiveRoute(fakeActiveRoute());
      await trip.setProfile(RoutingProfile.bike);

      // A cyclist's line through a park is not a walker's: keeping the old
      // shape on screen under a new profile label would be a lie, and the
      // session tab has no planner to recompute it with.
      expect(trip.route, isNull);
      expect(trip.activeRoute!.destination, const (46.51, 6.61));
      expect(routes.current!.route, isNull);
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
