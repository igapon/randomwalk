/// Where the account/sync flow currently stands, independent of any
/// backend or UI. See [AccountState] for the transition functions between
/// these.
enum AccountPhase {
  /// No `SyncBackend` is configured (`SupabaseConfig.fromEnvironment() ==
  /// null`). Terminal for the lifetime of a running process — configuration
  /// is compile-time (`--dart-define`), so a process that started
  /// unconfigured can never become configured without a restart.
  unconfigured,

  /// A backend is configured but nobody is signed in on this device.
  signedOut,

  /// An OTP code has been requested for [AccountState.email] and is
  /// awaited.
  otpSent,

  /// Signed in as [AccountState.uid].
  signedIn,
}

/// Pure state for the account/sync flow — no I/O, no backend reference.
///
/// Every transition below returns a *new* [AccountState] rather than
/// mutating; callers (Task 4's account screen, wired through
/// `accountStateProvider`) drive the actual [SyncBackend] calls and only
/// apply the matching transition once the backend call succeeds. A
/// transition called from a phase it doesn't support throws [StateError] —
/// this is a programmer error (the UI/engine calling backend operations out
/// of order), not a recoverable runtime condition, so it is not modelled as
/// a typed result.
///
/// Transition graph:
/// ```
/// unconfigured --configure()--> signedOut
/// signedOut --otpRequested(email)--> otpSent
/// otpSent --otpRequested(newEmail)--> otpSent   (restart with a new email)
/// otpSent --signedIn(uid, email)--> signedIn
/// signedOut --signedIn(uid, email)--> signedIn  (restored session, no OTP)
/// otpSent --reset()--> signedOut                (cancel the pending OTP)
/// signedIn --signOut()--> signedOut
/// ```
class AccountState {
  final AccountPhase phase;

  /// The OTP-pending or signed-in email. `null` in [AccountPhase.unconfigured]
  /// and [AccountPhase.signedOut].
  final String? email;

  /// The backend account id. Only ever set in [AccountPhase.signedIn].
  final String? uid;

  const AccountState._(this.phase, this.email, this.uid);

  /// Initial state for a process with no `SyncBackend` configured.
  const AccountState.unconfigured()
    : this._(AccountPhase.unconfigured, null, null);

  /// Initial state for a process with a configured backend and no
  /// restored session yet.
  const AccountState.signedOut() : this._(AccountPhase.signedOut, null, null);

  /// [AccountPhase.unconfigured] → [AccountPhase.signedOut]. Only valid once
  /// — a process that starts unconfigured has no path back to
  /// [AccountPhase.unconfigured] (see that phase's doc comment), so this
  /// throws [StateError] from every other phase.
  AccountState configure() {
    if (phase != AccountPhase.unconfigured) {
      throw StateError('configure(): requires unconfigured, was $phase');
    }
    return const AccountState.signedOut();
  }

  /// Requests (or restarts) an OTP for [email]. Valid from
  /// [AccountPhase.signedOut] (start the flow) and [AccountPhase.otpSent]
  /// (resend, or restart with a different email) — invalid from
  /// [AccountPhase.unconfigured] (nothing to authenticate against) and
  /// [AccountPhase.signedIn] (call [signOut] first; this deliberately does
  /// not double as an account-switch shortcut).
  AccountState otpRequested(String email) {
    if (phase != AccountPhase.signedOut && phase != AccountPhase.otpSent) {
      throw StateError(
        'otpRequested(): requires signedOut or otpSent, was $phase',
      );
    }
    return AccountState._(AccountPhase.otpSent, email, null);
  }

  /// Records a successful sign-in. Valid from [AccountPhase.otpSent] (the
  /// normal flow: code verified) and [AccountPhase.signedOut] (a session
  /// restored from the backend at startup, e.g. `currentUser()` already
  /// returning a user — no OTP round-trip needed). Invalid from
  /// [AccountPhase.unconfigured] and from [AccountPhase.signedIn] itself
  /// (sign out first to switch accounts, rather than silently overwriting
  /// the current session).
  AccountState signedIn(String uid, String? email) {
    if (phase != AccountPhase.otpSent && phase != AccountPhase.signedOut) {
      throw StateError('signedIn(): requires otpSent or signedOut, was $phase');
    }
    return AccountState._(AccountPhase.signedIn, email ?? this.email, uid);
  }

  /// Ends the current session. Valid only from [AccountPhase.signedIn].
  AccountState signOut() {
    if (phase != AccountPhase.signedIn) {
      throw StateError('signOut(): requires signedIn, was $phase');
    }
    return const AccountState.signedOut();
  }

  /// Cancels a pending OTP request, returning to [AccountPhase.signedOut].
  /// Valid only from [AccountPhase.otpSent] — [AccountPhase.signedIn] has
  /// [signOut] for the equivalent "go back to signedOut" step, kept as a
  /// separate method so a caller can't accidentally sign a user out by
  /// calling the "cancel this dialog" transition.
  AccountState reset() {
    if (phase != AccountPhase.otpSent) {
      throw StateError('reset(): requires otpSent, was $phase');
    }
    return const AccountState.signedOut();
  }
}
