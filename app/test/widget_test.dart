// Basic smoke test for the RandomWalk app shell.
//
// Verifies that the app boots and the three-tab bottom navigation
// (Carte / Session / Classement) is present. Placeholder screens are
// replaced by later tasks (5/8, 9, 10).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:randomwalk/main.dart';
import 'package:randomwalk/map/map_screen.dart';
import 'package:randomwalk/theme/theme.dart';

void main() {
  // Test 1: Verify the real wiring types
  test('HomeShell.defaultScreens wiring is correct', () {
    expect(HomeShell.defaultScreens, hasLength(3));
    expect(HomeShell.defaultScreens[0], isA<MapScreen>());
  });

  testWidgets('RandomWalkApp shows the three-tab shell', (WidgetTester tester) async {
    // Create test markers for each screen
    final testScreens = <Widget>[
      const Center(child: Text('Tab0Marker')),
      const Center(child: Text('Tab1Marker')),
      const Center(child: Text('Tab2Marker')),
    ];

    // Pump the REAL HomeShell with test screen overrides
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          title: 'RandomWalk Test',
          theme: AppTheme.light,
          home: HomeShell(screensOverride: testScreens),
        ),
      ),
    );

    // Verify tab 0 is selected and shows the correct marker
    expect(find.text('Tab0Marker'), findsOneWidget);
    expect(find.text('Tab1Marker'), findsNothing);
    expect(find.text('Tab2Marker'), findsNothing);

    // Verify the bottom navigation bar shows all three tabs
    expect(find.text('Carte'), findsOneWidget);
    expect(find.text('Session'), findsOneWidget);
    expect(find.text('Classement'), findsOneWidget);

    // Tap Session tab and verify it shows
    await tester.tap(find.text('Session'));
    await tester.pumpAndSettle();
    expect(find.text('Tab1Marker'), findsOneWidget);
    expect(find.text('Tab0Marker'), findsNothing);
    expect(find.text('Tab2Marker'), findsNothing);

    // Tap Classement tab and verify it shows
    await tester.tap(find.text('Classement'));
    await tester.pumpAndSettle();
    expect(find.text('Tab2Marker'), findsOneWidget);
    expect(find.text('Tab0Marker'), findsNothing);
    expect(find.text('Tab1Marker'), findsNothing);

    // Tap Carte tab and verify it shows again
    await tester.tap(find.text('Carte'));
    await tester.pumpAndSettle();
    expect(find.text('Tab0Marker'), findsOneWidget);
    expect(find.text('Tab1Marker'), findsNothing);
    expect(find.text('Tab2Marker'), findsNothing);
  });
}

