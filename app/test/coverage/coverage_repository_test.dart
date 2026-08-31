import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:randomwalk/coverage/coverage_repository.dart';
import 'package:randomwalk/coverage/manifest.dart';
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

  test(
      'ensureCoverage keeps only the 2 most recently touched sibling version directories',
      () async {
    final root = await Directory.systemTemp.createTemp('cov');
    // Three stale directories from previously-downloaded dataset versions,
    // oldest to newest by mtime.
    final oldest = Directory('${root.path}/OLDEST');
    final middle = Directory('${root.path}/MIDDLE');
    for (final (dir, ageMinutes) in [(oldest, 30), (middle, 20)]) {
      final f = File('${dir.path}/stale.gph');
      await f.create(recursive: true);
      await f.writeAsBytes([1, 2, 3]);
      await f.setLastModified(
          DateTime.now().subtract(Duration(minutes: ageMinutes)));
    }

    final repo = CoverageRepository(root: root, client: client());
    final res = await repo.ensureCoverage(lat, lon);

    // Active dir (just downloaded into) + MIDDLE (2nd most recent) survive;
    // OLDEST — beyond the top 2 — is reclaimed.
    expect(oldest.existsSync(), isFalse);
    expect(middle.existsSync(), isTrue);
    expect(Directory(res.tileDirPath).existsSync(), isTrue);
    // The manifest cache file lives directly under root and must survive.
    expect(File('${root.path}/manifest.cache.json').existsSync(), isTrue);
  });

  test('purge-by-count sweeps a sibling directory with no tile file at all',
      () async {
    final root = await Directory.systemTemp.createTemp('cov');
    final empty = Directory('${root.path}/EMPTY-LEFTOVER');
    await empty.create(recursive: true);

    final repo = CoverageRepository(root: root, client: client());
    await repo.ensureCoverage(lat, lon);

    expect(empty.existsSync(), isFalse);
  });

  test(
      'purge-by-count never deletes the active version dir, even when this run had failures',
      () async {
    final root = await Directory.systemTemp.createTemp('cov');
    // One previously-downloaded, fully-usable old version — purge-by-count
    // keeps the active dir plus this single other one (only 2 siblings
    // exist total, which is within the 2-dir keep count), so it survives
    // here regardless of relative recency. (A second old sibling is
    // deliberately not added: with 2 *other* siblings competing for the 1
    // remaining slot, which one survives depends on sub-millisecond mtime
    // ordering that is not reliably comparable across filesystems/OSes —
    // see the dedicated, explicit-mtime purge-by-count tests above for
    // that behaviour instead.)
    final old1 = Directory('${root.path}/OLD-1');
    await File('${old1.path}/${knownPaths.first}').create(recursive: true);
    await File('${old1.path}/${knownPaths.first}').writeAsBytes(tileBytes);

    final c = MockClient((req) async {
      if (req.url.path.endsWith('manifest.json')) {
        final m = manifestFor(knownPaths)..['dataset_version'] = 'NEW-VERSION';
        return http.Response(jsonEncode(m), 200);
      }
      // Every tile download fails (e.g. connectivity dropped mid-download).
      return http.Response('not found', 404);
    });
    final repo = CoverageRepository(root: root, client: c);

    final incomplete = await repo.ensureCoverage(lat, lon);
    expect(incomplete.datasetVersion, 'NEW-VERSION');
    expect(incomplete.failed, greaterThan(0));
    // The active (partial, empty) new-version directory must survive so a
    // later run can finish topping it up rather than starting over.
    expect(Directory(incomplete.tileDirPath).existsSync(), isTrue);
    expect(old1.existsSync(), isTrue);
  });

  test(
      'purge-by-count reclaims the oldest sibling beyond 2 even when this run had failures',
      () async {
    final root = await Directory.systemTemp.createTemp('cov');
    final oldest = Directory('${root.path}/OLDEST');
    final middle = Directory('${root.path}/MIDDLE');
    for (final (dir, ageMinutes) in [(oldest, 30), (middle, 20)]) {
      final f = File('${dir.path}/${knownPaths.first}');
      await f.create(recursive: true);
      await f.writeAsBytes(tileBytes);
      await f.setLastModified(
          DateTime.now().subtract(Duration(minutes: ageMinutes)));
    }

    final c = MockClient((req) async {
      if (req.url.path.endsWith('manifest.json')) {
        final m = manifestFor(knownPaths)..['dataset_version'] = 'NEW-VERSION';
        return http.Response(jsonEncode(m), 200);
      }
      return http.Response('not found', 404); // every tile fails
    });
    final repo = CoverageRepository(root: root, client: c);

    final incomplete = await repo.ensureCoverage(lat, lon);
    expect(incomplete.failed, greaterThan(0));
    // Unconditional purge-by-count: even with failures this run, the
    // active dir + MIDDLE (2 most recent) survive; OLDEST is reclaimed.
    expect(oldest.existsSync(), isFalse);
    expect(middle.existsSync(), isTrue);
    expect(Directory(incomplete.tileDirPath).existsSync(), isTrue);
  });

  test(
      'purge-by-count keeps the more complete sibling over the more recent '
      'one — completeness before recency (item 10, churn scenario)',
      () async {
    final root = await Directory.systemTemp.createTemp('cov');
    // MORE-COMPLETE is the older of the two siblings by mtime, but has every
    // tile this dataset point needs (all 3 of knownPaths). LESS-COMPLETE is
    // newer, but only has one — e.g. a version the app churned away from
    // mid-download, or partially purged by an earlier LRU pass. With only
    // recency to go on, LESS-COMPLETE would win the single remaining slot;
    // completeness-first must instead keep MORE-COMPLETE, since a version
    // with more of its tiles on disk is more useful offline than a merely
    // newer, thinner one.
    final moreComplete = Directory('${root.path}/MORE-COMPLETE');
    for (final path in knownPaths) {
      final f = File('${moreComplete.path}/$path');
      await f.create(recursive: true);
      await f.writeAsBytes(tileBytes);
      await f.setLastModified(
          DateTime.now().subtract(const Duration(minutes: 30)));
    }
    final lessComplete = Directory('${root.path}/LESS-COMPLETE');
    final onlyTile = File('${lessComplete.path}/${knownPaths.first}');
    await onlyTile.create(recursive: true);
    await onlyTile.writeAsBytes(tileBytes);
    await onlyTile.setLastModified(
        DateTime.now().subtract(const Duration(minutes: 5)));

    final c = MockClient((req) async {
      if (req.url.path.endsWith('manifest.json')) {
        final m = manifestFor(knownPaths)..['dataset_version'] = 'NEW-VERSION';
        return http.Response(jsonEncode(m), 200);
      }
      return http.Response('not found', 404); // every tile fails this run
    });
    final repo = CoverageRepository(root: root, client: c);

    await repo.ensureCoverage(lat, lon);

    expect(moreComplete.existsSync(), isTrue,
        reason: 'more complete despite being older');
    expect(lessComplete.existsSync(), isFalse,
        reason: 'newer but thinner — reclaimed in favour of completeness');
  });

  group('valhalla_version guard', () {
    Map<String, dynamic> badVersionManifest() =>
        manifestFor(knownPaths)..['valhalla_version'] = '4.0.0';

    test('rejects a fresh manifest whose valhalla_version mismatches, '
        'throwing DatasetVersionMismatch when no cache exists', () async {
      final root = await Directory.systemTemp.createTemp('cov');
      final c = MockClient((req) async {
        if (req.url.path.endsWith('manifest.json')) {
          return http.Response(jsonEncode(badVersionManifest()), 200);
        }
        return http.Response('not found', 404);
      });
      final repo = CoverageRepository(root: root, client: c);
      await expectLater(repo.ensureCoverage(lat, lon),
          throwsA(isA<DatasetVersionMismatch>()));
    });

    test(
        'falls back to the cached manifest (still usable) when the fresh one mismatches',
        () async {
      final root = await Directory.systemTemp.createTemp('cov');
      // Warm a good, matching-version cache first.
      final goodRepo = CoverageRepository(root: root, client: client());
      final good = await goodRepo.ensureCoverage(lat, lon);
      expect(good.versionMismatch, isFalse);

      // Now the server starts serving a manifest for an engine version this
      // app build does not ship.
      final badClient = MockClient((req) async {
        if (req.url.path.endsWith('manifest.json')) {
          return http.Response(jsonEncode(badVersionManifest()), 200);
        }
        return http.Response('not found', 404);
      });
      final repo = CoverageRepository(root: root, client: badClient);
      final res = await repo.ensureCoverage(lat, lon);

      expect(res.versionMismatch, isTrue);
      // Still routes against the last good (cached) dataset version.
      expect(res.datasetVersion, good.datasetVersion);
      expect(res.tileDirPath, good.tileDirPath);
      for (final p in knownPaths) {
        expect(File('${res.tileDirPath}/$p').existsSync(), isTrue);
      }
    });

    test(
        'does not overwrite the manifest cache with a version-mismatched fetch',
        () async {
      final root = await Directory.systemTemp.createTemp('cov');
      final goodRepo = CoverageRepository(root: root, client: client());
      await goodRepo.ensureCoverage(lat, lon);
      final cacheBefore =
          await File('${root.path}/manifest.cache.json').readAsString();

      final badClient = MockClient((req) async {
        if (req.url.path.endsWith('manifest.json')) {
          return http.Response(jsonEncode(badVersionManifest()), 200);
        }
        return http.Response('not found', 404);
      });
      final repo = CoverageRepository(root: root, client: badClient);
      await repo.ensureCoverage(lat, lon);

      final cacheAfter =
          await File('${root.path}/manifest.cache.json').readAsString();
      expect(cacheAfter, cacheBefore);
    });
  });
}
