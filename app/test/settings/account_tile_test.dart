import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/settings/account_tile.dart';

void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: AccountTile())),
      ),
    );
  }

  testWidgets('shows the unconfigured subtitle with no backend configured', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('Compte'), findsOneWidget);
    expect(find.text('Synchronisation non configurée'), findsOneWidget);
  });

  testWidgets('tapping the tile while unconfigured opens an explanatory '
      'dialog instead of navigating', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Compte'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(AccountScreenPlaceholder), findsNothing);
    expect(find.textContaining("n'est pas configurée"), findsOneWidget);

    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
