import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:randomwalk/valhalla/engine_channel.dart';
import 'package:randomwalk/valhalla/models.dart';

// La fixture est copiée dans l'app au moment du test via les assets ? Non :
// les .gph sont copiés depuis les assets déclarés ci-dessous vers un dossier
// réel, car valhalla lit le filesystem. Déclarer dans pubspec.yaml :
//   assets:
//     - integration_test/fixtures/monaco_tiles/   (et sous-dossiers .gph)
// puis lister via AssetManifest.

Future<String> materializeFixture() async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final tileAssets = manifest
      .listAssets()
      .where((a) =>
          a.startsWith('integration_test/fixtures/monaco_tiles/') &&
          a.endsWith('.gph'))
      .toList();
  expect(tileAssets, isNotEmpty, reason: 'fixture tiles must be bundled');
  final dir = await getApplicationSupportDirectory();
  final root = Directory('${dir.path}/fixture_tiles');
  for (final a in tileAssets) {
    // Asset names are flattened ("2_000_756_425.gph") -> valhalla tree paths.
    final flat = a.substring('integration_test/fixtures/monaco_tiles/'.length);
    final rel = flat.replaceAll('_', '/');
    final f = File('${root.path}/$rel');
    await f.create(recursive: true);
    final data = await rootBundle.load(a);
    await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
  }
  return root.path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pedestrian route across Monaco', (tester) async {
    final engine = ChannelRoutingEngine();
    await engine.init(await materializeFixture());
    final result = await engine.route(const RouteRequest(
        fromLat: 43.7396, fromLon: 7.4263, // gare de Monaco
        toLat: 43.7311, toLon: 7.4197, // vieille ville
        profile: RoutingProfile.walk));
    expect(result.distanceKm, greaterThan(0.3));
    expect(result.distanceKm, lessThan(5));
    expect(result.shape.length, greaterThan(10));
    expect(result.maneuvers, isNotEmpty);
  });
}
