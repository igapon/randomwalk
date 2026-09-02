import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../exploration/edges_store.dart';
import '../game/events.dart';
import '../game/game_state_provider.dart';
import '../session/recorder.dart';
import '../sync/account_state.dart';
import '../sync/providers.dart';
import 'identity.dart';

/// The app's version string, as declared in `pubspec.yaml`'s `version:`
/// field. Hardcoded rather than resolved via `package_info_plus` at
/// runtime — Task 6 deliberately avoided adding a second new native plugin
/// alongside `share_plus` (see `task-6-report.md`'s CI/AGP risk note).
/// **Keep this in sync by hand whenever `pubspec.yaml`'s `version:` line
/// changes.**
const kAppVersion = '1.0.0+1';

/// Filename prefix every export writes (`<prefix><epoch-ms>.json`) — shared
/// between the writer and [DataExporter]'s own leftover sweep so the sweep
/// only ever touches files this class itself created.
const _kExportFilePrefix = 'randomwalk_export_';

/// Builds the JSON payload [DataExporter.exportAndShare] writes to a file
/// and hands to the OS share sheet — factored out as a pure function (no
/// `dart:io`, no Riverpod, no `share_plus`) so its exact shape can be
/// pinned down by a plain unit test.
///
/// **Works UNCONFIGURED too, and with nobody signed in.** [journalEvents]/
/// [identity]/[totalKm]/[edgesCoveredCount] are all local-first data that
/// exists regardless of `SyncBackend` configuration or sign-in state —
/// only [accountUid]/[accountEmail] (both `null` unless
/// `AccountPhase.signedIn`) are account-dependent, and the `account` key of
/// the payload is `null` whenever they are, rather than the export itself
/// being unavailable.
Map<String, dynamic> buildExportPayload({
  required PlayerIdentity identity,
  required double totalKm,
  required List<GameEvent> journalEvents,
  required int edgesCoveredCount,
  String? accountUid,
  String? accountEmail,
  DateTime? exportedAt,
}) => {
  'appVersion': kAppVersion,
  'exportedAt': (exportedAt ?? DateTime.now()).toIso8601String(),
  'profile': {
    'userId': identity.userId,
    'pseudo': identity.pseudo,
    'totalKm': totalKm,
  },
  'account': accountUid == null
      ? null
      : {'uid': accountUid, 'email': accountEmail},
  'edgesCoveredCount': edgesCoveredCount,
  'journal': journalEvents.map((e) => e.toJson()).toList(),
};

/// Gathers this device's export payload (`buildExportPayload`) and hands it
/// to the platform share sheet as a JSON file, via `share_plus`.
///
/// RGPD "portabilité des données" — Task 6. Reachable from `Réglages` (not
/// gated on account state: see `SettingsScreen`'s `ExportDataTile`), which
/// is what makes it work for an UNCONFIGURED install as well as a
/// configured-but-signed-out one — every input this class reads (identity,
/// journal, edges count) is local, and the `account` section of the
/// payload simply reflects whatever `accountStateProvider` currently says.
class DataExporter {
  const DataExporter({
    Future<ShareResult> Function(ShareParams params)? share,
    Future<int> Function(String edgesDbPath)? edgesCounter,
    Future<Directory> Function()? tempDirResolver,
  }) : _share = share ?? _defaultShare,
       _edgesCounter = edgesCounter ?? _defaultEdgesCounter,
       _tempDirResolver = tempDirResolver ?? getTemporaryDirectory;

  /// Injectable seam for tests — defaults to the real `share_plus` call.
  final Future<ShareResult> Function(ShareParams params) _share;

  /// Injectable seam for tests — defaults to opening the real on-disk
  /// [EdgesStore]. Factored out (rather than inlined in [exportAndShare])
  /// so a widget test can supply a trivial fake and never have to touch
  /// `sqflite`/its native connection at all — only `local_purge_test.dart`
  /// and `edges_store_test.dart` need the real thing, both plain (non-
  /// widget) tests where `sqflite_common_ffi` behaves.
  final Future<int> Function(String edgesDbPath) _edgesCounter;

  /// Injectable seam for tests — defaults to `path_provider`'s real
  /// `getTemporaryDirectory()`. Lets a widget test hand this a plain temp
  /// [Directory] instead of swapping the global `PathProviderPlatform
  /// .instance`.
  final Future<Directory> Function() _tempDirResolver;

  static Future<ShareResult> _defaultShare(ShareParams params) =>
      SharePlus.instance.share(params);

  static Future<int> _defaultEdgesCounter(String path) async {
    final store = await EdgesStore.open(path);
    try {
      return await store.totalCount;
    } finally {
      await store.close();
    }
  }

