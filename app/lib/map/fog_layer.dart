import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart' show Brightness;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../game/grid.dart';
import '../theme/tokens.dart';
import 'fog_geometry.dart';

/// Stable MapLibre source/layer ids for the fog-of-war rendering — one
/// source, two layers (fill veil + halo boundary), shared by every screen
/// that draws the fog. Kept as one id per source/layer (rather than each
/// caller inventing its own string) so a screen can never accidentally
/// collide with another screen's fog ids if two screens' maps are ever
/// live at once — not currently possible (Aventure and the main map are
/// different tabs, each with its own [MapLibreMapController]), but Task 2j
/// adds the fog to the main map too, at which point this still holds:
/// each controller gets its own copy of these same ids, which is fine
/// since ids are only ever unique *within* one controller/style.
class FogLayerIds {
  FogLayerIds._();
  static const source = 'fog-of-war';
  static const fillLayer = 'fog-of-war-fill';
  static const haloLayer = 'fog-of-war-halo';
}

/// The fog's paint spec for one brightness — pure data, no MapLibre
/// dependency, so [forBrightness]'s exact values are unit-testable without
/// a native map (see `fog_layer_test.dart`).
///
/// Pinned direction (Task 2h brief): the fog reads as "papier non exploré"
/// (unexplored paper), not a grey checkerboard — a soft, semi-transparent
/// veil tinted per theme, with a blurred halo along the revealed/fog
/// frontier rather than a hard edge.
class FogPaint {
  const FogPaint({
    required this.fillColorHex,
    required this.fillOpacity,
    required this.haloColorHex,
    required this.haloWidth,
    required this.haloBlur,
    required this.haloOpacity,
  });

  /// Light theme: paper veil, per the brief's exact pin (`#F7F8F4` ≈85%).
  static const light = FogPaint(
    fillColorHex: AppColors.fogPaperHex,
    fillOpacity: 0.85,
    haloColorHex: AppColors.fogPaperHex,
    haloWidth: 3,
    haloBlur: 6,
    haloOpacity: 0.55,
  );

  /// Dark theme: ink veil, per the brief's exact pin (`#12201A` ≈85%).
  static const dark = FogPaint(
    fillColorHex: AppColors.fogDarkHex,
    fillOpacity: 0.85,
    haloColorHex: AppColors.fogDarkHex,
    haloWidth: 3,
    haloBlur: 6,
    haloOpacity: 0.55,
  );

  final String fillColorHex;
  final double fillOpacity;
  final String haloColorHex;
  final double haloWidth;
  final double haloBlur;
  final double haloOpacity;

  static FogPaint forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// Filters to just the `kind == 'fill'` feature — see
  /// `fog_geometry.dart`'s `fogWorldGeoJson` doc comment for why the source
  /// carries two features (fill + halo) needing two different layers.
  static const fillFilter = [
    '==',
    ['get', 'kind'],
    'fill',
  ];
  static const haloFilter = [
    '==',
    ['get', 'kind'],
    'halo',
  ];

  FillLayerProperties toFillLayerProperties() => FillLayerProperties(
    fillColor: fillColorHex,
    fillOpacity: fillOpacity,
    fillAntialias: true,
  );

  LineLayerProperties toLineLayerProperties() => LineLayerProperties(
    lineColor: haloColorHex,
    lineWidth: haloWidth,
    lineBlur: haloBlur,
    lineOpacity: haloOpacity,
  );
}

Map<String, dynamic> _emptyFeatureCollection() => const {
  'type': 'FeatureCollection',
  'features': <dynamic>[],
};

/// Reusable fog-of-war rendering component: owns the MapLibre source/layer
/// wiring (stable ids, in-place updates) and the theme-reactive paint —
/// deliberately independent of any one screen so both the Aventure tab
/// (this task) and the main map (Task 2j, once exploration lands there)
/// draw the exact same fog from the exact same code.
///
/// Usage per screen: call [install] once from `onStyleLoadedCallback` (the
/// source/layers must exist before anything else touches them), then
/// [update] whenever the revealed cell set changes, and [applyTheme] if the
/// screen ever repaints an existing style in place rather than remounting
/// on a brightness flip (today's screens remount `MapLibreMap` under a new
/// `ValueKey(styleUrl)` on brightness change, which already calls
/// [install] fresh with the new brightness — see `adventure_screen.dart`
/// and `map_screen.dart` — so [applyTheme] exists for a future caller that
/// doesn't remount, not because today's callers need it).
class FogLayer {
  /// Adds the fog source (initially empty — [update] fills it in) and its
  /// two paint layers (fill veil + halo), in that order so the halo draws
  /// on top of the fill. Safe to call once per fresh style load; calling it
  /// again on the SAME style (without a remount) would throw on the
  /// duplicate source/layer ids — that is intentional, matching every other
  /// `addXLayer` call in this codebase (`adventure_screen.dart`,
  /// `map_screen.dart`): callers only ever call this from
  /// `onStyleLoadedCallback`, which fires once per style instance.
  Future<void> install(
    MapLibreMapController controller, {
    required Brightness brightness,
    String? belowLayerId,
  }) async {
    final paint = FogPaint.forBrightness(brightness);
    await controller.addGeoJsonSource(
      FogLayerIds.source,
      _emptyFeatureCollection(),
    );
    await controller.addFillLayer(
      FogLayerIds.source,
      FogLayerIds.fillLayer,
      paint.toFillLayerProperties(),
      filter: FogPaint.fillFilter,
      belowLayerId: belowLayerId,
      enableInteraction: false,
    );
    await controller.addLineLayer(
      FogLayerIds.source,
      FogLayerIds.haloLayer,
      paint.toLineLayerProperties(),
      filter: FogPaint.haloFilter,
      enableInteraction: false,
    );
  }

