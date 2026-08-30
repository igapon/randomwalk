import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/map/route_controller.dart';
import 'package:randomwalk/valhalla/engine.dart';
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
    expect(engine.initializedWith, isNull); // même version → pas de re-init
    expect(engine.lastRequest!.profile, RoutingProfile.bike);
  });
}
