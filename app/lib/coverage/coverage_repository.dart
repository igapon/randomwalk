import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../valhalla/grid.dart';
import 'manifest.dart';

class CoverageConfig {
  static const manifestUrl =
      'https://github.com/igapon/randomwalk-tiles/releases/latest/download/manifest.json';
  static String assetUrl(String version, String asset) =>
      'https://github.com/igapon/randomwalk-tiles/releases/download/$version/$asset';
  static const radiiKmByLevel = <int, double>{2: 45, 1: 120, 0: 400};
  static const maxCacheBytes = 300 * 1024 * 1024;
}

class CoverageResult {
  final String datasetVersion;
  final String tileDirPath;
  final int downloaded;
  final int failed;
  final int total;
  const CoverageResult(
      {required this.datasetVersion,
      required this.tileDirPath,
      required this.downloaded,
      required this.failed,
      required this.total});
}

class CoverageRepository {
  final Directory root;
  final http.Client client;
  CoverageRepository({required this.root, required this.client});

  String get _manifestCachePath => '${root.path}/manifest.cache.json';

  /// Fetches the manifest over the network and persists a copy at
  /// [_manifestCachePath] on success. When the network call fails for any
  /// reason (no connectivity, DNS failure, non-200 response, ...) this falls
  /// back to that cached copy — from the last successful fetch, possibly by
  /// an earlier app run — so routing keeps working offline as long as a
  /// dataset was ever downloaded. Only rethrows when no cache exists either.
  Future<TileManifest> _fetchManifest() async {
    try {
      final resp = await client.get(Uri.parse(CoverageConfig.manifestUrl));
      if (resp.statusCode != 200) {
        throw HttpException('manifest: HTTP ${resp.statusCode}');
      }
      await _writeManifestCache(resp.body);
      return TileManifest.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
    } catch (_) {
      final cached = await _readManifestCache();
      if (cached != null) return cached;
      rethrow;
    }
  }

  Future<void> _writeManifestCache(String rawJson) async {
    await root.create(recursive: true);
    await File(_manifestCachePath).writeAsString(rawJson, flush: true);
  }

  Future<TileManifest?> _readManifestCache() async {
    final f = File(_manifestCachePath);
    if (!f.existsSync()) return null;
    try {
      return TileManifest.fromJson(
          jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      // Corrupt/partial cache: treat as absent rather than crashing.
      return null;
    }
  }

  List<String> neededPaths(double lat, double lon) => [
        for (final e in CoverageConfig.radiiKmByLevel.entries)
          for (final t in tilesCoveringCircle(e.key, lat, lon, e.value)) t.path
      ];

  Future<CoverageResult> ensureCoverage(double lat, double lon,
      {void Function(int done, int total)? onProgress}) async {
    final manifest = await _fetchManifest();
    final tileDir = Directory('${root.path}/${manifest.datasetVersion}');
    await tileDir.create(recursive: true);
    _sweepPartFiles(tileDir);
    await _purgeOtherVersions(manifest.datasetVersion);
    final wanted = neededPaths(lat, lon)
        .where(manifest.tiles.containsKey)
        .toList();
    var downloaded = 0, failed = 0, done = 0;
    for (final path in wanted) {
      final file = File('${tileDir.path}/$path');
      var have = file.existsSync();
      if (!have) {
        final ok = await _download(manifest, path, file);
        ok ? downloaded++ : failed++;
        have = ok;
      }
      onProgress?.call(++done, wanted.length);
      // Only record LRU usage for tiles that actually exist on disk after
      // this pass — a failed download must not create a phantom entry.
      if (have) await _touch(tileDir, path);
    }
    await _purgeLru(tileDir);
    return CoverageResult(
        datasetVersion: manifest.datasetVersion,
        tileDirPath: tileDir.path,
        downloaded: downloaded,
        failed: failed,
        total: wanted.length);
  }

  Future<bool> _download(TileManifest m, String path, File dest) async {
    final asset = m.tiles[path]!;
    final url = CoverageConfig.assetUrl(m.datasetVersion, asset.asset);
    final http.Response resp;
    try {
      resp = await client.get(Uri.parse(url));
    } catch (_) {
      // Network failure mid-download (e.g. connectivity dropped): treat like
      // any other failed download rather than crashing ensureCoverage.
      return false;
    }
    if (resp.statusCode != 200 ||
        sha256.convert(resp.bodyBytes).toString() != asset.sha256) {
      return false;
    }
    final tmp = File('${dest.path}.part');
    await tmp.create(recursive: true);
    await tmp.writeAsBytes(resp.bodyBytes, flush: true);
    await tmp.rename(dest.path);
    return true;
  }

  /// LRU index: JSON map tile path -> last-used epoch ms, stored next to tiles.
  Future<void> _touch(Directory tileDir, String path) async {
    final f = File('${tileDir.path}/.lru.json');
    final map = f.existsSync()
        ? (jsonDecode(await f.readAsString()) as Map<String, dynamic>)
        : <String, dynamic>{};
    map[path] = DateTime.now().millisecondsSinceEpoch;
    await f.writeAsString(jsonEncode(map), flush: true);
  }

  Future<void> _purgeLru(Directory tileDir) async {
    final files = tileDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.gph'))
        .toList();
    var totalBytes = files.fold<int>(0, (s, f) => s + f.lengthSync());
    if (totalBytes <= CoverageConfig.maxCacheBytes) return;
    final lruFile = File('${tileDir.path}/.lru.json');
    final lru = lruFile.existsSync()
        ? (jsonDecode(await lruFile.readAsString()) as Map<String, dynamic>)
        : <String, dynamic>{};
    int lastUsed(File f) {
      final rel = f.path
          .substring(tileDir.path.length + 1)
          .replaceAll('\\', '/');
      return (lru[rel] as int?) ?? 0;
    }
    files.sort((a, b) => lastUsed(a).compareTo(lastUsed(b)));
    for (final f in files) {
      if (totalBytes <= CoverageConfig.maxCacheBytes) break;
      totalBytes -= f.lengthSync();
      f.deleteSync();
    }
  }

  /// Removes any `.part` temp file left behind by a download that was
  /// interrupted before the atomic rename in [_download] completed — these
  /// would otherwise accumulate forever, never being cleaned up or counted
  /// against the cache budget.
  void _sweepPartFiles(Directory tileDir) {
    if (!tileDir.existsSync()) return;
    for (final entry in tileDir.listSync(recursive: true)) {
      if (entry is File && entry.path.endsWith('.part')) {
        entry.deleteSync();
      }
    }
  }

  /// Deletes sibling `<root>/<otherVersion>/` directories once the manifest
  /// resolves to [currentVersion] — old dataset releases are never routed
  /// to again, so keeping their tiles around only wastes disk. The manifest
  /// cache file lives directly under [root] (not inside a version dir) and
  /// is left untouched.
  Future<void> _purgeOtherVersions(String currentVersion) async {
    if (!root.existsSync()) return;
    for (final entry in root.listSync()) {
      if (entry is! Directory) continue;
      final name = entry.path.replaceAll('\\', '/').split('/').last;
      if (name != currentVersion) {
        await entry.delete(recursive: true);
      }
    }
  }
}
