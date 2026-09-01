import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';
import '../coverage/coverage_repository.dart';
import '../loop/loop_planner.dart';
import '../valhalla/engine.dart';
import '../valhalla/engine_channel.dart';
import '../valhalla/models.dart';
import 'geocoding.dart';

typedef EnsureCoverage =
    Future<
      ({
        String datasetVersion,
        String tileDirPath,
        int failed,
        bool versionMismatch,
      })
    >
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

final routingEngineProvider = Provider<RoutingEngine>(
  (ref) => ChannelRoutingEngine(),
);

final coverageRepositoryProvider = FutureProvider<CoverageRepository>((
  ref,
) async {
  final dir = await getApplicationSupportDirectory();
  // A raw `dart:io` `HttpClient` behind `IOClient`, not the package's plain
  // `http.Client()` — task-8 backlog item 2: this is the only layer that
  // exposes a genuine connect-phase timeout (`connectionTimeout`), distinct
  // from the request-level `.timeout()` [CoverageRepository] wraps each
  // `get()` call in for the total budget. See `CoverageConfig.connectTimeout`.
  final client = IOClient(
    HttpClient()..connectionTimeout = CoverageConfig.connectTimeout,
  );
  ref.onDispose(client.close);
  return CoverageRepository(
    root: Directory('${dir.path}/tiles'),
    client: client,
  );
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
///
/// Accepted limitation (task-8 backlog item 4): this slot is a single
/// provider-wide instance, not one per in-flight request. Two coverage
/// downloads that happen to overlap — a loop plan's own multi-probe
/// `ensureCoverage` racing an A→B plan the walker triggers moments later,
/// say — share the one `onProgress` callback the last setter installed, so
/// either caller's progress bar can briefly show the *other* request's
/// numbers until its own next callback fires. Purely cosmetic (a progress
/// bar reading, never route correctness — each request's own coverage/route
/// result is unaffected) and, in practice, rare: [RoutePlanner.plan] and
/// [LoopPlanOrchestrator.plan] both `await` their coverage step before doing
/// anything else, so two calls need to be started within the same short
/// coverage-download window to interleave at all. Fixing it properly would
/// mean threading a per-request progress callback through
/// [EnsureCoverage]/[RoutePlanner]/[LoopPlanOrchestrator] instead of this
/// shared slot — not worth the signature churn for a progress-bar glitch.
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
      final res = await coverage.ensureCoverage(
        lat,
        lon,
        onProgress: sink.onProgress,
      );
      return (
        datasetVersion: res.datasetVersion,
        tileDirPath: res.tileDirPath,
        failed: res.failed,
        versionMismatch: res.versionMismatch,
      );
    },
  );
});

/// Pure orchestration for loop/duration planning (task 6), the same
/// coverage -> (re)init -> route shape [RoutePlanner] uses for a plain A->B
/// plan — but coverage is only ever fetched *once* per [plan] call, up
/// front, rather than once per [LoopPlanner]'s many router probes (up to
/// `LoopPlanner.candidateCount * LoopPlanner.maxRouterCallsPerCandidate`):
/// every probe for one request starts from the same point, so there is
/// nothing a second `ensureCoverage` call for the same series would learn
/// that the first one did not already establish.
class LoopPlanOrchestrator {
  final RoutingEngine engine;
  final EnsureCoverage ensureCoverage;
  String? _initializedVersion;

  /// Same meaning as [RoutePlanner.lastCoverageFailed] — surfaced the same
  /// way, for the same "couverture incomplète" banner.
  int lastCoverageFailed = 0;
  bool lastVersionMismatch = false;

  LoopPlanOrchestrator({required this.engine, required this.ensureCoverage});

  Future<LoopPlanResult> plan(
    LoopRequest request, {
    math.Random Function(int seed)? rng,
  }) async {
    final (lat, lon) = request.start;
    final cov = await ensureCoverage(lat, lon);
    lastCoverageFailed = cov.failed;
    lastVersionMismatch = cov.versionMismatch;
    if (cov.datasetVersion != _initializedVersion) {
      await engine.init(cov.tileDirPath);
      _initializedVersion = cov.datasetVersion;
    }

    final planner = LoopPlanner(
      rng: rng,
      router: (locations) async {
        try {
          return await engine.routeMulti(
            MultiPointRouteRequest(
              locations: locations,
              profile: request.profile,
            ),
          );
          // A geometry the engine cannot route (too far off-network, outside
          // covered territory, etc.) is exactly what LoopRouter's contract
          // calls "not routable" — a null candidate for the bisection to
          // shrink away from, never a crash that would abort the whole plan.
        } on RoutingException {
          return null;
        }
      },
    );
    return planner.plan(request);
  }
}

final loopPlannerProvider = FutureProvider<LoopPlanOrchestrator>((ref) async {
  final coverage = await ref.watch(coverageRepositoryProvider.future);
  final sink = ref.watch(progressSinkProvider);
  return LoopPlanOrchestrator(
    engine: ref.watch(routingEngineProvider),
    ensureCoverage: (lat, lon) async {
      final res = await coverage.ensureCoverage(
        lat,
        lon,
        onProgress: sink.onProgress,
      );
      return (
        datasetVersion: res.datasetVersion,
        tileDirPath: res.tileDirPath,
        failed: res.failed,
        versionMismatch: res.versionMismatch,
      );
    },
  );
});
