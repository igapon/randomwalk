import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/tracking/nav_seed.dart';
import 'package:randomwalk/tracking/permissions.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/trip/active_route_store.dart';
import 'package:randomwalk/trip/trip_controller.dart';
import 'package:randomwalk/valhalla/models.dart';

import '../support/trip_fakes.dart';

void main() {
  group('NavSeed', () {
    NavSeed seed({String? tileDirPath = '/data/tiles/2026.08'}) => NavSeed(
      route: fakeRoute(),
      destLat: 46.51,
      destLon: 6.61,
      profile: RoutingProfile.bike,
      tileDirPath: tileDirPath,
    );

    test('round-trips everything a service-side replan needs', () {
      final restored = NavSeed.fromJson(
        jsonDecode(jsonEncode(seed().toJson())),
      );

      expect(restored.route.distanceKm, closeTo(1.2, 1e-9));
      expect(restored.route.shape, hasLength(2));
      expect(restored.route.shape.first.$1, closeTo(46.5, 1e-6));
      expect(restored.destLat, closeTo(46.51, 1e-9));
      expect(restored.destLon, closeTo(6.61, 1e-9));
      expect(restored.profile, RoutingProfile.bike);
      expect(restored.tileDirPath, '/data/tiles/2026.08');
    });

    test('survives having no tile directory to point at', () {
      final restored = NavSeed.fromJson(
        jsonDecode(jsonEncode(seed(tileDirPath: null).toJson())),
      );
      expect(restored.tileDirPath, isNull);
    });

    test('an unknown profile name degrades to walk rather than throwing', () {
      final json = seed().toJson()..['profile'] = 'hovercraft';
      expect(NavSeed.fromJson(json).profile, RoutingProfile.walk);
    });

    test(
      'isLoop round-trips, defaults false, and tolerates a legacy document',
      () {
        expect(seed().isLoop, isFalse);
        final loop = NavSeed(
          route: fakeRoute(),
          destLat: 46.51,
          destLon: 6.61,
          profile: RoutingProfile.walk,
          tileDirPath: null,
          isLoop: true,
        );
        expect(
          NavSeed.fromJson(jsonDecode(jsonEncode(loop.toJson()))).isLoop,
          isTrue,
        );
        expect(
          NavSeed.fromJson(seed().toJson()..remove('isLoop')).isLoop,
          isFalse,
        );
      },
    );
  });

  group('TripController seeds the service for navigation', () {
    late FakeTripTracker tracker;
    late MemoryRouteStore routes;

    TripController build({Future<String?> Function()? resolveTileDir}) =>
        TripController(
          tracker: tracker,
          routeStore: routes,
          totalStore: FakeTotalDistanceStore(),
          finalisedTrips: MemoryFinalisedTripMemory(),
          ensurePermissions: () async => const TripPermissions(
            outcome: TripPermissionOutcome.ready,
            mode: TrackingMode.background,
            stepsAvailable: true,
          ),
          createStepCounter: (seed) =>
              SessionStepCounter(FakeStepSensor(), seed: seed),
          clock: () => DateTime.utc(2026, 8, 30, 10, 0, 0),
          persistProfile: (_) async {},
          loadProfile: () async => null,
          resolveTileDir: resolveTileDir,
        );

    setUp(() {
      tracker = FakeTripTracker();
      routes = MemoryRouteStore()..current = fakeActiveRoute();
    });

    test(
      'a route-bound trip carries route, destination, profile and tiles',
      () async {
        final trip = build(resolveTileDir: () async => '/data/tiles/2026.08');
        await trip.restore();
        expect(await trip.startTrip(route: fakeRoute()), isTrue);

        final nav = tracker.startedNav.single!;
        expect(nav.route.distanceKm, closeTo(1.2, 1e-9));
        expect(nav.destLat, closeTo(46.51, 1e-9));
        expect(nav.destLon, closeTo(6.61, 1e-9));
        expect(nav.profile, RoutingProfile.walk);
        expect(nav.tileDirPath, '/data/tiles/2026.08');
      },
    );

    test('a free trip seeds no navigation at all', () async {
      final trip = build(resolveTileDir: () async => '/data/tiles/2026.08');
      await trip.restore();
      expect(await trip.startTrip(profile: RoutingProfile.walk), isTrue);

      expect(tracker.startedNav.single, isNull);
    });

    test(
      'with no destination planned, the route\'s own end is the target',
      () async {
        routes.current = ActiveRoute(
          route: fakeRoute(),
          profile: RoutingProfile.walk,
        );
        final trip = build();
        await trip.restore();
        await trip.startTrip(route: fakeRoute());

        final nav = tracker.startedNav.single!;
        expect(nav.destLat, closeTo(fakeRoute().shape.last.$1, 1e-9));
        expect(nav.destLon, closeTo(fakeRoute().shape.last.$2, 1e-9));
      },
    );

    test('no tile directory still navigates — it only cannot replan', () async {
      final trip = build(resolveTileDir: () async => null);
      await trip.restore();
      await trip.startTrip(route: fakeRoute());

      expect(tracker.startedNav.single, isNotNull);
      expect(tracker.startedNav.single!.tileDirPath, isNull);
    });

    test('a planned loop reaches the service flagged as one', () async {
      // Item 1: without this the service has no way to tell a loop from an
      // A→B route, and its first off-route replan reroutes the walker to the
      // loop's own start point — ending the trip.
      routes.current = ActiveRoute(
        route: fakeRoute(),
        profile: RoutingProfile.walk,
        isLoop: true,
      );
      final trip = build();
      await trip.restore();
      await trip.startTrip(route: fakeRoute());

      expect(tracker.startedNav.single!.isLoop, isTrue);
    });

    test('an ordinary A→B plan is not flagged as a loop', () async {
      final trip = build();
      await trip.restore();
      await trip.startTrip(route: fakeRoute());

      expect(tracker.startedNav.single!.isLoop, isFalse);
    });

    test('a failing tile lookup never blocks the start of a trip', () async {
      final trip = build(resolveTileDir: () async => throw StateError('disk'));
      await trip.restore();

      expect(await trip.startTrip(route: fakeRoute()), isTrue);
      expect(tracker.startedNav.single!.tileDirPath, isNull);
    });
  });
}
