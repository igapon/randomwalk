/// Task 2j: the reusable "game layer" both `AdventureScreen` and `MapScreen`
/// install onto their own [MapLibreMapController] — fog-of-war (Task 2h's
/// `FogLayer`) plus the landmark diamond symbols (Task 6's icon registration
/// + nearest-POI placement), bundled behind one small stateful helper so
/// neither screen repeats the other's wiring.
///
/// Not a widget: both screens own their own native `MapLibreMap` (a platform
/// view neither can share), so there is nothing to extract at the widget
/// level without a much larger refactor the brief explicitly does not ask
/// for ("don't over-refactor MapScreen; a shared 'game layer installer'
/// helper both screens call is enough"). What *is* shared, and was
/// previously duplicated verbatim in `adventure_screen.dart`, is exactly
/// this: registering the six landmark icon variants, installing/updating
/// the fog source+layers, and deciding when to regenerate either.
///
/// One instance per screen (each owns its own `_iconsRegistered`/
/// `_landmarkSymbols`/fog-throttle state, scoped to that screen's own
/// controller) — never shared between `AdventureScreen` and `MapScreen`,
/// which have entirely separate native map instances.
///
/// **Style-swap caveat** (Task 2h, now doubly relevant since `MapScreen`
/// also remounts `MapLibreMap` under a fresh `ValueKey(styleUrl)` on every
/// brightness flip): a remount tears down the previous native map instance
/// and everything drawn on it. [reset] must be called from the new
/// `onMapCreated`, and [install] again from the new `onStyleLoadedCallback`
/// — the same two-step every pre-existing caller (`adventure_screen.dart`)
/// already followed for `FogLayer` alone.
library;

import 'package:flutter/material.dart' show Brightness, debugPrint;
import 'package:maplibre_gl/maplibre_gl.dart';

import '../adventure/fog_regen.dart';
import '../adventure/poi_symbols.dart';
import '../game/grid.dart' show CellId;
import '../game/pois.dart';
import '../game/reducers.dart' show GameState;
import '../nav/polyline_math.dart' show metersBetween;
import '../theme/tokens.dart';
import '../theme/waymark_glyph.dart';
import 'fog_layer.dart';

Set<CellId> parseRevealedCells(GameState state) => {
  for (final key in state.revealedCellKeys)
    if (CellId.parseKey(key) case final parsed?) parsed,
};

/// Icon color per [PoiKind] — the Aventure map's own scheme (yellow reveal /
/// terre culture, brief: "iconographie culturelle (losanges terre
/// #B0552F)"), now shared verbatim by whichever screen installs this layer.
///
/// Task 2k: no entries for the retired `coins`/`energy` kinds — a POI of
/// either kind can never make it into a [PoiStore]'s live index any more
/// (see `pois.dart`'s `_isLiveKind`), so no code path here ever needs to
/// resolve an icon for one. `PoiKind.values` (all four) is still what
/// `poi_symbols_test.dart` walks generically, so those two kinds simply stay
/// unregistered rather than being removed from the enum outright — see that
/// enum's own doc comment for why.
const _kPoiColorsByKind = {
  PoiKind.reveal: AppColors.yellow,
  PoiKind.culture: AppColors.terre,
};

class GameLayer {
  GameLayer({FogLayer? fog}) : _fog = fog ?? FogLayer() {
    _fogCoalescer = _newFogCoalescer();
  }

  final FogLayer _fog;

  /// Task 2l review fix round 1: single-flight/latest-wins coalescing
  /// around the (`compute()`-backed, potentially hundreds-of-ms) fog
  /// regeneration — see [SingleFlightCoalescer]'s own doc comment for the
  /// bug this fixes. `late` (not `final`): [reset] swaps in a brand new
  /// instance rather than mutating this one in place.
  late SingleFlightCoalescer<Set<CellId>, MapLibreMapController> _fogCoalescer;

  SingleFlightCoalescer<Set<CellId>, MapLibreMapController>
  _newFogCoalescer() => SingleFlightCoalescer(regen: _runFogRegen);

