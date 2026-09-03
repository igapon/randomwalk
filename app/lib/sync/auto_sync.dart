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
///
/// **Fix round 1 (Task 4 review I2): the ENTIRE body is inside the
/// `try`**, including the first `ref.read(accountStateProvider)` — every
/// call site invokes this via `unawaited(...)` (`main.dart`, the account
/// screen), so an exception escaping uncaught here becomes an unhandled
/// async error rather than something any caller can catch. The most likely
/// cause is the widget that owns [ref] having been disposed mid-`await`
/// (a trip finishing right as the user backs out of the app, a fast
/// sign-out during a manual sync) — `ref.read` throws once its
/// `ProviderContainer` is gone, and this function's whole contract is
/// "never throws", so that must be swallowed same as any other failure.
Future<SyncReport?> runAutoSync(WidgetRef ref) async {
  try {
    final account = ref.read(accountStateProvider);
    if (account.phase != AccountPhase.signedIn) return null;

    final engine = await ref.read(syncEngineProvider.future);
    final report = await engine.sync();
    ref.read(lastSyncResultProvider.notifier).state = SyncResult.success(
      report,
      DateTime.now(),
    );
    return report;
  } catch (e) {
    // A second, INNER try: if `ref` itself is unusable (the dispose case
    // above), even this failure-recording read would throw — nothing left
    // to record it in, so that specific case is silently dropped rather
    // than escaping as a second unhandled error.
    try {
      ref.read(lastSyncResultProvider.notifier).state = SyncResult.failure(
        _frenchMessage(e),
        DateTime.now(),
      );
    } catch (_) {
      // Widget/ref gone — nothing left to surface this to.
    }
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
///
/// **Fix round 1 (Task 4 review I2), two changes:**
/// - The ENTIRE body is now inside one `try`/`catch` — same reasoning as
///   [runAutoSync]'s own dartdoc: this is invoked via `unawaited(...)` from
///   `HomeShell.initState()`, so a `ref.read` throwing because the widget
///   disposed mid-`await` (the ~300ms retry window is exactly long enough
///   for that) must not escape as an unhandled async error.
/// - The [AccountPhase.signedOut] guard is re-checked with a FRESH
///   `ref.read(accountStateProvider)` immediately before applying
///   `.signedIn(...)`, not reused from the check at the top of this
///   function. Between that first check and this point there are two
///   `await`s (`currentUser()` and the retry) during which something else
///   could have moved the phase along — most plausibly the user racing
///   through the OTP flow on the account screen while this launch restore
///   is still in flight. Applying `.signedIn(...)` from `signedIn` itself
///   throws `StateError` (caught by the outer `try` either way, so not a
///   crash) but from `otpSent` it would silently stomp a sign-in the user
///   is actively in the middle of — re-checking avoids both.
Future<void> restoreAccountAndAutoSync(WidgetRef ref) async {
  try {
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

    final current = ref.read(accountStateProvider);
    if (current.phase != AccountPhase.signedOut) return;

    ref.read(accountStateProvider.notifier).state = current.signedIn(
      user.uid,
      user.email,
    );

    await runAutoSync(ref);
  } catch (_) {
    // Best-effort, never throws — matches this function's own contract
    // (see the class doc comment above). Covers a disposed `ref` mainly;
    // `runAutoSync` above already guarantees it never throws on its own.
  }
}

Future<AuthUser?> _retryCurrentUserOnce(SyncBackend backend) async {
  await Future<void>.delayed(const Duration(milliseconds: 300));
  try {
    return await backend.currentUser();
  } catch (_) {
    return null;
  }
}