  /// Builds the payload, writes it to a temp JSON file, and summons the
  /// share sheet. Lets any failure (journal read error, disk full,
  /// `share_plus` plugin failure) propagate to the caller — this class does
  /// no I/O-error swallowing of its own, by design: `ExportDataTile` is the
  /// single call site and is the one place that decides how to surface a
  /// failure to the player (a snackbar, never a crash — "game-never-blocks"
  /// applies to export too, just enforced one layer up).
  ///
  /// **Cleans up after itself (Task 6 review round 1, Important I3).** The
  /// export file is written into the OS cache/temp directory
  /// ([_tempDirResolver], `path_provider`'s `getTemporaryDirectory()` by
  /// default — never the app-support directory, so nothing here is a
  /// permanent copy by construction) and deleted again once [_share]
  /// settles, success or failure alike (`try`/`finally`: a share-sheet
  /// failure must not leak a copy of the user's exported personal data any
  /// more than a successful share should). As a backstop for the one case
  /// that can't go through this method's own cleanup — the process dying
  /// between the write and the delete — every call also sweeps any
  /// `$_kExportFilePrefix*.json` leftovers from a previous run before
  /// writing its own file, so at most one export's worth of temp data can
  /// ever accumulate.
  Future<void> exportAndShare(WidgetRef ref) async {
    final identity = await ref.read(identityStoreProvider).get();
    final totalKm = await TotalDistanceStore().totalKm();
    final journal = await ref.read(gameJournalProvider.future);
    final events = await journal.readAll();
    final account = ref.read(accountStateProvider);

    var edgesCount = 0;
    try {
      edgesCount = await _edgesCounter(
        '${journal.dir.parent.path}/covered_edges.db',
      );
    } catch (_) {
      // Best-effort: an unreadable/missing edges store exports as 0 rather
      // than failing the whole export over a count that is, worst case,
      // slightly stale — the journal (the actual source of truth for
      // gameplay) is unaffected by this failing.
    }

    final payload = buildExportPayload(
      identity: identity,
      totalKm: totalKm,
      journalEvents: events,
      edgesCoveredCount: edgesCount,
      accountUid: account.phase == AccountPhase.signedIn ? account.uid : null,
      accountEmail: account.phase == AccountPhase.signedIn
          ? account.email
          : null,
    );

    final tempDir = await _tempDirResolver();
    await _sweepLeftoverExports(tempDir);

    final file = File(
      '${tempDir.path}/$_kExportFilePrefix'
      '${DateTime.now().millisecondsSinceEpoch}.json',
    );
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );

    try {
      await _share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/json')],
          subject: 'Export RandomWalk',
          text: 'Export de mes données RandomWalk',
        ),
      );
    } finally {
      // Best-effort: this file has done its job either way — a failed
      // delete here just means the next export's own sweep (below) picks
      // it up.
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  /// Deletes any `$_kExportFilePrefix*.json` file already sitting in
  /// [tempDir] — a previous export's temp file that [exportAndShare]'s own
  /// `finally` couldn't clean up (the process died between the write and
  /// the delete being the only realistic way that happens). Best-effort and
  /// silent: a sweep failure must never block the export it's guarding.
  Future<void> _sweepLeftoverExports(Directory tempDir) async {
    try {
      await for (final entity in tempDir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.startsWith(_kExportFilePrefix) && name.endsWith('.json')) {
          try {
            await entity.delete();
          } catch (_) {
            // Best-effort per-file too: one stuck leftover must not stop
            // the rest of the sweep, let alone the export itself.
          }
        }
      }
    } catch (_) {
      // tempDir itself unreadable/missing — nothing to sweep.
    }
  }
}

/// Settings entry point for [DataExporter] — Task 6. Lives in
/// `SettingsScreen` (`Réglages`), NOT `AccountScreen`: unlike `AccountTile`,
/// which is reachable but only ever opens an explanatory dialog when
/// `AccountPhase.unconfigured` (see that class's own doc comment),
/// `AccountScreen` itself is never pushed in that state — so putting export
/// there would make it unreachable for exactly the installs (unconfigured,
/// or configured-but-signed-out) where "your local game data is exportable
/// regardless of account state" matters most. This tile is unconditional:
/// no `accountStateProvider` check at all.
class ExportDataTile extends ConsumerWidget {
  const ExportDataTile({super.key, this.exporter = const DataExporter()});

  /// Injectable for tests — defaults to the real [DataExporter].
  final DataExporter exporter;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.ios_share_outlined),
    title: const Text('Exporter mes données'),
    subtitle: const Text(
      'Journal de jeu, profil et zones explorées, au format JSON',
    ),
    onTap: () => _export(context, ref),
  );

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    try {
      await exporter.exportAndShare(ref);
    } catch (_) {
      // game-never-blocks: an export failure (disk full, no share target,
      // an unreadable journal) is shown softly, never a crash.
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("L'export a échoué. Réessayez plus tard."),
        ),
      );
    }
  }
}
