import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/theme/waymark_glyph.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('WaymarkDiamond renders a rotated square', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: WaymarkDiamond(size: 24, color: Colors.black)),
      ),
    );
    expect(find.byType(WaymarkDiamond), findsOneWidget);
    final transform = tester.widget<Transform>(find.byType(Transform));
    expect(
      transform.transform.getRotation().entry(0, 0),
      closeTo(0.7071, 0.01),
    );
  });

  test('waymarkDiamondPng renders valid PNG bytes', () async {
    final bytes = await waymarkDiamondPng(
      sizePx: 32,
      color: const Color(0xFF1C2B25),
    );
    expect(bytes.length, greaterThan(8));
    // PNG magic number.
    expect(bytes.sublist(0, 8), [
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
    ]);
  });

  test('waymarkDiamondPng supports an outline (contour) variant', () async {
    final bytes = await waymarkDiamondPng(
      sizePx: 32,
      color: const Color(0xFF1C2B25),
      filled: false,
    );
    expect(bytes.sublist(0, 8), [
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
    ]);
  });
}
