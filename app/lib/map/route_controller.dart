import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../coverage/coverage_repository.dart';
import '../valhalla/engine.dart';
import '../valhalla/engine_channel.dart';
import '../valhalla/models.dart';
import 'geocoding.dart';

typedef EnsureCoverage
    = Future<
        ({
          String datasetVersion,
          String tileDirPath,
          int failed,
          bool versionMismatch
        })>
    Function(double lat, double lon);

/// Pure orchestration, unit-testable: coverage -> (re)init -> route.
class RoutePlanner {
  final RoutingEngine engine;
  final EnsureCoverage ensureCoverage;
  String? _initializedVersion;
  RoutePlanner({required this.engine, required this.ensureCoverage});

  /// `CoverageResult.failed` (dataset_repository.dart) for the most recent
  /// [plan] call — previously swallowed by the fixed `(datasetVersion,
  /// tileDirPath)` tuple [EnsureCoverage] returns. The UI polls this right
  /// after `plan()` to decide whether to show the "couverture incomplète"
  /// banner, rather than widening [plan]'s return type (which is the
  /// routing engine's own [RouteResult]).
  int lastCoverageFailed = 0;

  /// Whether the coverage used for the most recent [plan] call is a stale
  /// cached manifest kept because the freshly-fetched one had an
  /// incompatible `valhalla_version` (see `DatasetVersionMismatch`).
  bool lastVersionMismatch = false;

  Future<RouteResult> plan(RouteRequest request) async {
    final cov = await ensureCoverage(request.fromLat, request.fromLon);
    lastCoverageFailed = cov.failed;
    lastVersionMismatch = cov.versionMismatch;
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
  final client = http.Client();
  ref.onDispose(client.close);
  return CoverageRepository(root: Directory('${dir.path}/tiles'), client: client);
});

final geocodingServiceProvider = Provider<GeocodingService>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return PhotonGeocodingService(client: client);
});

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
        return (
          datasetVersion: res.datasetVersion,
          tileDirPath: res.tileDirPath,
          failed: res.failed,
          versionMismatch: res.versionMismatch,
        );
      });
});