  /// Regenerates the fog geometry for the current [revealed] set and pushes
  /// it into the existing source via `setGeoJsonSource` — same stable
  /// [FogLayerIds.source] id every time (never removed/re-added), the same
  /// "update in place" pattern `map_screen.dart`'s `_redrawRouteLine` uses
  /// for the route line (`updateLine`, Task 2e). The geometry itself
  /// ([fogWorldGeoJson]) is a pure function of [revealed] alone — no
  /// viewport is read here or anywhere downstream, which is the actual fix
  /// for "fog of war ... changes when i move the map" (see
  /// `fog_geometry.dart`'s doc comment for the full root-cause writeup).
  ///
  /// Task 2l (owner: "la carte freeze au début"): [fogWorldGeoJson] is
  /// `O(rings^2 * ring_length)` in the CONTAINMENT classification
  /// (`_ringDepths`/`_tightestContainer`), not `O(cells)` — the existing
  /// Task 2h perf test only ever measured a solid block (one ring) and
  /// uniform 3x3 blobs (tiny 4-vertex rings each), both of which keep that
  /// term cheap. A real player's `revealedCellKeys` instead accumulates from
  /// many separate WALKS, each a long, thin, winding corridor whose traced
  /// ring is roughly as long as the walk itself (a corridor barely cancels
  /// any of its own interior edges) — measured (see
  /// `fog_geometry_bench_test.dart`): 300 disjoint 150-cell corridors
  /// (34k cells, a very ordinary multi-month history) already cost ~210ms
  /// on the calling isolate; 600 corridors cost ~760ms. Run on the UI
  /// isolate at the first `onStyleLoaded` (via `GameLayer.refresh` /
  /// `_refreshGameLayer`, called unconditionally the first time — see
  /// `shouldRegenFog`'s "never generated yet" rule), that reads exactly as
  /// the owner described: the map "freezes" for the whole synchronous
  /// duration — animations, scrolling and touch handling all stall, because
  /// nothing else on the UI isolate's event loop can run until it returns.
  ///
  /// Fixed by moving the actual computation to [compute] — a real, separate
  /// isolate, same pattern `poi_loader.dart`'s `loadPoiStoreOffUiIsolate`
  /// already uses for the POI parse (also once suspected, but already
  /// off-isolate: see that file's own doc comment). The UI isolate's event
  /// loop stays free for the whole duration; `setGeoJsonSource` still runs
  /// here once the result comes back, so the fog simply appears a little
  /// after the map itself rather than blocking it. No caller needs to
  /// change: this method's signature and contract (world-in-coordinates,
  /// pure function of [revealed]) are unchanged, only WHERE the pure part
  /// of the work happens.
  Future<void> update(
    MapLibreMapController controller, {
    required Set<CellId> revealed,
    double cellM = cellSizeM,
  }) async {
    final geojson = await fogWorldGeoJsonOffUiIsolate(
      revealed: revealed,
      cellM: cellM,
    );
    await controller.setGeoJsonSource(
      FogLayerIds.source,
      jsonDecode(geojson) as Map<String, dynamic>,
    );
  }

  /// Repaints the fill/halo layers for [brightness] without touching the
  /// source's geometry — see the class doc comment for why today's callers
  /// don't need this (they remount on brightness change instead).
  Future<void> applyTheme(
    MapLibreMapController controller,
    Brightness brightness,
  ) async {
    final paint = FogPaint.forBrightness(brightness);
    await controller.setLayerProperties(
      FogLayerIds.fillLayer,
      paint.toFillLayerProperties(),
    );
    await controller.setLayerProperties(
      FogLayerIds.haloLayer,
      paint.toLineLayerProperties(),
    );
  }
}

/// Runs [fogWorldGeoJson] on a fresh background isolate via [compute] — see
/// [FogLayer.update]'s doc comment for the measured freeze this fixes.
/// Exposed as a standalone top-level function (not a private detail of
/// [FogLayer.update]) so it is directly unit-testable without a
/// [MapLibreMapController] — mirrors `poi_loader.dart`'s
/// `loadPoiStoreOffUiIsolate` sitting alongside `PoiStore.load`.
Future<String> fogWorldGeoJsonOffUiIsolate({
  required Set<CellId> revealed,
  double cellM = cellSizeM,
}) => compute(_fogWorldGeoJsonSync, (revealed, cellM));

/// Top-level (not a closure) so `compute` can hand it to a fresh isolate
/// without capturing any UI-isolate state — same requirement
/// `poi_loader.dart`'s `_loadPoiStoreSync` documents for the same reason.
/// `compute` takes exactly one argument, hence the record.
String _fogWorldGeoJsonSync((Set<CellId>, double) args) =>
    fogWorldGeoJson(revealed: args.$1, cellM: args.$2);
