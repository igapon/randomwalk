import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/pois.dart';

void main() {
  const churchLat = 46.5200, churchLon = 6.6300;
  const bankLat = 46.5210, bankLon = 6.6310;
  const cafeLat = 46.9000, cafeLon = 7.4000; // far away, different cell

  final fixtureJson = jsonEncode([
    {
      'id': 'node/1',
      'kind': 'reveal',
      'lat': churchLat,
      'lon': churchLon,
      'name': 'Église Saint-Pierre',
    },
    {
      'id': 'node/2',
      'kind': 'coins',
      'lat': bankLat,
      'lon': bankLon,
    },
    {
      'id': 'node/3',
      'kind': 'energy',
      'subkind': 'cafe',
      'lat': cafeLat,
      'lon': cafeLon,
      'name': 'Café Central',
    },
  ]);

  Future<File> writeFixture(Directory dir,
      {required String name, required bool gzipped}) async {
    final file = File('${dir.path}/$name');
    final bytes = utf8.encode(fixtureJson);
    await file.writeAsBytes(gzipped ? gzip.encode(bytes) : bytes);
    return file;
  }

  group('GamePoi.tryParse', () {
    test('parses a full entry', () {
      final poi = GamePoi.tryParse({
        'id': 'node/1',
        'kind': 'energy',
        'subkind': 'restaurant',
        'lat': 46.5,
        'lon': 6.6,
        'name': 'Chez Fondue',
      });
      expect(poi, isNotNull);
      expect(poi!.id, 'node/1');
      expect(poi.kind, PoiKind.energy);
      expect(poi.subkind, 'restaurant');
      expect(poi.lat, 46.5);
      expect(poi.lon, 6.6);
      expect(poi.name, 'Chez Fondue');
    });

    test('parses a minimal entry (no subkind/name)', () {
      final poi = GamePoi.tryParse(
          {'id': 'way/2', 'kind': 'reveal', 'lat': 1.0, 'lon': 2.0});
      expect(poi, isNotNull);
      expect(poi!.subkind, isNull);
      expect(poi.name, isNull);
    });

    test('rejects an unknown kind', () {
      expect(
          GamePoi.tryParse(
              {'id': 'node/1', 'kind': 'bogus', 'lat': 1.0, 'lon': 2.0}),
          isNull);
    });

    test('rejects entries missing required fields', () {
      expect(GamePoi.tryParse({'kind': 'reveal', 'lat': 1.0, 'lon': 2.0}),
          isNull);
      expect(GamePoi.tryParse({'id': 'node/1', 'lat': 1.0, 'lon': 2.0}),
          isNull);
      expect(GamePoi.tryParse({'id': 'node/1', 'kind': 'reveal', 'lon': 2.0}),
          isNull);
    });

    test('rejects non-map input', () {
      expect(GamePoi.tryParse('not a map'), isNull);
      expect(GamePoi.tryParse(null), isNull);
      expect(GamePoi.tryParse([1, 2, 3]), isNull);
    });
  });

  group('PoiStore.load', () {
    test('loads a gzipped fixture and reports the correct count', () async {
      final dir = await Directory.systemTemp.createTemp('pois');
      final file = await writeFixture(dir, name: 'pois.json.gz', gzipped: true);
      final store = await PoiStore.load(file);
      expect(store.count, 3);
    });

    test('a plain (non-gzipped) file fails gzip decode -> PoiStore.empty',
        () async {
      final dir = await Directory.systemTemp.createTemp('pois');
      final file =
          await writeFixture(dir, name: 'pois.json', gzipped: false);
      final store = await PoiStore.load(file);
      expect(store.count, 0);
      expect(identical(store, PoiStore.empty), isTrue);
    });

    test('a missing file resolves to PoiStore.empty', () async {
      final dir = await Directory.systemTemp.createTemp('pois');
      final file = File('${dir.path}/does_not_exist.json.gz');
      final store = await PoiStore.load(file);
      expect(store.count, 0);
      expect(identical(store, PoiStore.empty), isTrue);
    });

    test('gzip of garbage (not JSON) resolves to PoiStore.empty', () async {
      final dir = await Directory.systemTemp.createTemp('pois');
      final file = File('${dir.path}/garbage.json.gz');
      await file.writeAsBytes(gzip.encode(utf8.encode('not json at all {{{')));
      final store = await PoiStore.load(file);
      expect(store.count, 0);
    });

    test('gzip of a JSON object (not a list) resolves to PoiStore.empty',
        () async {
      final dir = await Directory.systemTemp.createTemp('pois');
      final file = File('${dir.path}/object.json.gz');
      await file.writeAsBytes(gzip.encode(utf8.encode(jsonEncode({'a': 1}))));
      final store = await PoiStore.load(file);
      expect(store.count, 0);
    });

    test('skips malformed entries but keeps the valid ones', () async {
      final dir = await Directory.systemTemp.createTemp('pois');
      final mixed = jsonEncode([
        {'id': 'node/1', 'kind': 'reveal', 'lat': 1.0, 'lon': 2.0},
        {'id': 'node/2', 'kind': 'not-a-kind', 'lat': 1.0, 'lon': 2.0},
        {'kind': 'coins', 'lat': 1.0, 'lon': 2.0}, // missing id
      ]);
      final file = File('${dir.path}/mixed.json.gz');
      await file.writeAsBytes(gzip.encode(utf8.encode(mixed)));
      final store = await PoiStore.load(file);
      expect(store.count, 1);
    });
  });

  group('PoiStore.near', () {
    late PoiStore store;

    setUp(() async {
      final dir = await Directory.systemTemp.createTemp('pois');
      final file = await writeFixture(dir, name: 'pois.json.gz', gzipped: true);
      store = await PoiStore.load(file);
    });

    test('finds POIs within radius, excludes far ones', () {
      final nearby = store.near(churchLat, churchLon, 500);
      final ids = nearby.map((p) => p.id).toSet();
      expect(ids.contains('node/1'), isTrue); // the church itself
      expect(ids.contains('node/2'), isTrue); // bank ~130m away
      expect(ids.contains('node/3'), isFalse); // cafe is far away
    });

    test('a tight radius excludes a POI in a neighboring cell', () {
      final nearby = store.near(churchLat, churchLon, 5);
      expect(nearby.map((p) => p.id), ['node/1']);
    });

    test('empty store.near never throws and returns nothing', () {
      expect(PoiStore.empty.near(0, 0, 1000), isEmpty);
    });
  });
}
