import '../game/pois.dart';
import '../nav/polyline_math.dart' show metersBetween;

/// Cap on how many landmark symbols the Aventure map ever draws at once
/// (Task 6 perf constraint: "cap ~200 nearest").
const kMaxAdventureSymbols = 200;

/// MapLibre `addImage` ids for the six landmark glyph variants: one per
/// [PoiKind], each in a filled (visited) and outlined (unvisited) version —
/// see `adventure_screen.dart`'s icon registration, which renders these with
/// [WaymarkDiamond]'s color-per-kind scheme (yellow reveal / hydro coins /
/// terre energy) via `waymarkDiamondPng`.
String poiIconId(PoiKind kind, {required bool visited}) {
  final suffix = visited ? 'filled' : 'outline';
  return 'adventure-poi-${kind.name}-$suffix';
}

/// The [pois] closest to ([lat], [lon]), sorted nearest-first, capped at
/// [cap]. Pure sort-and-truncate — callers (typically `PoiStore.near`'s
/// result for some generous radius around the viewport center) are expected
/// to have already narrowed the candidate list to roughly the viewport's
/// neighborhood; this only handles the final "closest ~200" cap so the map
/// never tries to draw more symbols than that regardless of how many POIs
/// [pois] contains.
List<GamePoi> nearestPois(
  List<GamePoi> pois,
  double lat,
  double lon, {
  int cap = kMaxAdventureSymbols,
}) {
  final sorted = [...pois]
    ..sort(
      (a, b) => metersBetween(
        lat,
        lon,
        a.lat,
        a.lon,
      ).compareTo(metersBetween(lat, lon, b.lat, b.lon)),
    );
  return sorted.length <= cap ? sorted : sorted.sublist(0, cap);
}

/// One landmark symbol's map placement: everything `adventure_screen.dart`
/// needs to call `MapLibreMapController.addSymbol` with, computed as pure
/// data so the "which icon for which POI" decision is unit-testable without
/// touching a real controller.
class PoiSymbolSpec {
  final GamePoi poi;
  final String iconId;
  final bool visited;

  const PoiSymbolSpec({
    required this.poi,
    required this.iconId,
    required this.visited,
  });
}

/// Builds one [PoiSymbolSpec] per POI in [pois] (already capped/filtered by
/// the caller — see [nearestPois]), resolving each one's icon from its
/// [GamePoi.kind] and whether [visitedPoiIds] (the exact set
/// `GameState.visitedPoiIds` — keyed by bare `poiId`, any kind, per that
/// field's own doc comment in reducers.dart) contains its id.
List<PoiSymbolSpec> buildPoiSymbolSpecs(
  List<GamePoi> pois,
  Set<String> visitedPoiIds,
) {
  return [
    for (final poi in pois)
      PoiSymbolSpec(
        poi: poi,
        visited: visitedPoiIds.contains(poi.id),
        iconId: poiIconId(poi.kind, visited: visitedPoiIds.contains(poi.id)),
      ),
  ];
}