  bool _iconsRegistered = false;
  List<Symbol> _landmarkSymbols = const [];
  DateTime? _lastFogGen;
  int _lastRevealedVersion = -1;

  /// Whatever `clock` the most recent [refresh] call was given — read by
  /// [_runFogRegen] to stamp [_lastFogGen], since that closure is bound
  /// once (at construction/[reset] time) and so cannot close over any one
  /// call's own `clock` parameter directly.
  DateTime Function() _clock = DateTime.now;

  /// Whether the fog/halo layers are currently painted visible — mirrors
  /// the last [setVisible] call (defaults true, matching the "couche
  /// Aventure" default-ON rule). [refresh] still updates the fog geometry
  /// and redraws landmarks while this is false — turning the layer back on
  /// must show up-to-date content immediately, not whatever was last drawn
  /// before it was hidden.
  bool visible = true;

  /// Call from `onMapCreated`: this screen's [MapLibreMapController] is
  /// about to be replaced (fresh native map instance, or the very first
  /// one) — every native handle/throttle this class held for the OLD
  /// controller is now dead and must be dropped rather than reused against
  /// the new one.
  void reset() {
    _iconsRegistered = false;
    _landmarkSymbols = const [];
    _lastFogGen = null;
    _lastRevealedVersion = -1;
    // A brand new coalescer rather than resetting the old one in place: a
    // regen already in flight against the OLD (about-to-be-disposed)
    // controller is simply abandoned here — when it eventually resolves it
    // mutates an object nothing references any more, never this fresh one,
    // so it can't wedge or race the new controller's own first regen.
    _fogCoalescer = _newFogCoalescer();
  }

  /// Call once from `onStyleLoadedCallback` (must run after the style has
  /// finished loading — same requirement `FogLayer.install` and
  /// `addImage` already have). Installs the fog source/layers and
  /// registers the landmark icon images; safe to call again after a
  /// [reset] (a fresh style/controller), throws if called twice on the
  /// SAME style without a [reset] in between — same contract as
  /// `FogLayer.install` and every other `addXLayer`/`addImage` call in this
  /// codebase.
  Future<void> install(
    MapLibreMapController controller, {
    required Brightness brightness,
  }) async {
    await _fog.install(controller, brightness: brightness);
    await _registerIcons(controller);
  }

  Future<void> _registerIcons(MapLibreMapController controller) async {
    if (_iconsRegistered) return;
    for (final entry in _kPoiColorsByKind.entries) {
      for (final visited in const [true, false]) {
        final bytes = await waymarkDiamondPng(
          sizePx: 32,
          color: entry.value,
          filled: visited,
        );
        await controller.addImage(
          poiIconId(entry.key, visited: visited),
          bytes,
        );
      }
    }
    _iconsRegistered = true;
  }

  /// Shows/hides the fog fill+halo without touching its geometry
  /// (`setLayerVisibility` — cheap, no source rewrite) and drops any drawn
  /// landmark symbols when hiding (there is no per-symbol visibility toggle
  /// in this maplibre_gl version, so the plain "app doesn't know" removal
  /// [_removeLandmarkSymbols] already used is reused here). Turning it back
  /// on redraws nothing by itself — the next [refresh] call does that, same
  /// as any other state change this class reacts to.
  Future<void> setVisible(MapLibreMapController controller, bool value) async {
    visible = value;
    try {
      await controller.setLayerVisibility(FogLayerIds.fillLayer, value);
      await controller.setLayerVisibility(FogLayerIds.haloLayer, value);
    } catch (e) {
      // Best-effort, like every other layer call here — a style not fully
      // installed yet just means the toggle takes effect on the next
      // install/refresh instead of this frame.
      debugPrint('GameLayer setVisible($value) failed: $e');
    }
    if (!value) await _removeLandmarkSymbols(controller);
  }

