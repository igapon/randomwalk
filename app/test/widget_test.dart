// Basic smoke test for the RandomWalk app shell.
//
// Verifies that the app boots and the three-tab bottom navigation
// (Carte / Session / Classement) is present. Placeholder screens are
// replaced by later tasks (5/8, 9, 10).

import 'package:flutter_test/flutter_test.dart';

import 'package:randomwalk/main.dart';

void main() {
  testWidgets('RandomWalkApp shows the three-tab shell', (WidgetTester tester) async {
    await tester.pumpWidget(const RandomWalkApp());

    expect(find.text('Carte'), findsWidgets);
    expect(find.text('Session'), findsOneWidget);
    expect(find.text('Classement'), findsOneWidget);

    await tester.tap(find.text('Session'));
    await tester.pumpAndSettle();

    expect(find.text('Session'), findsWidgets);
  });
}
