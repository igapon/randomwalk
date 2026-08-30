import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// The « losange de balisage » (waymark diamond) signature glyph: a square
/// rotated 45°, either outlined (departure marker, "A") or filled
/// (destination marker, "B", and the Démarrer pill icon).
///
/// Widget form, for use inside the Flutter widget tree (e.g. the pill
/// icon). For MapLibre markers — which need a raster image, not a widget —
/// see [waymarkDiamondPng].
class WaymarkDiamond extends StatelessWidget {
  const WaymarkDiamond({
    super.key,
    required this.size,
    required this.color,
    this.filled = true,
    this.strokeWidth = 2,
  });

  final double size;
  final Color color;
  final bool filled;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) => Transform.rotate(
        angle: 0.7853981633974483, // 45deg in radians
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: filled ? color : null,
            border: filled ? null : Border.all(color: color, width: strokeWidth),
          ),
        ),
      );
}

/// Renders a waymark diamond to PNG bytes for MapLibre's `addImage`, so A/B
/// route markers can use the same glyph as the rest of the identity instead
/// of the generic circle markers MapLibre ships with.
///
/// [sizePx] is the full square canvas size (the diamond touches its edges).
/// Needs a live Flutter binding (dart:ui rendering) — call from within the
/// app, or a `flutter_test` context with `TestWidgetsFlutterBinding`.
Future<Uint8List> waymarkDiamondPng({
  required double sizePx,
  required Color color,
  bool filled = true,
  double strokeWidth = 3,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final half = sizePx / 2;
  final inset = filled ? 0.0 : strokeWidth / 2;
  final path = Path()
    ..moveTo(half, inset)
    ..lineTo(sizePx - inset, half)
    ..lineTo(half, sizePx - inset)
    ..lineTo(inset, half)
    ..close();

  final paint = Paint()
    ..color = color
    ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
    ..strokeWidth = strokeWidth
    ..isAntiAlias = true;
  canvas.drawPath(path, paint);

  final picture = recorder.endRecording();
  final image =
      await picture.toImage(sizePx.round(), sizePx.round());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}
