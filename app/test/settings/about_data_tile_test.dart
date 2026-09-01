import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/settings/settings_screen.dart';

void main() {
  testWidgets(
    'AboutDataTile opens a dialog mentioning OpenStreetMap, OpenFreeMap and Valhalla',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: AboutDataTile())),
      );

      expect(find.text('À propos des données'), findsOneWidget);
      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();

      final dialogText = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data ?? '')
          .join('\n');
      expect(dialogText, contains('OpenStreetMap'));
      expect(dialogText, contains('ODbL'));
      expect(dialogText, contains('OpenFreeMap'));
      expect(dialogText, contains('Valhalla'));

      await tester.tap(find.text('Fermer'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
}
