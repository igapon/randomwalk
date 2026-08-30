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
