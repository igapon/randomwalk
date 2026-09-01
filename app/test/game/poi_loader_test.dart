import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:randomwalk/coverage/coverage_repository.dart';
import 'package:randomwalk/game/poi_loader.dart';
import 'package:randomwalk/map/route_controller.dart' show coverageRepositoryProvider;

/// Every one of these tests exercises only `poisFile()`/the disk-only
/// providers built on it — nothing here should ever reach the network, so
/// any request reaching this client is itself a test failure.
final _failingClient =
    MockClient((req) async => http.Response('unexpected request', 500));

void main() {
  const churchLat = 46.5200, churchLon = 6.6300;

  final fixtureJson = jsonEncode([
    {
      'id': 'node/1',
      'kind': 'reveal',
      'lat': churchLat,
      'lon': churchLon,
      'name': 'Église Saint-Pierre',
    },
    {'id': 'node/2', 'kind': 'coins', 'lat': 46.521, 'lon': 6.631},
  ]);

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('poi_loader_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('loadPoiStoreOffUiIsolate', () {
    test('produces the same result as PoiStore.load, off the calling isolate',
        () async {
      final file = File('${tempDir.path}/pois.json.gz');
      await file.writeAsBytes(gzip.encode(utf8.encode(fixtureJson)));

      final store = await loadPoiStoreOffUiIsolate(file);

      expect(store.count, 2);
      final near = store.near(churchLat, churchLon, 50);
      expect(near, hasLength(1));
      expect(near.single.id, 'node/1');
      expect(near.single.name, 'Église Saint-Pierre');
    });

    test('a missing/corrupt file degrades to an empty store, never throws',
        () async {
      final file = File('${tempDir.path}/missing.json.gz');
      final store = await loadPoiStoreOffUiIsolate(file);
      expect(store.count, 0);
    });
  });

  group('poisFileProvider / poisStoreProvider', () {
    Future<void> writeManifestCache(Directory root, {TileAssetInfo? pois}) async {
      final manifest = {
        'dataset_version': 'v1',
        'valhalla_version': '3.6.2',
        'tiles': <String, dynamic>{},
        if (pois != null)
          'pois': {
            'asset': pois.asset,
            'bytes': pois.bytes,
            'sha256': pois.sha256,
          },
      };
      await File('${root.path}/manifest.cache.json')
          .writeAsString(jsonEncode(manifest));
    }

    ProviderContainer buildContainer(CoverageRepository repo) {
      final container = ProviderContainer(overrides: [
        coverageRepositoryProvider.overrideWith((ref) async => repo),
      ]);
      addTearDown(container.dispose);
      return container;
    }

    test('no cached manifest at all: poisFileProvider is null, store is empty',
        () async {
      final root = Directory('${tempDir.path}/tiles');
      final repo = CoverageRepository(root: root, client: _failingClient);
      final container = buildContainer(repo);

      expect(await container.read(poisFileProvider.future), isNull);
      final store = await container.read(poisStoreProvider.future);
      expect(store.count, 0);
    });

    test('a manifest with no "pois" key: still null, no crash', () async {
      final root = Directory('${tempDir.path}/tiles');
      await root.create(recursive: true);
      await writeManifestCache(root);
      final repo = CoverageRepository(root: root, client: _failingClient);
      final container = buildContainer(repo);

      expect(await container.read(poisFileProvider.future), isNull);
    });

    test(
        'a manifest advertising pois, with the asset already on disk: loads '
        'the real store off the UI isolate', () async {
      final root = Directory('${tempDir.path}/tiles');
      await Directory('${root.path}/v1').create(recursive: true);
      final gzBytes = gzip.encode(utf8.encode(fixtureJson));
      await File('${root.path}/v1/pois.json.gz').writeAsBytes(gzBytes);
      await writeManifestCache(root,
          pois: TileAssetInfo(
              asset: 'pois.json.gz', bytes: gzBytes.length, sha256: 'unused'));
      final repo = CoverageRepository(root: root, client: _failingClient);
      final container = buildContainer(repo);

      final file = await container.read(poisFileProvider.future);
      expect(file, isNotNull);
      expect(file!.path, '${root.path}/v1/pois.json.gz');

      final store = await container.read(poisStoreProvider.future);
      expect(store.count, 2);
    });

    test('the asset advertised but not yet downloaded: poisFileProvider is '
        'null (mirrors CoverageRepository.poisFile\'s disk-only contract)',
        () async {
      final root = Directory('${tempDir.path}/tiles');
      await root.create(recursive: true);
      await writeManifestCache(root,
          pois: const TileAssetInfo(
              asset: 'pois.json.gz', bytes: 10, sha256: 'unused'));
      final repo = CoverageRepository(root: root, client: _failingClient);
      final container = buildContainer(repo);

      expect(await container.read(poisFileProvider.future), isNull);
    });
  });
}

/// A minimal shape for building a manifest's `pois` entry in tests, so this
/// file doesn't need to reach into `manifest.dart`'s `TileAsset` (private
/// construction details aside, using the same field names keeps the JSON
/// this test writes obviously in sync with what `TileManifest.fromJson`
/// actually reads).
class TileAssetInfo {
  final String asset;
  final int bytes;
  final String sha256;
  const TileAssetInfo(
      {required this.asset, required this.bytes, required this.sha256});
}
