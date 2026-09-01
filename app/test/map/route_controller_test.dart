import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:randomwalk/coverage/coverage_repository.dart';
import 'package:randomwalk/loop/loop_planner.dart';
import 'package:randomwalk/map/geocoding.dart';
import 'package:randomwalk/map/route_controller.dart';
import 'package:randomwalk/valhalla/engine.dart';
import 'package:randomwalk/valhalla/grid.dart';
import 'package:randomwalk/valhalla/models.dart';

class FakeEngine implements RoutingEngine {
  String? initializedWith;
  RouteRequest? lastRequest;
  MultiPointRouteRequest? lastMultiRequest;
  int multiCalls = 0;

  /// When set, [routeMulti] throws this instead of returning a route — the
  /// same "no path here" outcome the real channel engine raises.
  RoutingException? multiFailure;

  @override
  Future<void> init(String tileDirPath) async => initializedWith = tileDirPath;
  @override
  Future<RouteResult> route(RouteRequest request) async {
    lastRequest = request;
    return const RouteResult(
      shape: [(46.52, 6.63), (46.53, 6.64)],
      distanceKm: 2.5,
      duration: Duration(minutes: 30),
      maneuvers: [],
    );
  }

  @override
  Future<RouteResult> routeMulti(MultiPointRouteRequest request) async {
    multiCalls++;
    lastMultiRequest = request;
    final failure = multiFailure;
    if (failure != null) throw failure;
    return const RouteResult(
      shape: [(46.52, 6.63), (46.53, 6.64), (46.54, 6.65)],
      distanceKm: 3.5,
      duration: Duration(minutes: 40),
      maneuvers: [],
    );
  }

  @override
  Future<String> trace(String requestJson) async =>
      throw UnimplementedError('not exercised by this test');
}

