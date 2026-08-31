import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:randomwalk/coverage/coverage_repository.dart';
import 'package:randomwalk/map/route_controller.dart';
import 'package:randomwalk/valhalla/engine.dart';
import 'package:randomwalk/valhalla/grid.dart';
import 'package:randomwalk/valhalla/models.dart';

class FakeEngine implements RoutingEngine {
  String? initializedWith;
  RouteRequest? lastRequest;
  @override
  Future<void> init(String tileDirPath) async => initializedWith = tileDirPath;
  @override
  Future<RouteResult> route(RouteRequest request) async {
    lastRequest = request;
    return const RouteResult(
        shape: [(46.52, 6.63), (46.53, 6.64)],
        distanceKm: 2.5,
        duration: Duration(minutes: 30),
        maneuvers: []);
  }
}

void main() {
  test('plans coverage then route, reinitializes only on version change',
      () async {
    final engine = FakeEngine();
    var version = 'V1';
    final logic = RoutePlanner(
        engine: engine,
        ensureCoverage: (lat, lon) async =>
            (datasetVersion: version, tileDirPath: '/tiles/$version'));
    final r1 = await logic.plan(const RouteRequest(
        fromLat: 46.52, fromLon: 6.63, toLat: 46.53, toLon: 6.64,
        profile: RoutingProfile.walk));
    expect(r1.distanceKm, 2.5);
    expect(engine.initializedWith, '/tiles/V1');
    engine.initializedWith = null;
    await logic.plan(const RouteRequest(
        fromLat: 46.52, fromLon: 6.63, toLat: 46.53, toLon: 6.64,
        profile: RoutingProfile.bike));
    expect(engine.initializedWith, isNull); // same version → no re-init
    expect(engine.lastRequest!.profile, RoutingProfile.bike);
  });

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
              }
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
    final offlineClient =
        MockClient((req) async => throw const SocketException('no network'));
    final offlineCoverage =
        CoverageRepository(root: root, client: offlineClient);

    final engine = FakeEngine();
    final planner = RoutePlanner(
        engine: engine,
        ensureCoverage: (lat, lon) async {
          final res = await offlineCoverage.ensureCoverage(lat, lon);
          return (
            datasetVersion: res.datasetVersion,
            tileDirPath: res.tileDirPath
          );
        });

    final result = await planner.plan(const RouteRequest(
        fromLat: lat, fromLon: lon, toLat: 46.53, toLon: 6.64,
        profile: RoutingProfile.walk));
    expect(result.distanceKm, 2.5);
    expect(engine.initializedWith, '${root.path}/V1');
  });
}
