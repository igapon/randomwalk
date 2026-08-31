import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/valhalla/grid.dart';

void main() {
  // Reference point from the Valhalla docs (« why tiles »):
  // (41.413203, -73.623787) → level-2 tile id 756425.
  const lat = 41.413203, lon = -73.623787;

  test('level sizes and ids match the valhalla scheme', () {
    expect(TileId.fromLatLon(2, lat, lon).index, 756425);
    expect(TileId.fromLatLon(1, lat, lon).index, 47266);
    expect(TileId.fromLatLon(0, lat, lon).index, 2906);
  });

  test('file paths are zero-padded in groups of three', () {
    expect(TileId.fromLatLon(2, lat, lon).path, '2/000/756/425.gph');
    expect(TileId.fromLatLon(1, lat, lon).path, '1/047/266.gph');
    expect(TileId.fromLatLon(0, lat, lon).path, '0/002/906.gph');
  });

  test('covering circle includes neighbors across tile edges', () {
    // 46.52,6.63 (Lausanne), rayon 45 km → plusieurs tuiles L2, incluant celle du centre
    final tiles = tilesCoveringCircle(2, 46.52, 6.63, 45);
    expect(tiles, contains(TileId.fromLatLon(2, 46.52, 6.63)));
    expect(tiles.length, inInclusiveRange(9, 36));
    // pas de doublons
    expect(tiles.toSet().length, tiles.length);
  });

  test('zero radius yields exactly the containing tile', () {
    expect(tilesCoveringCircle(2, 46.52, 6.63, 0), hasLength(1));
  });
}
