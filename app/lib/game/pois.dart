import 'dart:convert';
import 'dart:io';

import '../nav/polyline_math.dart';
import 'grid.dart';

/// Reward category of a game landmark — see the M4 event contract
/// (task-1-report.md): `reveal` (churches, viewpoints, towers, historic
/// sites — no economy effect, just fog reveal), `coins` (banks/ATMs),
/// `energy` (restaurants/cafes/fast-food).
enum PoiKind { reveal, coins, energy }

PoiKind? _kindFromString(String s) {
  switch (s) {
    case 'reveal':
      return PoiKind.reveal;
    case 'coins':
      return PoiKind.coins;
    case 'energy':
      return PoiKind.energy;
    default:
      return null;
  }
}

/// One game landmark, as delivered by the tiles repo's `pois.json.gz`
/// release asset (see `randomwalk-tiles/tools/extract_pois.py`).
class GamePoi {
  final String id;
  final PoiKind kind;
  final String? subkind;
  final double lat;
  final double lon;
  final String? name;

  const GamePoi({
    required this.id,
    required this.kind,
    this.subkind,
    required this.lat,
    required this.lon,
    this.name,
  });

  /// Parses one POI entry, or returns `null` for a malformed one (unknown
  /// `kind`, missing required field, wrong field type, ...) — a single bad
  /// entry must never take down the whole store; see [PoiStore.load].
  static GamePoi? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final kindStr = json['kind'];
    final lat = json['lat'];
    final lon = json['lon'];
    if (id is! String || kindStr is! String) return null;
    if (lat is! num || lon is! num) return null;
    final kind = _kindFromString(kindStr);
    if (kind == null) return null;
    final subkind = json['subkind'];
    final name = json['name'];
    return GamePoi(
      id: id,
      kind: kind,
      subkind: subkind is String ? subkind : null,
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      name: name is String ? name : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GamePoi &&
      other.id == id &&
      other.kind == kind &&
      other.subkind == subkind &&
      other.lat == lat &&
      other.lon == lon &&
      other.name == name;

  @override
  int get hashCode => Object.hash(id, kind, subkind, lat, lon, name);

  @override
  String toString() => 'GamePoi($id, $kind${subkind != null ? '/$subkind' : ''})';
}

/// In-memory index of game POIs, bucketed by the ~150 m exploration grid
/// cell ([CellId]) they fall in — the same grid `game/grid.dart` uses for
/// fog-of-war, so no second spatial-indexing scheme is introduced.
///
/// **Game never blocks the tool**: [load] never throws. A missing file, a
/// non-gzip file, invalid JSON, or a JSON value that isn't a list all
/// resolve to [PoiStore.empty] rather than propagating an error — the
/// landmark layer simply has nothing to show, exactly as if POIs were never
/// downloaded. Individual malformed *entries* inside an otherwise-valid list
/// are silently skipped (see [GamePoi.tryParse]) rather than voiding the
/// whole store.
class PoiStore {
  final Map<String, List<GamePoi>> _byCell;
  final int count;

  PoiStore._(this._byCell, this.count);

  /// The empty store — no POIs, [near] always returns an empty list. The
  /// safe fallback for "no usable POI data" (see the class doc comment).
  static final PoiStore empty = PoiStore._(const {}, 0);

  factory PoiStore._fromPois(List<GamePoi> pois) {
    final byCell = <String, List<GamePoi>>{};
    for (final poi in pois) {
      final key = cellIdFor(poi.lat, poi.lon).key;
      byCell.putIfAbsent(key, () => []).add(poi);
    }
    return PoiStore._(byCell, pois.length);
  }

  /// Loads a gzip-compressed POI list from [gz] (the `pois.json.gz` asset
  /// downloaded by `CoverageRepository`). See the class doc comment for the
  /// "never throws" contract.
  static Future<PoiStore> load(File gz) async {
    try {
      if (!await gz.exists()) return empty;
      final bytes = await gz.readAsBytes();
      final jsonBytes = gzip.decode(bytes);
      final decoded = jsonDecode(utf8.decode(jsonBytes));
      if (decoded is! List) return empty;
      final pois = <GamePoi>[
        for (final item in decoded)
          if (GamePoi.tryParse(item) case final poi?) poi,
      ];
      return PoiStore._fromPois(pois);
    } catch (_) {
      return empty;
    }
  }

  /// POIs within [radiusM] meters of ([lat], [lon]), any kind.
  ///
  /// Candidate cells come from [discCells] (the same corridor/reveal-radius
  /// bucketing `game/grid.dart` already implements) so this never has to
  /// scan the full POI list; results are then filtered to the exact
  /// distance since a POI can share a cell with the query point's
  /// neighborhood without truly being within [radiusM].
  List<GamePoi> near(double lat, double lon, double radiusM) {
    if (count == 0) return const [];
    final cells = discCells(lat, lon, radiusM);
    final result = <GamePoi>[];
    for (final cell in cells) {
      final bucket = _byCell[cell.key];
      if (bucket == null) continue;
      for (final poi in bucket) {
        if (metersBetween(lat, lon, poi.lat, poi.lon) <= radiusM) {
          result.add(poi);
        }
      }
    }
    return result;
  }
}
