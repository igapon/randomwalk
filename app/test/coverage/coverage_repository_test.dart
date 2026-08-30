import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:randomwalk/coverage/coverage_repository.dart';
import 'package:randomwalk/valhalla/grid.dart';

void main() {
  const lat = 46.52, lon = 6.63;
  final tileBytes = List<int>.generate(64, (i) => i);
  final tileSha = sha256.convert(tileBytes).toString();

  Map<String, dynamic> manifestFor(Iterable<String> paths) => {
        'dataset_version': 'V1',
        'valhalla_version': '3.6.2',
        'region': 'test',
        'tiles': {
          for (final p in paths)
            p: {
              'asset': p.replaceAll('/', '_'),
              'bytes': tileBytes.length,
              'sha256': tileSha,
            }
        },
      };

  // Manifest containing ONLY the L2/L1/L0 tiles for the test point:
  final knownPaths = [
    TileId.fromLatLon(2, lat, lon).path,
    TileId.fromLatLon(1, lat, lon).path,
    TileId.fromLatLon(0, lat, lon).path,
  ];

  MockClient client({bool corrupt = false}) => MockClient((req) async {
        if (req.url.path.endsWith('manifest.json')) {
          return http.Response(jsonEncode(manifestFor(knownPaths)), 200);
        }
        if (req.url.path.endsWith('.gph')) {
          return http.Response.bytes(
              corrupt ? [0, 0, 0] : tileBytes, 200);
        }
        return http.Response('not found', 404);
      });

  test('downloads needed tiles present in manifest, verifies sha, reports paths',
      () async {
    final root = await Directory.systemTemp.createTemp('cov');
    final repo = CoverageRepository(root: root, client: client());
    final res = await repo.ensureCoverage(lat, lon);
    expect(res.datasetVersion, 'V1');
    expect(res.downloaded, knownPaths.length);
    for (final p in knownPaths) {
      expect(File('${res.tileDirPath}/$p').existsSync(), isTrue);
    }
  });

  test('second call downloads nothing (idempotent)', () async {
    final root = await Directory.systemTemp.createTemp('cov');
    final repo = CoverageRepository(root: root, client: client());
    await repo.ensureCoverage(lat, lon);
    final res2 = await repo.ensureCoverage(lat, lon);
    expect(res2.downloaded, 0);
  });

  test('rejects corrupted tile (sha mismatch) and leaves no file', () async {
    final root = await Directory.systemTemp.createTemp('cov');
    final repo = CoverageRepository(root: root, client: client(corrupt: true));
    final res = await repo.ensureCoverage(lat, lon);
    expect(res.downloaded, 0);
    expect(res.failed, knownPaths.length);
    for (final p in knownPaths) {
      expect(File('${res.tileDirPath}/$p').existsSync(), isFalse);
    }
  });

  test('new dataset version gets its own directory', () async {
    final root = await Directory.systemTemp.createTemp('cov');
    var version = 'V1';
    final c = MockClient((req) async {
      if (req.url.path.endsWith('manifest.json')) {
        final m = manifestFor(knownPaths)..['dataset_version'] = version;
        return http.Response(jsonEncode(m), 200);
      }
      return http.Response.bytes(tileBytes, 200);
    });
    final repo = CoverageRepository(root: root, client: c);
    final r1 = await repo.ensureCoverage(lat, lon);
    version = 'V2';
    final r2 = await repo.ensureCoverage(lat, lon);
    expect(r1.tileDirPath, isNot(r2.tileDirPath));
  });

  test('falls back to the cached manifest and already-downloaded tiles when offline',
      () async {
    final root = await Directory.systemTemp.createTemp('cov');
    final onlineRepo = CoverageRepository(root: root, client: client());
    final first = await onlineRepo.ensureCoverage(lat, lon);
    expect(first.failed, 0);
    expect(first.downloaded, knownPaths.length);

    final offlineClient =
        MockClient((req) async => throw const SocketException('no network'));
    final offlineRepo = CoverageRepository(root: root, client: offlineClient);
    final second = await offlineRepo.ensureCoverage(lat, lon);

    expect(second.datasetVersion, first.datasetVersion);
    expect(second.tileDirPath, first.tileDirPath);
    expect(second.downloaded, 0);
    expect(second.failed, 0);
    for (final p in knownPaths) {
      expect(File('${second.tileDirPath}/$p').existsSync(), isTrue);
    }
  });

  test('throws when offline and no manifest was ever cached', () async {
    final root = await Directory.systemTemp.createTemp('cov');
    final offlineClient =
        MockClient((req) async => throw const SocketException('no network'));
    final repo = CoverageRepository(root: root, client: offlineClient);
    expect(() => repo.ensureCoverage(lat, lon), throwsA(isA<SocketException>()));
  });

  test('a failed download does not create a phantom LRU entry', () async {
    final root = await Directory.systemTemp.createTemp('cov');
    final repo = CoverageRepository(root: root, client: client(corrupt: true));
    final res = await repo.ensureCoverage(lat, lon);
    final lru = File('${res.tileDirPath}/.lru.json');
    if (lru.existsSync()) {
      final map = jsonDecode(await lru.readAsString()) as Map<String, dynamic>;
      for (final p in knownPaths) {
        expect(map.containsKey(p), isFalse);
      }
    }
  });

  test('sweeps orphaned .part files left by an interrupted download', () async {
    final root = await Directory.systemTemp.createTemp('cov');
    final repo = CoverageRepository(root: root, client: client());
    // Simulate a prior run that crashed mid-download, leaving a .part file.
    final tileDir = Directory('${root.path}/V1');
    await tileDir.create(recursive: true);
    final orphan = File('${tileDir.path}/${knownPaths.first}.part');
    await orphan.create(recursive: true);
    await orphan.writeAsBytes([1, 2, 3]);

    await repo.ensureCoverage(lat, lon);
    expect(orphan.existsSync(), isFalse);
  });

  test('ensureCoverage removes sibling directories for old dataset versions',
      () async {
    final root = await Directory.systemTemp.createTemp('cov');
    // A stale directory from a previously-downloaded dataset version.
    final oldVersionDir = Directory('${root.path}/OLD-VERSION');
    await oldVersionDir.create(recursive: true);
    await File('${oldVersionDir.path}/stale.gph').writeAsBytes([1, 2, 3]);

    final repo = CoverageRepository(root: root, client: client());
    final res = await repo.ensureCoverage(lat, lon);

    expect(oldVersionDir.existsSync(), isFalse);
    expect(Directory(res.tileDirPath).existsSync(), isTrue);
    // The manifest cache file lives directly under root and must survive.
    expect(File('${root.path}/manifest.cache.json').existsSync(), isTrue);
  });
}
