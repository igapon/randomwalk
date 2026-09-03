import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/game/game_state_provider.dart';
import 'package:randomwalk/sync/account_state.dart';
import 'package:randomwalk/sync/auto_sync.dart';
import 'package:randomwalk/sync/backend.dart';
import 'package:randomwalk/sync/providers.dart';

import '../support/fake_sync_backend.dart';
import '../support/temp_dir.dart';

/// [runAutoSync]/[restoreAccountAndAutoSync] take a [WidgetRef] (matching
/// their real call sites: `HomeShell.initState`, `_onSessionEnded`, the
/// account screen's manual button — all inside widget code), so exercising
/// them needs a live [WidgetRef] from an actual widget tree rather than a
/// bare `ProviderContainer`. This harness does nothing but hand its own
/// `ref` out via [onReady] once mounted; tests then call the functions
/// under test directly, inside [WidgetTester.runAsync] (the real-I/O
/// journal reads/writes these functions trigger need the real event loop,
/// not `testWidgets`' fake-time pumping — see this file's own notes below).
class _Harness extends ConsumerStatefulWidget {
  const _Harness({required this.onReady});
  final void Function(WidgetRef ref) onReady;

  @override
  ConsumerState<_Harness> createState() => _HarnessState();
}

class _HarnessState extends ConsumerState<_Harness> {
  @override
  void initState() {
    super.initState();
    widget.onReady(ref);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  late Directory tempDir;
  late GameJournal journal;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('auto_sync_test');
    journal = GameJournal(Directory('${tempDir.path}/journal'));
  });

  tearDown(() async {
    // gameStateProvider replays via loadStateFast (Task 5), which fires an
    // unawaited background checkpoint write on every read — tolerate that
    // write still being in flight (see deleteTempDirRetrying's dartdoc).
    await deleteTempDirRetrying(tempDir);
  });

  /// Pumps the harness and returns its live [WidgetRef]. Tests then drive
  /// [runAutoSync]/[restoreAccountAndAutoSync] via `tester.runAsync` — these
  /// functions do real `dart:io` journal reads/writes (through
  /// `GameJournal`/`SyncEngine`), and `testWidgets`' default fake-clock
  /// pumping (`pump`/`pumpAndSettle`) does not reliably let genuine
  /// asynchronous I/O complete; `runAsync` runs its callback in the real
  /// zone specifically so real I/O resolves normally.
  Future<WidgetRef> pumpHarness(
    WidgetTester tester, {
    required FakeSyncBackend backend,
    required AccountState account,
  }) async {
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncBackendProvider.overrideWithValue(backend),
          accountStateProvider.overrideWith((ref) => account),
          gameJournalProvider.overrideWith((ref) async => journal),
        ],
        child: MaterialApp(home: _Harness(onReady: (r) => ref = r)),
      ),
    );
    return ref;
  }

  group('runAutoSync', () {
    testWidgets(
      'is a no-op (no backend call, no result recorded) when not signed in',
      (tester) async {
        final backend = FakeSyncBackend();
        final ref = await pumpHarness(
          tester,
          backend: backend,
          account: const AccountState.signedOut(),
        );

        await tester.runAsync(() => runAutoSync(ref));

        expect(ref.read(lastSyncResultProvider), isNull);
        expect(backend.pushCallCount, 0);
        expect(backend.pullCallCount, 0);
      },
    );

    testWidgets(
      'records a success SyncResult (with counts) when signed in and the '
      'engine syncs cleanly',
      (tester) async {
        final backend = FakeSyncBackend()
          ..seedServer([
            GameEvent(
              id: 'r-1',
              ts: DateTime.utc(2026, 9, 1),
              type: GameEventTypes.coinsEarned,
              payload: const {'amount': 5},
            ),
          ]);
        final ref = await pumpHarness(
          tester,
          backend: backend,
          account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
        );

        final report = await tester.runAsync(() => runAutoSync(ref));

        expect(report!.pushedCount, 0);
        expect(report.pulledCount, 1);
        final result = ref.read(lastSyncResultProvider);
        expect(result!.isSuccess, isTrue);
        expect(result.report!.pulledCount, 1);
      },
    );

    testWidgets('maps a SyncNetworkError to French copy', (tester) async {
      final backend = FakeSyncBackend()
        ..pullError = const SyncNetworkError('offline');
      final ref = await pumpHarness(
        tester,
        backend: backend,
        account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
      );

      await tester.runAsync(() => runAutoSync(ref));

      final result = ref.read(lastSyncResultProvider);
      expect(result!.isSuccess, isFalse);
      expect(
        result.errorMessage,
        'Connexion impossible. Nouvelle tentative plus tard.',
      );
    });

    testWidgets('maps a SyncAuthError to French copy', (tester) async {
      final backend = FakeSyncBackend()
        ..pullError = const SyncAuthError('expired');
      final ref = await pumpHarness(
        tester,
        backend: backend,
        account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
      );

      await tester.runAsync(() => runAutoSync(ref));

      final result = ref.read(lastSyncResultProvider);
      expect(result!.isSuccess, isFalse);
      expect(result.errorMessage, 'Session expirée — reconnectez-vous.');
    });
  });

  group('restoreAccountAndAutoSync', () {
    testWidgets(
      'a no-op when unconfigured (phase stays unconfigured, no backend call)',
      (tester) async {
        final backend = FakeSyncBackend();
        final ref = await pumpHarness(
          tester,
          backend: backend,
          account: const AccountState.unconfigured(),
        );

        await tester.runAsync(() => restoreAccountAndAutoSync(ref));

        expect(ref.read(accountStateProvider).phase, AccountPhase.unconfigured);
        expect(backend.currentUserCallCount, 0);
      },
    );

    testWidgets(
      'a no-op when already signedIn or otpSent (nothing to restore)',
      (tester) async {
        final backend = FakeSyncBackend();
        final ref = await pumpHarness(
          tester,
          backend: backend,
          account: const AccountState.signedOut().otpRequested('a@b.ch'),
        );

        await tester.runAsync(() => restoreAccountAndAutoSync(ref));

        expect(backend.currentUserCallCount, 0);
      },
    );

    testWidgets(
      'restores a session immediately available from currentUser() and '
      'transitions to signedIn, then auto-syncs',
      (tester) async {
        final backend = FakeSyncBackend()
          ..currentUserAnswers = const [AuthUser(uid: 'u1', email: 'a@b.ch')];
        final ref = await pumpHarness(
          tester,
          backend: backend,
          account: const AccountState.signedOut(),
        );

        await tester.runAsync(() => restoreAccountAndAutoSync(ref));

        expect(ref.read(accountStateProvider).phase, AccountPhase.signedIn);
        expect(ref.read(accountStateProvider).uid, 'u1');
        expect(ref.read(lastSyncResultProvider)!.isSuccess, isTrue);
      },
    );

    testWidgets(
      'tolerates one transiently-null currentUser() answer by retrying '
      'once before restoring the session (Task 3 cold-start race)',
      (tester) async {
        final backend = FakeSyncBackend()
          ..currentUserAnswers = const [
            null,
            AuthUser(uid: 'u1', email: 'a@b.ch'),
          ];
        final ref = await pumpHarness(
          tester,
          backend: backend,
          account: const AccountState.signedOut(),
        );

        await tester.runAsync(() => restoreAccountAndAutoSync(ref));

        expect(backend.currentUserCallCount, 2);
        expect(ref.read(accountStateProvider).phase, AccountPhase.signedIn);
      },
    );

    testWidgets(
      'stays signedOut when currentUser() answers null twice (genuinely '
      'not signed in), without surfacing an error',
      (tester) async {
        final backend = FakeSyncBackend()..currentUserAnswers = const [null];
        final ref = await pumpHarness(
          tester,
          backend: backend,
          account: const AccountState.signedOut(),
        );

        await tester.runAsync(() => restoreAccountAndAutoSync(ref));

        expect(ref.read(accountStateProvider).phase, AccountPhase.signedOut);
        expect(ref.read(lastSyncResultProvider), isNull);
      },
    );

    testWidgets(
      'fix round 1 (Task 4 review I2): re-checks the phase guard after the '
      'currentUser() await, and does not stomp an OTP flow that advanced '
      'to otpSent while this was in flight',
      (tester) async {
        late WidgetRef ref;
        final backend = _MutatesPhaseDuringCurrentUser(
          () => ref.read(accountStateProvider.notifier).state = ref
              .read(accountStateProvider)
              .otpRequested('someone-else@b.ch'),
        )..currentUserAnswers = const [AuthUser(uid: 'u1', email: 'a@b.ch')];
        ref = await pumpHarness(
          tester,
          backend: backend,
          account: const AccountState.signedOut(),
        );

        await tester.runAsync(() => restoreAccountAndAutoSync(ref));

        // Stayed on the in-progress OTP flow — not silently overwritten by
        // the launch restore that raced it, and no StateError escaped
        // either (applying signedIn() from otpSent for a DIFFERENT uid
        // than the one mid-flow would otherwise have been a data-loss bug,
        // not just a thrown exception).
        final account = ref.read(accountStateProvider);
        expect(account.phase, AccountPhase.otpSent);
        expect(account.email, 'someone-else@b.ch');
      },
    );

    testWidgets(
      'fix round 1 (Task 4 review I2): a ref.read that throws because the '
      'owning widget was disposed does not escape as an unhandled async '
      'error — this function\'s own contract is that it never throws',
      (tester) async {
        final backend = FakeSyncBackend()
          ..currentUserAnswers = const [AuthUser(uid: 'u1', email: 'a@b.ch')];
        final ref = await pumpHarness(
          tester,
          backend: backend,
          account: const AccountState.signedOut(),
        );
        // Unmount the harness — `ref.read` throws from here on.
        await tester.pumpWidget(const SizedBox.shrink());

        // Reaching this line at all (rather than the test framework
        // reporting an unhandled exception from a stray, uncaught Future)
        // is the regression signal fix round 1 addresses.
        await tester.runAsync(
          () => restoreAccountAndAutoSync(
            ref,
          ).timeout(const Duration(seconds: 1)),
        );
      },
    );
  });

  group('fix round 1 (Task 4 review I2): runAutoSync never throws even '
      'when ref is unusable', () {
    testWidgets('a disposed widget\'s ref does not make runAutoSync throw', (
      tester,
    ) async {
      final backend = FakeSyncBackend();
      final ref = await pumpHarness(
        tester,
        backend: backend,
        account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
      );
      await tester.pumpWidget(const SizedBox.shrink());

      final report = await tester.runAsync(
        () => runAutoSync(ref).timeout(const Duration(seconds: 1)),
      );

      expect(report, isNull);
    });
  });
}

/// Calls [onCall] synchronously before answering [currentUser] — lets a
/// test simulate something else (the account screen's own OTP flow, in
/// this file's I2 regression test) mutating `accountStateProvider` WHILE
/// `restoreAccountAndAutoSync` is awaiting this very call.
class _MutatesPhaseDuringCurrentUser extends FakeSyncBackend {
  _MutatesPhaseDuringCurrentUser(this.onCall);
  final void Function() onCall;

  @override
  Future<AuthUser?> currentUser() async {
    onCall();
    return super.currentUser();
  }
}
