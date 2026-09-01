import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/coverage/manifest.dart';

void main() {
  group('TileManifest.fromJson', () {
    test('parses an old manifest with no "pois" key (retro-compat)', () {
      final m = TileManifest.fromJson({
        'dataset_version': 'V1',
        'valhalla_version': '3.6.2',
        'region': 'ch-fr',
        'tiles': {
          '0/1.gph': {'asset': '0_1.gph', 'bytes': 3, 'sha256': 'abc'},
        },
      });
      expect(m.datasetVersion, 'V1');
      expect(m.tiles['0/1.gph']!.bytes, 3);
      expect(m.pois, isNull);
    });

    test('parses a manifest carrying an optional "pois" entry', () {
      final m = TileManifest.fromJson({
        'dataset_version': 'V2',
        'valhalla_version': '3.6.2',
        'region': 'ch-fr',
        'tiles': <String, dynamic>{},
        'pois': {'asset': 'pois.json.gz', 'bytes': 42, 'sha256': 'deadbeef'},
      });
      expect(m.pois, isNotNull);
      expect(m.pois!.asset, 'pois.json.gz');
      expect(m.pois!.bytes, 42);
      expect(m.pois!.sha256, 'deadbeef');
    });
  });
}
