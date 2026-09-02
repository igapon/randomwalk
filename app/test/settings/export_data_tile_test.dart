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

  /// Runs [action] inside `runAsync` — every real `dart:io` check these
  /// tests make after [tapExport] has to go through this: a bare `await`
  /// issued directly in a `testWidgets` body never resolves (the CI-fix
  /// commit's root cause — see that commit's `task-6-report.md` writeup),
  /// regardless of whether it happens inside the same `runAsync` call the
  /// tap used or, as here, a fresh one afterward.
  Future<T> real<T>(WidgetTester tester, Future<T> Function() action) =>
      tester.runAsync(action).then((v) => v as T);

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
  ///
  /// [share] is invoked from *inside* `DataExporter.exportAndShare`'s own
  /// async chain — before Task 6 review round 1's I3 fix deletes the temp
  /// file in a `finally` right after — so a caller that needs the file's
  /// content (not just its path) must read it here, synchronously with the
  /// share call, rather than after [tapExport] returns: by then the file is
  /// already gone (see the "cleans up" group below, which asserts exactly
  /// that).
  DataExporter exporterWith({
    required Future<ShareResult> Function(ShareParams) share,
  }) => DataExporter(
    share: share,
    edgesCounter: (_) async => 0,
    tempDirResolver: () async => tempDir,
  );

  /// Reads back an export file's JSON content — only ever safe to call
  /// *from inside* an injected `share` callback (see [exporterWith]'s own
  /// doc comment), never after [tapExport] has returned.
  Future<Map<String, dynamic>> payloadOf(ShareParams params) async {
    final content = await File(params.files!.single.path).readAsString();
    return jsonDecode(content) as Map<String, dynamic>;
  }

  testWidgets(
    'is reachable and works with no account configured at all — export is '
    'local-first, per task-6-brief.md',
    (tester) async {
      Map<String, dynamic>? payload;
      final exporter = exporterWith(
        share: (params) async {
          payload = await payloadOf(params);
          return const ShareResult('ok', ShareResultStatus.success);
        },
      );

      await pump(
        tester,
        exporter: exporter,
        account: const AccountState.unconfigured(),
      );
      await tapExport(tester);

      expect(payload, isNotNull);
      expect(payload!['appVersion'], kAppVersion);
      expect(payload!['account'], isNull);
      expect(payload!['journal'], isEmpty);
      expect(payload!['edgesCoveredCount'], 0);
    },
  );

  testWidgets('includes the account uid/email in the payload once signed in', (
    tester,
  ) async {
    Map<String, dynamic>? payload;
    final exporter = exporterWith(
      share: (params) async {
        payload = await payloadOf(params);
        return const ShareResult('ok', ShareResultStatus.success);
      },
    );

    await pump(
      tester,
      exporter: exporter,
      account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
    );
    await tapExport(tester);

    expect(payload!['account'], {'uid': 'u1', 'email': 'a@b.ch'});
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

  group('cleans up the temp export file (Task 6 review round 1, I3)', () {
    testWidgets('the export file is gone once the share has completed', (
      tester,
    ) async {
      ShareParams? captured;
      final exporter = exporterWith(
        share: (params) async {
          captured = params;
          return const ShareResult('ok', ShareResultStatus.success);
        },
      );

      await pump(tester, exporter: exporter);
      await tapExport(tester);

      final path = captured!.files!.single.path;
      expect(await real(tester, () => File(path).exists()), isFalse);
    });

    testWidgets(
      'the export file is deleted even when the share itself fails — a '
      'failed share must not leak a permanent copy either',
      (tester) async {
        String? writtenPath;
        final exporter = DataExporter(
          share: (params) async {
            writtenPath = params.files!.single.path;
            throw Exception('boom');
          },
          edgesCounter: (_) async => 0,
          tempDirResolver: () async => tempDir,
        );

        await pump(tester, exporter: exporter);
        await tapExport(tester);

        expect(writtenPath, isNotNull);
        expect(await real(tester, () => File(writtenPath!).exists()), isFalse);
      },
    );

    testWidgets(
      'sweeps a leftover export file from a previous run before writing '
      'its own — the backstop for the process dying between a write and '
      'its own delete',
      (tester) async {
        final leftover = File('${tempDir.path}/randomwalk_export_old.json');
        await real(tester, () async {
          await leftover.writeAsString('{"stale": true}');
        });

        ShareParams? captured;
        final exporter = exporterWith(
          share: (params) async {
            captured = params;
            return const ShareResult('ok', ShareResultStatus.success);
          },
        );

        await pump(tester, exporter: exporter);
        await tapExport(tester);

        expect(await real(tester, () => leftover.exists()), isFalse);
        // The new export's own file is cleaned up too, per the group above.
        expect(
          await real(tester, () => File(captured!.files!.single.path).exists()),
          isFalse,
        );
      },
    );
  });
}
