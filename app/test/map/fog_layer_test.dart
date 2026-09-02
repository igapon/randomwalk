// `FogLayer` itself drives a real `MapLibreMapController` (a platform
// view) and cannot be unit- or widget-tested directly — same story as
// `AdventureScreen`/`MapScreen` (see `adventure_screen_test.dart`'s own
// doc comment). `FogPaint` is the pure-data half of `map/fog_layer.dart`
// (the theme -> paint-value mapping) and *is* fully testable in isolation.

import 'package:flutter/material.dart' show Brightness;
import 'package:flutter_test/flutter_test.dart';
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
}
