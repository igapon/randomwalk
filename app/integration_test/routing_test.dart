import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:randomwalk/coverage/coverage_repository.dart';
import 'package:randomwalk/loop/loop_planner.dart';
import 'package:randomwalk/valhalla/engine.dart';
import 'package:randomwalk/valhalla/engine_channel.dart';
import 'package:randomwalk/valhalla/models.dart';

// This exercises the real production path end to end rather than a bundled test
// fixture: CoverageRepository downloads real tiles from the live manifest (same
// path Task 9 wires up), then ChannelRoutingEngine routes through them. That
// avoids shipping ~1.3MB of test-only .gph tiles in every release APK, and it
// pre-validates that the deployed tile dataset's Valhalla version stays aligned
// with the embedded valhalla-mobile AAR (both are 3.6.2 — see task-8-report.md).
// Requires network; the emulator running this in CI has it.

/// Lausanne, well within the ch-fr coverage area — shared by both tests.
const _lat = 46.52;
const _lon = 6.63;

/// Loose ceiling for the loop plan (M3 DoD item), deliberately far above the
/// DoD's own < 15 s target: the target is measured and printed below, but a CI
/// emulator is not a phone, and a shared runner having a slow minute is not the
/// same finding as the planner having regressed. A breach of *this* bound means
/// the search is not converging at all.
const _kLoopPlanCeiling = Duration(seconds: 60);

/// The M3 DoD's own wall-clock target for a loop plan, on a real device.
/// Reported, never asserted — see [_kLoopPlanCeiling].
const _kLoopPlanDodTarget = Duration(seconds: 15);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pedestrian route across Lausanne using production tiles', (
    tester,
  ) async {
    final supportDir = await getApplicationSupportDirectory();
    final repo = CoverageRepository(
      root: Directory('${supportDir.path}/coverage_tiles'),
      client: http.Client(),
    );

    final coverage = await repo.ensureCoverage(_lat, _lon);
    expect(
      coverage.failed,
      0,
      reason: 'no tile download should fail sha check',
    );
    expect(
      coverage.total,
      greaterThan(0),
      reason: 'ch-fr must cover this point',
    );

    final engine = ChannelRoutingEngine();
    await engine.init(coverage.tileDirPath);
    final result = await engine.route(
      const RouteRequest(
        fromLat: 46.5197,
        fromLon: 6.6323,
        toLat: 46.5089,
        toLon: 6.6283,
        profile: RoutingProfile.walk,
      ),
    );
    expect(result.distanceKm, greaterThan(0.5));
    expect(result.distanceKm, lessThan(6));
    expect(result.shape.length, greaterThan(10));
    expect(result.maneuvers, isNotEmpty);
  });

  // M3 DoD: a real 5 km walking loop, planned by the real LoopPlanner over the
  // real engine's multi-point routing, against real downloaded tiles. The unit
  // tests drive LoopPlanner against a synthetic router — which proves the
  // bisection but says nothing about whether Valhalla can actually route a
  // circle of `circleWaypoints` on the Lausanne street network within the
  // planner's own call budget. That is the question this answers.
  testWidgets('plans a 5 km walking loop through the real engine', (
    tester,
  ) async {
    final supportDir = await getApplicationSupportDirectory();
    final repo = CoverageRepository(
      root: Directory('${supportDir.path}/coverage_tiles'),
      client: http.Client(),
    );

    // Same coverage assertions as the A→B test: a loop that comes back empty
    // because tiles failed their sha check is not a planner finding, and this
    // must not be mistaken for one.
    final coverage = await repo.ensureCoverage(_lat, _lon);
    expect(
      coverage.failed,
      0,
      reason: 'no tile download should fail sha check',
    );
    expect(
      coverage.total,
      greaterThan(0),
      reason: 'ch-fr must cover this point',
    );

    final engine = ChannelRoutingEngine();
    await engine.init(coverage.tileDirPath);

    // Exactly the wiring `LoopPlanOrchestrator` uses in production: a
    // RoutingException is "this geometry is not routable" (a null for the
    // bisection to shrink away from), never an error that aborts the plan.
    final planner = LoopPlanner(
      router: (locations) async {
        try {
          return await engine.routeMulti(
            MultiPointRouteRequest(
              locations: locations,
              profile: RoutingProfile.walk,
            ),
          );
        } on RoutingException {
          return null;
        }
      },
    );

    // Fixed seed: the whole search is reproducible for a given seed (see
    // LoopRequest.seed), so a failure here is re-runnable rather than a
    // once-in-a-while shape nobody can reproduce.
    final request = LoopRequest(
      kind: PlanKind.loop,
      start: (_lat, _lon),
      targetKm: 5.0,
      profile: RoutingProfile.walk,
      seed: 20260831,
    );

    final stopwatch = Stopwatch()..start();
    final result = await planner.plan(request);
    stopwatch.stop();

    expect(
      result.candidates,
      isNotEmpty,
      reason: 'a 5 km walking loop in central Lausanne must be plannable',
    );

    final bestGap = result.bestGapRatio;
    expect(bestGap, isNotNull);
    // 0.15 rather than LoopPlanner.targetTolerance (0.10): the tolerance is
    // what the *planner* calls on-target and what the UI badges against, while
    // this is the DoD's "the offer is recognisably the distance asked for"
    // bar against a real street network, where the closest routable circle is
    // whatever the roads allow. Tightening it to 0.10 would be asserting
    // something about Lausanne's street grid, not about this code.
    expect(
      bestGap!,
      lessThanOrEqualTo(0.15),
      reason:
          'best candidate should be within 15 % of the 5 km target; '
          'got ${(bestGap * 100).toStringAsFixed(1)} %',
    );

    for (final candidate in result.candidates) {
      expect(candidate.route.shape.length, greaterThan(10));
      expect(candidate.route.distanceKm, greaterThan(0));
      expect(candidate.repeatedRatio, inInclusiveRange(0.0, 1.0));
    }

    // Wall clock, logged either way — the DoD's < 15 s target is a measured
    // output here, not a CI gate (see [_kLoopPlanCeiling]).
    final elapsed = stopwatch.elapsed;
    // ignore: avoid_print
    print(
      '[M3 DoD] 5 km loop plan: ${elapsed.inMilliseconds} ms '
      '(DoD target < ${_kLoopPlanDodTarget.inSeconds}s, '
      'CI ceiling ${_kLoopPlanCeiling.inSeconds}s) — '
      '${result.candidates.length} candidate(s), '
      'best gap ${(bestGap * 100).toStringAsFixed(1)} %, '
      'targetMet ${result.targetMet}',
    );
    expect(
      elapsed,
      lessThan(_kLoopPlanCeiling),
      reason:
          'the loop search should converge inside its router-call '
          'budget, not grind — took ${elapsed.inMilliseconds} ms',
    );
  });
}
