import 'dart:math' as math;

/// Valhalla tile grid: level 0 = 4°, 1 = 1°, 2 = 0.25°.
/// Tiles are row-major from (-90, -180). File paths group the zero-padded
/// id into 3-digit segments, e.g. level 2 id 756425 -> "2/000/756/425.gph".
class TileId {
  final int level;
  final int index;
  const TileId(this.level, this.index);

  static const List<double> sizes = [4.0, 1.0, 0.25];
  static const List<int> pathDigits = [6, 6, 9];

  static int columns(int level) => (360 / sizes[level]).round();

  factory TileId.fromLatLon(int level, double lat, double lon) {
    final size = sizes[level];
    final row = ((lat + 90) / size).floor();
    final col = ((lon + 180) / size).floor();
    return TileId(level, row * columns(level) + col);
  }

  String get path {
    final s = index.toString().padLeft(pathDigits[level], '0');
    final groups = <String>[
      for (var i = 0; i < s.length; i += 3) s.substring(i, i + 3),
    ];
    return '$level/${groups.join('/')}.gph';
  }

  @override
  bool operator ==(Object other) =>
      other is TileId && other.level == level && other.index == index;
  @override
  int get hashCode => Object.hash(level, index);
  @override
  String toString() => 'TileId($level, $index)';
}

const _kmPerDegLat = 111.32;

List<TileId> tilesCoveringCircle(
  int level,
  double lat,
  double lon,
  double radiusKm,
) {
  final size = TileId.sizes[level];
  final dLat = radiusKm / _kmPerDegLat;
  final cosLat = math.cos(lat * math.pi / 180).abs().clamp(0.01, 1.0);
  final dLon = radiusKm / (_kmPerDegLat * cosLat);
  final rowMin = (((lat - dLat).clamp(-90.0, 89.999) + 90) / size).floor();
  final rowMax = (((lat + dLat).clamp(-90.0, 89.999) + 90) / size).floor();
  final colMin = (((lon - dLon).clamp(-180.0, 179.999) + 180) / size).floor();
  final colMax = (((lon + dLon).clamp(-180.0, 179.999) + 180) / size).floor();
  return [
    for (var r = rowMin; r <= rowMax; r++)
      for (var c = colMin; c <= colMax; c++)
        TileId(level, r * TileId.columns(level) + c),
  ];
}
