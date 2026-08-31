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
  /// True when the manifest actually used this run is a stale cached copy
  /// kept because the freshly-fetched one had a `valhalla_version` this app
  /// build cannot use (see [DatasetVersionMismatch]). The caller should
  /// warn the user that new coverage needs an app update.
  final bool versionMismatch;
  const CoverageResult(
      {required this.datasetVersion,
      required this.tileDirPath,
      required this.downloaded,
      required this.failed,
      required this.total,
      this.versionMismatch = false});
}

/// A manifest fetch outcome: the manifest to use, plus whether it is a
/// cached fallback kept because the fresh fetch's engine version mismatched
/// (see [DatasetVersionMismatch]).
class _ManifestFetch {
  final TileManifest manifest;
  final bool versionMismatch;
  const _ManifestFetch(this.manifest, {required this.versionMismatch});
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
  Future<_ManifestFetch> _fetchManifest() async {
    try {
      final resp = await client.get(Uri.parse(CoverageConfig.manifestUrl));
      if (resp.statusCode != 200) {
        throw HttpException('manifest: HTTP ${resp.statusCode}');
      }
      final manifest =
          TileManifest.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
      if (manifest.valhallaVersion != kExpectedValhallaVersion) {
        // Never adopt (or cache) a manifest built for an engine version this
        // app build does not ship — routing against it could crash or
        // silently misroute. Fall back to whatever cached manifest already
        // exists on disk, exactly like a network failure, but flag it so
        // the caller can tell the user new coverage needs an app update.
        final cached = await _readManifestCache();
        if (cached != null) {
          return _ManifestFetch(cached, versionMismatch: true);
        }
        throw DatasetVersionMismatch(manifest.valhallaVersion);
      }
      await _writeManifestCache(resp.body);
      return _ManifestFetch(manifest, versionMismatch: false);
    } catch (_) {
      final cached = await _readManifestCache();
      if (cached != null) return _ManifestFetch(cached, versionMismatch: false);
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

  /// The tile directory of the dataset already on disk, or null if there is
  /// none. Touches neither the network nor the tiles themselves.
  ///
  /// Exists for the tracking service, which is handed this path at trip
  /// start and routes against it offline for the rest of the walk (see
  /// `NavSeed`). Deliberately *not* [ensureCoverage]: that one downloads,
  /// and a foreground service has no way to tell a user it is doing so.
  Future<String?> cachedTileDirPath() async {
    final manifest = await _readManifestCache();
    if (manifest == null) return null;
    final dir = Directory('${root.path}/${manifest.datasetVersion}');
    return await dir.exists() ? dir.path : null;
  }

  List<String> neededPaths(double lat, double lon) => [
        for (final e in CoverageConfig.radiiKmByLevel.entries)
          for (final t in tilesCoveringCircle(e.key, lat, lon, e.value)) t.path
      ];

  Future<CoverageResult> ensureCoverage(double lat, double lon,
      {void Function(int done, int total)? onProgress}) async {
    final fetch = await _fetchManifest();
    final manifest = fetch.manifest;
    final tileDir = Directory('${root.path}/${manifest.datasetVersion}');
    await tileDir.create(recursive: true);
    _sweepPartFiles(tileDir);
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
    // Purge-by-count runs unconditionally, even when this run had failed
    // downloads: unlike the old failed==0 gate, it never deletes the
    // directory actually in use ([tileDir]/[manifest.datasetVersion]) — a
    // partial new version is always left in place for a later run to
    // finish topping it up — so it cannot destroy the offline guarantee
    // ensureCoverage/plan() provide. It only reclaims *other* sibling
    // version directories once more than [_keepVersionCount] of them have
    // at least one tile on disk.
    await _purgeByCount(manifest.datasetVersion);
    return CoverageResult(
        datasetVersion: manifest.datasetVersion,
        tileDirPath: tileDir.path,
        downloaded: downloaded,
        failed: failed,
        total: wanted.length,
        versionMismatch: fetch.versionMismatch);
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

  /// How many sibling `<root>/<version>/` directories [_purgeByCount] keeps
  /// around, [activeVersion]'s included.
  static const _keepVersionCount = 2;

  /// Disk-hygiene purge-by-count: deletes sibling `<root>/<version>/`
  /// directories beyond the [_keepVersionCount] most complete/recently
  /// touched ones, so switching dataset versions repeatedly cannot grow disk
  /// usage without bound. Runs unconditionally — including after a run whose
  /// downloads failed (unlike the old failed==0-gated full purge this
  /// replaces).
  ///
  /// [activeVersion] — the directory this very run downloaded into/read
  /// from, i.e. the one backing the manifest cache — is never deleted,
  /// regardless of its completeness or recency: deleting it would break the
  /// offline guarantee ensureCoverage/plan() provide for the version
  /// currently in use. Sibling directories with no tile file at all (e.g.
  /// leftover empty dirs) are swept unconditionally, since they cannot serve
  /// any offline route anyway. The manifest cache file lives directly under
  /// [root] (not inside a version dir) and is always left untouched.
  ///
  /// Item 10 (review carry-over): a sibling is kept over another primarily
  /// because it has *more* tiles on disk, not because it is merely newer — a
  /// version the app churned away from mid-download (or thinned by an
  /// earlier LRU pass) is less useful offline than an older-but-fuller one,
  /// even if its mtime looks more recent. Recency only breaks ties between
  /// siblings with the same tile count.
  Future<void> _purgeByCount(String activeVersion) async {
    if (!root.existsSync()) return;
    final candidates = <(Directory dir, int tileCount, DateTime newestTile)>[];
    for (final entry in root.listSync()) {
      if (entry is! Directory) continue;
      final name = entry.path.replaceAll('\\', '/').split('/').last;
      if (name == activeVersion) continue;
      final tiles = entry
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.gph'))
          .toList();
      if (tiles.isEmpty) {
        await entry.delete(recursive: true);
        continue;
      }
      // Recency of a version dir is that of its most recently touched tile
      // file — a directory's own mtime is not reliably updated by every
      // platform/filesystem when a child file changes.
      final newest = tiles
          .map((f) => f.lastModifiedSync())
          .reduce((a, b) => a.isAfter(b) ? a : b);
      candidates.add((entry, tiles.length, newest));
    }
    // The active version always occupies one of the kept slots.
    final otherSlots = _keepVersionCount - 1;
    if (candidates.length <= otherSlots) return;
    // Completeness first (more tiles on disk survives), recency only as the
    // tie-breaker between equally complete siblings.
    candidates.sort((a, b) {
      final byCompleteness = b.$2.compareTo(a.$2);
      return byCompleteness != 0 ? byCompleteness : b.$3.compareTo(a.$3);
    });
    for (final (dir, _, _) in candidates.skip(otherSlots)) {
      await dir.delete(recursive: true);
    }
  }
}
