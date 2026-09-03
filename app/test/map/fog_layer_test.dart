// `FogLayer` itself drives a real `MapLibreMapController` (a platform
// view) and cannot be unit- or widget-tested directly — same story as
// `AdventureScreen`/`MapScreen` (see `adventure_screen_test.dart`'s own
// doc comment). `FogPaint` is the pure-data half of `map/fog_layer.dart`
// (the theme -> paint-value mapping) and *is* fully testable in isolation.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show Brightness;
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/grid.dart';
import 'package:randomwalk/map/fog_geometry.dart';
import 'package:randomwalk/map/fog_layer.dart';
import 'package:randomwalk/theme/tokens.dart';

void main() {
  group('FogPaint', () {
    test('light matches the brief\'s pinned paper veil (#F7F8F4, ~85%)', () {
      expect(FogPaint.light.fillColorHex, '#F7F8F4');
      expect(FogPaint.light.fillColorHex, AppColors.fogPaperHex);
      expect(FogPaint.light.fillOpacity, closeTo(0.85, 0.001));
    });

    test('dark matches the brief\'s pinned ink veil (#12201A, ~85%)', () {
      expect(FogPaint.dark.fillColorHex, '#12201A');
      expect(FogPaint.dark.fillColorHex, AppColors.fogDarkHex);
      expect(FogPaint.dark.fillOpacity, closeTo(0.85, 0.001));
    });

    test('both themes carry a soft halo (non-zero blur, partial opacity)', () {
      for (final paint in [FogPaint.light, FogPaint.dark]) {
        expect(paint.haloBlur, greaterThan(0));
        expect(paint.haloOpacity, greaterThan(0));
        expect(paint.haloOpacity, lessThan(1));
      }
    });

    test(
      'forBrightness selects light for light/unspecified, dark for dark',
      () {
        expect(FogPaint.forBrightness(Brightness.light), same(FogPaint.light));
        expect(FogPaint.forBrightness(Brightness.dark), same(FogPaint.dark));
      },
    );

    test('toFillLayerProperties carries the exact fill color/opacity', () {
      final props = FogPaint.light.toFillLayerProperties();
      expect(props.fillColor, FogPaint.light.fillColorHex);
      expect(props.fillOpacity, FogPaint.light.fillOpacity);
      expect(props.fillAntialias, isTrue);
    });

    test('toLineLayerProperties carries the exact halo color/blur/width', () {
      final props = FogPaint.dark.toLineLayerProperties();
      expect(props.lineColor, FogPaint.dark.haloColorHex);
      expect(props.lineBlur, FogPaint.dark.haloBlur);
      expect(props.lineWidth, FogPaint.dark.haloWidth);
      expect(props.lineOpacity, FogPaint.dark.haloOpacity);
    });
  });

  group('FogLayerIds', () {
    test('source and layer ids are distinct and stable strings', () {
      expect(FogLayerIds.source, isNotEmpty);
      expect(FogLayerIds.fillLayer, isNotEmpty);
      expect(FogLayerIds.haloLayer, isNotEmpty);
      expect({
        FogLayerIds.source,
        FogLayerIds.fillLayer,
        FogLayerIds.haloLayer,
      }, hasLength(3));
    });
  });

  group('fogWorldGeoJsonOffUiIsolate', () {
    test('produces the exact same GeoJSON as calling fogWorldGeoJson '
        'directly — the isolate hop must not change the result', () async {
      final revealed = {
        const CellId(3, 3),
        const CellId(4, 3),
        const CellId(4, 4),
      };
      final direct = fogWorldGeoJson(revealed: revealed);
      final offIsolate = await fogWorldGeoJsonOffUiIsolate(revealed: revealed);
      expect(offIsolate, direct);
    });

    // Task 2l (owner: "la carte freeze au début"): the whole point of
    // routing this through `compute()` (see `FogLayer.update`'s doc
    // comment, and `fog_geometry_test.dart`'s adversarial perf tests for
    // WHY this computation can take hundreds of ms for a realistic
    // multi-trip revealed-cell history) is that the calling isolate's own
    // event loop stays free while it runs — no frozen map, no stalled
    // touch handling, no stuck animations — even though the heavy Dart
    // computation itself is exactly as slow as before.
    //
    // This is what a "the UI isolate was NOT blocked" regression actually
    // looks like without a running native map: a periodic `Timer` on the
    // CALLING isolate must keep firing throughout a computation heavy
    // enough that, run synchronously in-place, would itself have starved
    // that same event loop for the whole duration (see
    // `fog_geometry_test.dart`'s "MANY SEPARATE winding corridors" perf
    // test — a comparable input reliably takes >50ms run directly).
    test('does not block the calling isolate\'s event loop — a periodic timer '
        'keeps firing throughout a computation heavy enough to freeze a '
        'single-isolate app if run in place', () async {
      final revealed = _manyDisjointCorridors(count: 300, lengthCells: 150);

      var ticks = 0;
      final ticker = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => ticks++,
      );
      addTearDown(ticker.cancel);

      final sw = Stopwatch()..start();
      await fogWorldGeoJsonOffUiIsolate(revealed: revealed);
      sw.stop();
      ticker.cancel();

      // Sanity: this input is genuinely heavy — comparable inputs measure
      // well over 100ms run synchronously (see fog_geometry_test.dart).
      // A near-zero elapsed time here would mean the test stopped
      // exercising anything, not that the fix works.
      expect(sw.elapsedMilliseconds, greaterThan(20));
      // The actual regression guard: if this ran on the calling isolate
      // (the old, direct `fogWorldGeoJson` call), NOTHING else — including
      // this very timer — could run until it returned, so `ticks` would
      // stay at (or near) 0 for the whole `sw.elapsedMilliseconds`
      // duration. Seeing the timer fire repeatedly proves the calling
      // isolate's event loop kept running throughout.
      expect(ticks, greaterThan(2));
    });
  });
}

/// One long, thin, winding "corridor" of [lengthCells] cells — same
/// generator `fog_geometry_test.dart` uses for its own adversarial perf
/// tests, duplicated here (rather than exported) to keep this file's only
/// production dependency on `fog_layer.dart` itself.
Set<CellId> _corridor(int ox, int oy, int lengthCells, math.Random rng) {
  final cells = <CellId>{};
  var x = ox, y = oy;
  cells.add(CellId(x, y));
  const dirs = [(1, 0), (-1, 0), (0, 1), (0, -1)];
  var lastDir = 0;
  for (var i = 1; i < lengthCells; i++) {
    final dir = rng.nextDouble() < 0.7 ? lastDir : rng.nextInt(4);
    lastDir = dir;
    final (dx, dy) = dirs[dir];
    x += dx;
    y += dy;
    cells.add(CellId(x, y));
  }
  return cells;
}

Set<CellId> _manyDisjointCorridors({
  required int count,
  required int lengthCells,
  int seed = 42,
}) {
  final rng = math.Random(seed);
  final revealed = <CellId>{};
  final spacing = lengthCells + 20;
  final perRow = (math.sqrt(count)).ceil();
  for (var i = 0; i < count; i++) {
    final ox = (i % perRow) * spacing;
    final oy = (i ~/ perRow) * spacing;
    revealed.addAll(_corridor(ox, oy, lengthCells, rng));
  }
  return revealed;
}