  /// Regenerates the fog geometry (throttled — see [shouldRegenFog]) and
  /// redraws the nearest landmark symbols for the current viewport. A no-op
  /// for the fog when [shouldRegenFog] declines, and for landmarks when
  /// [store] is null (not loaded yet) or [visible] is false (nothing to
  /// draw while the layer is hidden — callers still call this on every
  /// state/camera change regardless of [visible], since it costs nothing
  /// to skip here and means the very next [setVisible] `true` has already
  /// fresh content queued up next refresh anyway).
  Future<void> refresh(
    MapLibreMapController controller, {
    required GameState state,
    PoiStore? store,
    DateTime Function() clock = DateTime.now,
  }) async {
    await _refreshFog(controller, state, clock);
    if (store != null) await _refreshLandmarks(controller, store, state);
  }

  /// Task 2l review fix round 1: [shouldRegenFog]'s own throttle is only
  /// even consulted when nothing is currently in flight — while a regen IS
  /// in flight, every trigger goes straight to [_fogCoalescer], which
  /// decides for itself whether this is a genuine change worth queuing
  /// (see [SingleFlightCoalescer]'s doc comment). Consulting
  /// [shouldRegenFog] unconditionally here (the pre-fix behavior) is
  /// exactly what let concurrent triggers each see "never generated yet"
  /// and spawn their own redundant `compute()` isolate.
  Future<void> _refreshFog(
    MapLibreMapController controller,
    GameState state,
    DateTime Function() clock,
  ) async {
    _clock = clock;
    final revealedVersion = state.revealedCellKeys.length;
    if (!_fogCoalescer.isInFlight) {
      final regen = shouldRegenFog(
        lastGen: _lastFogGen,
        now: clock(),
        lastRevealedVersion: _lastRevealedVersion,
        revealedVersion: revealedVersion,
      );
      if (!regen) return;
    }
    await _fogCoalescer.request(
      parseRevealedCells(state),
      revealedVersion,
      controller,
    );
  }

  /// The coalescer's `regen` callback — the actual (slow) fog rebuild.
  /// Errors are swallowed by [SingleFlightCoalescer._run] itself (matching
  /// this method's pre-2l-review-fix `try/catch`), so [_lastFogGen]/
  /// [_lastRevealedVersion] simply stay stale on failure, same as before —
  /// a later genuine trigger retries.
  Future<void> _runFogRegen(
    Set<CellId> revealed,
    int revealedVersion,
    MapLibreMapController controller,
  ) async {
    await _fog.update(controller, revealed: revealed);
    _lastFogGen = _clock();
    _lastRevealedVersion = revealedVersion;
  }

  Future<void> _refreshLandmarks(
    MapLibreMapController controller,
    PoiStore store,
    GameState state,
  ) async {
    if (!visible) return;
    final LatLngBounds bounds;
    try {
      bounds = await controller.getVisibleRegion();
    } catch (_) {
      return;
    }
    final centerLat =
        (bounds.southwest.latitude + bounds.northeast.latitude) / 2;
    final centerLon =
        (bounds.southwest.longitude + bounds.northeast.longitude) / 2;
    final radiusM =
        metersBetween(
              centerLat,
              centerLon,
              bounds.northeast.latitude,
              bounds.northeast.longitude,
            ) *
            1.2 +
        200;
    final nearby = store.near(centerLat, centerLon, radiusM);
    final capped = nearestPois(nearby, centerLat, centerLon);
    final specs = buildPoiSymbolSpecs(capped, state.visitedPoiIds);

    try {
      if (_landmarkSymbols.isNotEmpty) {
        await controller.removeSymbols(_landmarkSymbols);
        _landmarkSymbols = const [];
      }
      if (specs.isNotEmpty) {
        _landmarkSymbols = await controller.addSymbols([
          for (final s in specs)
            SymbolOptions(
              geometry: LatLng(s.poi.lat, s.poi.lon),
              iconImage: s.iconId,
              iconSize: 0.6,
            ),
        ]);
      }
    } catch (e) {
      // Landmarks are decoration on top of the fog — never worth crashing
      // the screen over.
      debugPrint('GameLayer landmark redraw failed: $e');
    }
  }

  Future<void> _removeLandmarkSymbols(MapLibreMapController controller) async {
    if (_landmarkSymbols.isEmpty) return;
    try {
      await controller.removeSymbols(_landmarkSymbols);
    } catch (_) {
      // Best-effort.
    }
    _landmarkSymbols = const [];
  }
}
