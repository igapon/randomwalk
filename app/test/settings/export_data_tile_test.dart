import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/game_state_provider.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/settings/data_export.dart';
import 'package:randomwalk/sync/account_state.dart';
import 'package:randomwalk/sync/providers.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/temp_dir.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('export_tile_test');
  });

  tearDown(() => deleteTempDirRetrying(tempDir));

  /// Taps the export tile then lets the real `dart:io` work `_export` fires
  /// off (unawaited by the widget's `onTap`) actually complete before
  /// returning — same issue/fix as `account_screen_test.dart`'s
  /// `tapAndWait`: a fake-clock `pump`/`pumpAndSettle` alone doesn't
  /// observe an unawaited async method's result.
  Future<void> tapExport(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.text('Exporter mes données'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
  }

  /// Reads back the exported file's JSON payload. **Must** run inside
  /// `runAsync` — root cause of the CI hang this replaces a bare
  /// `await file.readAsString()` for (see `task-6-report.md`'s corrected
  /// writeup): any real `dart:io` await issued directly in a `testWidgets`
  /// body, even one that never touches a fake `Timer`, only actually
  /// resolves when driven from inside `tester.runAsync` — the two tests
  /// that did this as a bare `await` (outside `runAsync`) hung for the
  /// full 10-minute per-test framework timeout on CI (both Linux and,
  /// consistent with that, locally on Windows — this was never an
  /// environment-specific flake). The one test that never read the file
  /// back (share-failure path) never hit this and always passed, which is
  /// what pointed at the bare awaits specifically rather than `ListTile`/
  /// `share_plus`/`sqflite`/`path_provider`, every one of which was ruled
  /// out individually beforehand.
  Future<Map<String, dynamic>> readExportedPayload(
    WidgetTester tester,
    ShareParams params,
  ) => tester
      .runAsync(() async {
        final file = File(params.files!.single.path);
        final content = await file.readAsString();
        return jsonDecode(content) as Map<String, dynamic>;
      })
      .then((v) => v!);

  Future<void> pump(
    WidgetTester tester, {
    required DataExporter exporter,
    AccountState account = const AccountState.unconfigured(),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountStateProvider.overrideWith((ref) => account),
          gameJournalProvider.overrideWith(
            (ref) async => GameJournal(Directory('${tempDir.path}/journal')),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: ExportDataTile(exporter: exporter)),
        ),
      ),
    );
  }

  /// Every test here injects `edgesCounter`/`tempDirResolver` — deliberately
  /// never touching the real `EdgesStore`/`sqflite` or `path_provider`
  /// plugin channel in a widget test: those seams exist specifically so
  /// this file can stay a plain widget test (see `DataExporter`'s own doc
  /// comments) — `edges_store_test.dart`/`local_purge_test.dart` cover the
  /// real `EdgesStore`, and `data_export_test.dart` covers the payload
  /// shape directly.
  DataExporter exporterWith({
    required Future<ShareResult> Function(ShareParams) share,
  }) => DataExporter(
    share: share,
    edgesCounter: (_) async => 0,
    tempDirResolver: () async => tempDir,
  );

  testWidgets(
    'is reachable and works with no account configured at all — export is '
    'local-first, per task-6-brief.md',
    (tester) async {
      ShareParams? captured;
      final exporter = exporterWith(
        share: (params) async {
          captured = params;
          return const ShareResult('ok', ShareResultStatus.success);
        },
      );

      await pump(
        tester,
        exporter: exporter,
        account: const AccountState.unconfigured(),
      );
      await tapExport(tester);

      expect(captured, isNotNull);
      final payload = await readExportedPayload(tester, captured!);
      expect(payload['appVersion'], kAppVersion);
      expect(payload['account'], isNull);
      expect(payload['journal'], isEmpty);
      expect(payload['edgesCoveredCount'], 0);
    },
  );

  testWidgets('includes the account uid/email in the payload once signed in', (
    tester,
  ) async {
    ShareParams? captured;
    final exporter = exporterWith(
      share: (params) async {
        captured = params;
        return const ShareResult('ok', ShareResultStatus.success);
      },
    );

    await pump(
      tester,
      exporter: exporter,
      account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
    );
    await tapExport(tester);

    final payload = await readExportedPayload(tester, captured!);
    expect(payload['account'], {'uid': 'u1', 'email': 'a@b.ch'});
  });

  testWidgets(
    'a share failure surfaces a French snackbar instead of crashing — '
    'game-never-blocks applies to export too',
    (tester) async {
      final exporter = exporterWith(
        share: (_) async => throw Exception('boom'),
      );

      await pump(tester, exporter: exporter);
      await tapExport(tester);

      expect(
        find.text("L'export a échoué. Réessayez plus tard."),
        findsOneWidget,
      );
    },
  );
}
