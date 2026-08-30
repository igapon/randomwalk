import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:randomwalk/coverage/coverage_repository.dart';
import 'package:randomwalk/valhalla/engine_channel.dart';
import 'package:randomwalk/valhalla/models.dart';

// This exercises the real production path end to end rather than a bundled test
// fixture: CoverageRepository downloads real tiles from the live manifest (same
// path Task 9 wires up), then ChannelRoutingEngine routes through them. That
// avoids shipping ~1.3MB of test-only .gph tiles in every release APK, and it
// pre-validates that the deployed tile dataset's Valhalla version stays aligned
// with the embedded valhalla-mobile AAR (both are 3.6.2 — see task-8-report.md).
// Requires network; the emulator running this in CI has it.

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pedestrian route across Lausanne using production tiles',
      (tester) async {
    final supportDir = await getApplicationSupportDirectory();
    final repo = CoverageRepository(
        root: Directory('${supportDir.path}/coverage_tiles'),
        client: http.Client());

    // Lausanne, well within the ch-fr coverage area.
    final coverage = await repo.ensureCoverage(46.52, 6.63);
    expect(coverage.failed, 0, reason: 'no tile download should fail sha check');
    expect(coverage.total, greaterThan(0), reason: 'ch-fr must cover this point');

    final engine = ChannelRoutingEngine();
    await engine.init(coverage.tileDirPath);
    final result = await engine.route(const RouteRequest(
        fromLat: 46.5197, fromLon: 6.6323,
        toLat: 46.5089, toLon: 6.6283,
        profile: RoutingProfile.walk));
    expect(result.distanceKm, greaterThan(0.5));
    expect(result.distanceKm, lessThan(6));
    expect(result.shape.length, greaterThan(10));
    expect(result.maneuvers, isNotEmpty);
  });
}
