import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/settings/theme_mode_provider.dart';
import 'package:randomwalk/settings/theme_mode_store.dart';
import 'package:randomwalk/settings/theme_mode_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    ThemeMode initial = ThemeMode.system,
  }) async {
    final container = ProviderContainer(
      overrides: [themeModeProvider.overrideWith((ref) => initial)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ThemeModeTile())),
      ),
    );
    return container;
  }

  testWidgets('shows "Thème" with the current mode\'s French label as '
      'subtitle', (tester) async {
    await pump(tester, initial: ThemeMode.system);
    expect(find.text('Thème'), findsOneWidget);
    expect(find.text('Système'), findsOneWidget);
  });

  testWidgets('subtitle reflects Jour/Nuit when already set', (tester) async {
    await pump(tester, initial: ThemeMode.dark);
    expect(find.text('Nuit'), findsOneWidget);
  });

  testWidgets('tapping the tile opens a dialog with all three options', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Thème'));
    await tester.pumpAndSettle();

    final dialog = find.byType(SimpleDialog);
    expect(dialog, findsOneWidget);
    Finder inDialog(String text) =>
        find.descendant(of: dialog, matching: find.text(text));
    expect(inDialog('Système'), findsOneWidget);
    expect(inDialog('Jour'), findsOneWidget);
    expect(inDialog('Nuit'), findsOneWidget);
  });

  testWidgets('choosing "Jour" applies it IMMEDIATELY — the provider '
      'updates without any restart/reload, before the persistence write '
      'even needs to complete', (tester) async {
    final container = await pump(tester, initial: ThemeMode.system);

    await tester.tap(find.text('Thème'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(SimpleDialog),
        matching: find.text('Jour'),
      ),
    );
    // A single pump (not pumpAndSettle) is enough for the provider write —
    // proving this doesn't wait on the SharedPreferences round trip (or the
    // dialog's own closing animation) to reflect the choice.
    await tester.pump();

    expect(container.read(themeModeProvider), ThemeMode.light);

    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing); // dialog closed itself.
  });

  testWidgets('choosing "Nuit" persists it — a later ThemeModeStore().load() '
      'sees the new choice (survives a cold start)', (tester) async {
    await pump(tester, initial: ThemeMode.system);

    await tester.tap(find.text('Thème'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nuit'));
    await tester.pumpAndSettle();

    expect(await ThemeModeStore().load(), ThemeMode.dark);
  });

  testWidgets('the tile\'s own subtitle updates once the provider changes '
      '(rebuilds live, not just the dialog\'s own state)', (tester) async {
    await pump(tester, initial: ThemeMode.system);

    await tester.tap(find.text('Thème'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nuit'));
    await tester.pumpAndSettle();

    expect(find.text('Nuit'), findsOneWidget); // now the tile's subtitle.
    expect(find.text('Système'), findsNothing);
  });
}
