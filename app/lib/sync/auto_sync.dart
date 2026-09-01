import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_state.dart';
import 'backend.dart';
import 'providers.dart';
import 'sync_engine.dart';

/// Single entry point every M5 sync trigger goes through — launch (see
/// [restoreAccountAndAutoSync]), post-trip (`main.dart`'s
/// `_HomeShellState._onSessionEnded`), and the account screen's manual
/// button (`settings/account_screen.dart`) — so all three share one error
/// mapping and one place [lastSyncResultProvider] gets written.
///
/// Always best-effort: never throws, regardless of why the sync failed.
/// Per `task-4-brief.md`'s decision, sync errors are non-fatal everywhere
/// and only ever surfaced (softly, in French) on the account screen — which
/// reads [lastSyncResultProvider] rather than this function's return value.
///
/// A no-op (never even constructs [SyncEngine]/touches the network) unless
/// [AccountState.phase] is already [AccountPhase.signedIn] — this is what
/// keeps an unconfigured build byte-for-byte behaviourally identical to M4:
/// that phase is unreachable when no backend is configured (see
/// `AccountState`'s transition graph), so the guard below is enough on its
/// own, with no separate `is UnconfiguredBackend` check needed.
Future<SyncReport?> runAutoSync(WidgetRef ref) async {
  final account = ref.read(accountStateProvider);
  if (account.phase != AccountPhase.signedIn) return null;

  try {
    final engine = await ref.read(syncEngineProvider.future);
    final report = await engine.sync();
    ref.read(lastSyncResultProvider.notifier).state = SyncResult.success(
      report,
      DateTime.now(),
    );
    return report;
  } catch (e) {
    ref.read(lastSyncResultProvider.notifier).state = SyncResult.failure(
      _frenchMessage(e),
      DateTime.now(),
    );
    return null;
  }
}

/// French copy for [SyncResult.errorMessage] — the only place in M5 that
/// turns a [SyncBackend] exception into user-facing text.
String _frenchMessage(Object error) {
  if (error is SyncAuthError) {
    return 'Session expirée — reconnectez-vous.';
  }
  if (error is SyncNetworkError) {
    return 'Connexion impossible. Nouvelle tentative plus tard.';
  }
  // SyncUnconfigured can't reach here (runAutoSync's own signedIn guard
  // makes it unreachable); kept as a safety net for anything unexpected.
  return 'Échec de la synchronisation.';
}

/// Restores a signed-in session at app launch, then kicks off a best-effort
/// sync — the "au lancement (si signedIn)" auto-sync trigger.
///
/// Fire-and-forget by design: called from `HomeShell.initState()`, which
/// cannot itself be async and must not block the first frame. A no-op
/// (returns synchronously, before any `await`) unless
/// [AccountState.phase] is already [AccountPhase.signedOut] — i.e. a
/// configured backend with no session restored yet — so both an
/// unconfigured build and an already-otpSent/signedIn one are unaffected.
///
/// **Cold-start `currentUser()` race (Task 3 report, concern #2):** a
/// freshly-initialized `supabase_flutter` client kicks off session recovery
/// from disk as a background operation it doesn't block on, so the very
/// first `currentUser()` call after a cold start can transiently answer
/// `null` even though a real session is about to be restored. The simplest
/// correct fix available through the [SyncBackend] contract alone (no
/// `onAuthStateChange` stream exists on it) is a single bounded retry: on a
/// `null` first answer, wait briefly and ask once more before concluding
/// "not signed in". Not a loop/poll — one retry is enough to clear the
/// specific race Task 3 flagged, and this function fails soft either way
/// (any exception, or still-null after the retry, just leaves
/// [AccountState.phase] at `signedOut`).
Future<void> restoreAccountAndAutoSync(WidgetRef ref) async {
  final account = ref.read(accountStateProvider);
  if (account.phase != AccountPhase.signedOut) return;

  final backend = ref.read(syncBackendProvider);
  AuthUser? user;
  try {
    user = await backend.currentUser();
    user ??= await _retryCurrentUserOnce(backend);
  } catch (_) {
    return; // Best-effort: stay signedOut, nothing to surface here.
  }
  if (user == null) return;

  ref.read(accountStateProvider.notifier).state = ref
      .read(accountStateProvider)
      .signedIn(user.uid, user.email);

  await runAutoSync(ref);
}

Future<AuthUser?> _retryCurrentUserOnce(SyncBackend backend) async {
  await Future<void>.delayed(const Duration(milliseconds: 300));
  try {
    return await backend.currentUser();
  } catch (_) {
    return null;
  }
}