void main() {
  test(
    'plans coverage then route, reinitializes only on version change',
    () async {
      final engine = FakeEngine();
      var version = 'V1';
      final logic = RoutePlanner(
        engine: engine,
        ensureCoverage: (lat, lon) async => (
          datasetVersion: version,
          tileDirPath: '/tiles/$version',
          failed: 0,
          versionMismatch: false,
        ),
      );
      final r1 = await logic.plan(
        const RouteRequest(
          fromLat: 46.52,
          fromLon: 6.63,
          toLat: 46.53,
          toLon: 6.64,
          profile: RoutingProfile.walk,
        ),
      );
      expect(r1.distanceKm, 2.5);
      expect(engine.initializedWith, '/tiles/V1');
      engine.initializedWith = null;
      await logic.plan(
        const RouteRequest(
          fromLat: 46.52,
          fromLon: 6.63,
          toLat: 46.53,
          toLon: 6.64,
          profile: RoutingProfile.bike,
        ),
      );
      expect(engine.initializedWith, isNull); // same version → no re-init
      expect(engine.lastRequest!.profile, RoutingProfile.bike);
    },
  );

  test('plan() succeeds offline once the coverage cache is warm', () async {
    const lat = 46.52, lon = 6.63;
    final tileBytes = List<int>.generate(64, (i) => i);
    final tileSha = sha256.convert(tileBytes).toString();
    final knownPaths = [
      TileId.fromLatLon(2, lat, lon).path,
      TileId.fromLatLon(1, lat, lon).path,
      TileId.fromLatLon(0, lat, lon).path,
    ];
    Map<String, dynamic> manifest() => {
      'dataset_version': 'V1',
      'valhalla_version': '3.6.2',
      'region': 'test',
      'tiles': {
        for (final p in knownPaths)
          p: {
            'asset': p.replaceAll('/', '_'),
            'bytes': tileBytes.length,
            'sha256': tileSha,
          },
      },
    };
    final onlineClient = MockClient((req) async {
      if (req.url.path.endsWith('manifest.json')) {
        return http.Response(jsonEncode(manifest()), 200);
      }
      if (req.url.path.endsWith('.gph')) {
        return http.Response.bytes(tileBytes, 200);
      }
      return http.Response('not found', 404);
    });

    final root = await Directory.systemTemp.createTemp('cov_planner');
    // Warm the cache while "online".
    final warmCoverage = CoverageRepository(root: root, client: onlineClient);
    await warmCoverage.ensureCoverage(lat, lon);

    // Now go offline: every network call throws.
    final offlineClient = MockClient(
      (req) async => throw const SocketException('no network'),
    );
    final offlineCoverage = CoverageRepository(
      root: root,
      client: offlineClient,
    );

    final engine = FakeEngine();
    final planner = RoutePlanner(
      engine: engine,
      ensureCoverage: (lat, lon) async {
        final res = await offlineCoverage.ensureCoverage(lat, lon);
        return (
          datasetVersion: res.datasetVersion,
          tileDirPath: res.tileDirPath,
          failed: res.failed,
          versionMismatch: res.versionMismatch,
        );
      },
    );

    final result = await planner.plan(
      const RouteRequest(
        fromLat: lat,
        fromLon: lon,
        toLat: 46.53,
        toLon: 6.64,
        profile: RoutingProfile.walk,
      ),
    );
    expect(result.distanceKm, 2.5);
    expect(engine.initializedWith, '${root.path}/V1');
  });

  test(
    'plan() surfaces the coverage failed count and version-mismatch flag',
    () async {
      final engine = FakeEngine();
      final planner = RoutePlanner(
        engine: engine,
        ensureCoverage: (lat, lon) async => (
          datasetVersion: 'V1',
          tileDirPath: '/tiles/V1',
          failed: 3,
          versionMismatch: true,
        ),
      );
      expect(planner.lastCoverageFailed, 0);
      expect(planner.lastVersionMismatch, isFalse);
      await planner.plan(
        const RouteRequest(
          fromLat: 46.52,
          fromLon: 6.63,
          toLat: 46.53,
          toLon: 6.64,
          profile: RoutingProfile.walk,
        ),
      );
      expect(planner.lastCoverageFailed, 3);
      expect(planner.lastVersionMismatch, isTrue);
    },
  );

  group('LoopPlanOrchestrator', () {
    LoopRequest loopRequest({int seed = 1}) => LoopRequest(
      kind: PlanKind.loop,
      start: (46.52, 6.63),
      targetKm: 5,
      profile: RoutingProfile.walk,
      seed: seed,
    );

    test('fetches coverage once, then inits and calls routeMulti through the '
        'engine', () async {
      final engine = FakeEngine();
      var version = 'V1';
      var coverageCalls = 0;
      final orchestrator = LoopPlanOrchestrator(
        engine: engine,
        ensureCoverage: (lat, lon) async {
          coverageCalls++;
          return (
            datasetVersion: version,
            tileDirPath: '/tiles/$version',
            failed: 0,
            versionMismatch: false,
          );
        },
      );

      final result = await orchestrator.plan(loopRequest());

      // Exactly one ensureCoverage call for the whole plan() series, however
      // many router probes LoopPlanner itself made internally.
      expect(coverageCalls, 1);
      expect(engine.initializedWith, '/tiles/V1');
      expect(engine.multiCalls, greaterThan(0));
      expect(engine.lastMultiRequest!.profile, RoutingProfile.walk);
      expect(result.candidates, isNotEmpty);
    });

    test('re-inits only when the dataset version changes', () async {
      final engine = FakeEngine();
      var version = 'V1';
      final orchestrator = LoopPlanOrchestrator(
        engine: engine,
        ensureCoverage: (lat, lon) async => (
          datasetVersion: version,
          tileDirPath: '/tiles/$version',
          failed: 0,
          versionMismatch: false,
        ),
      );

      await orchestrator.plan(loopRequest());
      expect(engine.initializedWith, '/tiles/V1');
      engine.initializedWith = null;

      await orchestrator.plan(loopRequest(seed: 2));
      expect(engine.initializedWith, isNull); // same version -> no re-init

      version = 'V2';
      await orchestrator.plan(loopRequest(seed: 3));
      expect(engine.initializedWith, '/tiles/V2');
    });

    test(
      'surfaces the coverage failed count and version-mismatch flag',
      () async {
        final engine = FakeEngine();
        final orchestrator = LoopPlanOrchestrator(
          engine: engine,
          ensureCoverage: (lat, lon) async => (
            datasetVersion: 'V1',
            tileDirPath: '/tiles/V1',
            failed: 4,
            versionMismatch: true,
          ),
        );
        expect(orchestrator.lastCoverageFailed, 0);
        expect(orchestrator.lastVersionMismatch, isFalse);
        await orchestrator.plan(loopRequest());
        expect(orchestrator.lastCoverageFailed, 4);
        expect(orchestrator.lastVersionMismatch, isTrue);
      },
    );

    test('a RoutingException from the engine is swallowed into an empty '
        'plan, not rethrown', () async {
      final engine = FakeEngine()
        ..multiFailure = const RoutingException('no route here');
      final orchestrator = LoopPlanOrchestrator(
        engine: engine,
        ensureCoverage: (lat, lon) async => (
          datasetVersion: 'V1',
          tileDirPath: '/tiles/V1',
          failed: 0,
          versionMismatch: false,
        ),
      );

      final result = await orchestrator.plan(loopRequest());
      expect(result.candidates, isEmpty);
      expect(result.targetMet, isFalse);
    });
  });

  test(
    'geocodingServiceProvider closes its owned http.Client on dispose',
    () async {
      final container = ProviderContainer();
      final service =
          container.read(geocodingServiceProvider) as PhotonGeocodingService;
      container.dispose();
      await expectLater(
        service.client.get(Uri.parse('http://example.invalid')),
        throwsA(isA<http.ClientException>()),
      );
    },
  );
}
