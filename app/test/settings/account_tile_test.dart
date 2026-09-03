import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/sync/account_state.dart';
import 'package:randomwalk/sync/providers.dart';
import 'package:randomwalk/settings/account_screen.dart';
import 'package:randomwalk/settings/account_tile.dart';

import '../support/fake_sync_backend.dart';

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
    expect(find.byType(AccountScreen), findsNothing);
    expect(find.textContaining("n'est pas configurée"), findsOneWidget);

    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('tapping the tile while configured navigates to AccountScreen', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncBackendProvider.overrideWithValue(FakeSyncBackend()),
          accountStateProvider.overrideWith(
            (ref) => const AccountState.signedOut(),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: AccountTile())),
      ),
    );

    await tester.tap(find.text('Compte'));
    await tester.pumpAndSettle();

    expect(find.byType(AccountScreen), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
