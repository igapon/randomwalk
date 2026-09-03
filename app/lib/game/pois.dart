import 'dart:convert';
import 'dart:io';

import '../nav/polyline_math.dart';
import 'grid.dart';

/// Reward category of a game landmark — see the M4 event contract
/// (task-1-report.md) for `reveal`/`coins`/`energy`, and Task 2k's brief for
/// `culture`:
///  - `reveal`: churches, viewpoints, towers, historic sites — no economy
///    effect, just fog reveal (+XP on first visit, as every kind gets).
///  - `culture`: Task 2k's replacement for the game's whole landmark
///    dataset — place of worship / monument / museum / artwork / viewpoint /
///    castle / ruins (see `GamePoi.subkind` and `randomwalk-tiles/tools/
///    extract_pois.py` for the exact OSM mapping). Same fog-reveal effect as
///    `reveal`, PLUS a one-time energy refill on a landmark's first-ever
///    visit ("reprendre son souffle devant un monument" — see
///    `GameVisitConsumer`'s doc comment for why it's first-visit-only rather
///    than a repeatable cooldown like the old `energy` kind).
///  - `coins` (banks/ATMs) and `energy` (restaurants/cafes/fast-food):
///    **retired by Task 2k** (owner veto: "les restaurants et banques sont
///    pas une bonne idée"). Kept as parseable enum values — and the
///    `landmark_visited`/`coins_earned`/`energy_changed` reducer paths that
///    already understood them stay untouched forever, so an event already
///    written to a journal keeps replaying identically (locked M4 schema) —
///    but [PoiStore.load] excludes them from the live index (see
///    [_isLiveKind]), so an old cached `pois.json.gz` still holding bank/
///    restaurant entries never shows or lets a walker visit one again. A
///    fresh tile release (Task 2k) no longer emits them at all.
enum PoiKind { reveal, coins, energy, culture }

PoiKind? _kindFromString(String s) {
  switch (s) {
    case 'reveal':
      return PoiKind.reveal;
    case 'coins':
      return PoiKind.coins;
    case 'energy':
      return PoiKind.energy;
    case 'culture':
      return PoiKind.culture;
    default:
      return null;
  }
}

/// Task 2k: whether [PoiStore.load] should index a POI of this [kind] at
/// all — `false` for the two retired kinds (see [PoiKind]'s doc comment),
/// `true` for `reveal` and `culture`. A retired-kind POI still parses fine
/// via [GamePoi.tryParse] (it is a well-formed, well-typed value — nothing
/// about parsing itself changed), it just never makes it into the store's
/// `near()`-queryable index, which is what actually keeps it off the map and
/// out of [VisitDetector]'s candidate list.
bool _isLiveKind(PoiKind kind) =>
    kind != PoiKind.coins && kind != PoiKind.energy;

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
  String toString() =>
      'GamePoi($id, $kind${subkind != null ? '/$subkind' : ''})';
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
/// whole store. Task 2k: entries of a retired kind (`coins`/`energy` — see
/// [PoiKind]'s doc comment) parse fine but are then excluded from the index
/// too (see [_isLiveKind]), for the same "never shown" reason.
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
          if (GamePoi.tryParse(item) case final poi?)
            if (_isLiveKind(poi.kind)) poi,
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
