/// The Valhalla engine version this app ships (the embedded
/// `io.github.rallista:valhalla-mobile` AAR — see `ValhallaChannel.kt`).
/// A manifest built for a different engine version is never adopted: its
/// tile format may not be one the bundled engine can read. See
/// [DatasetVersionMismatch].
const kExpectedValhallaVersion = '3.6.2';

/// Thrown when a freshly-fetched manifest's `valhalla_version` does not
/// match [kExpectedValhallaVersion]. The tile server has published a
/// dataset built for a Valhalla engine newer (or otherwise different) than
/// the one bundled in this app build — routing needs an app update before
/// it can use it.
class DatasetVersionMismatch implements Exception {
  final String foundVersion;
  const DatasetVersionMismatch(this.foundVersion);
  @override
  String toString() => 'DatasetVersionMismatch: manifest valhalla_version '
      '"$foundVersion" != expected "$kExpectedValhallaVersion"';
}

class TileAsset {
  final String asset;
  final int bytes;
  final String sha256;
  const TileAsset({required this.asset, required this.bytes, required this.sha256});
  factory TileAsset.fromJson(Map<String, dynamic> j) => TileAsset(
      asset: j['asset'] as String,
      bytes: j['bytes'] as int,
      sha256: j['sha256'] as String);
}

class TileManifest {
  final String datasetVersion;
  final String valhallaVersion;
  final Map<String, TileAsset> tiles;
  const TileManifest(
      {required this.datasetVersion,
      required this.valhallaVersion,
      required this.tiles});
  factory TileManifest.fromJson(Map<String, dynamic> j) => TileManifest(
        datasetVersion: j['dataset_version'] as String,
        valhallaVersion: j['valhalla_version'] as String,
        tiles: (j['tiles'] as Map<String, dynamic>).map(
            (k, v) => MapEntry(k, TileAsset.fromJson(v as Map<String, dynamic>))),
      );
}
