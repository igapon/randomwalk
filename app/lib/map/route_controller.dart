import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../coverage/coverage_repository.dart';
import '../valhalla/engine.dart';
import '../valhalla/engine_channel.dart';
import '../valhalla/models.dart';
import 'geocoding.dart';

typedef EnsureCoverage = Future<({String datasetVersion, String tileDirPath})>
    Function(double lat, double lon);

/// Pure orchestration, unit-testable: coverage -> (re)init -> route.
class RoutePlanner {
  final RoutingEngine engine;
  final EnsureCoverage ensureCoverage;
  String? _initializedVersion;
  RoutePlanner({required this.engine, required this.ensureCoverage});

  Future<RouteResult> plan(RouteRequest request) async {
    final cov = await ensureCoverage(request.fromLat, request.fromLon);
    if (cov.datasetVersion != _initializedVersion) {
      await engine.init(cov.tileDirPath);
      _initializedVersion = cov.datasetVersion;
    }
    return engine.route(request);
  }
}

final routingEngineProvider =
    Provider<RoutingEngine>((ref) => ChannelRoutingEngine());

final coverageRepositoryProvider = FutureProvider<CoverageRepository>((ref) async {
  final dir = await getApplicationSupportDirectory();
  return CoverageRepository(
      root: Directory('${dir.path}/tiles'), client: http.Client());
});

final geocodingServiceProvider = Provider<GeocodingService>(
    (ref) => PhotonGeocodingService(client: http.Client()));

/// Mutable slot the UI can set right before calling `planner.plan(...)` to
/// receive tile-download progress for that request, without widening
/// [EnsureCoverage] (which would break [RoutePlanner]'s fixed, tested
/// signature).
class ProgressSink {
  void Function(int done, int total)? onProgress;
}

final progressSinkProvider = Provider<ProgressSink>((ref) => ProgressSink());

final routePlannerProvider = FutureProvider<RoutePlanner>((ref) async {
  final coverage = await ref.watch(coverageRepositoryProvider.future);
  final sink = ref.watch(progressSinkProvider);
  return RoutePlanner(
      engine: ref.watch(routingEngineProvider),
      ensureCoverage: (lat, lon) async {
        final res = await coverage.ensureCoverage(lat, lon,
            onProgress: sink.onProgress);
        return (datasetVersion: res.datasetVersion, tileDirPath: res.tileDirPath);
      });
});
