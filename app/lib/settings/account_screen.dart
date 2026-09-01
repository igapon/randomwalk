import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../leaderboard/repository.dart';
import '../session/recorder.dart';
import '../sync/account_state.dart';
import '../sync/auto_sync.dart';
import '../sync/backend.dart';
import '../sync/providers.dart';
import 'identity.dart';

/// The account/sync screen (M5 Task 4): email → 6-digit OTP → signed in.
///
/// Reached from `AccountTile` only once a backend is configured (the
/// unconfigured case shows an explanatory dialog instead and never
/// navigates here — see that class) — the `AccountPhase.unconfigured`
/// branch below is a defensive fallback, not a state this screen is
/// expected to actually render in production.
///
/// Export/delete (Task 6) are deliberately NOT implemented here — the
/// signedIn section below has no controls for them at all, per
/// `task-4-brief.md`'s explicit "do NOT implement export/delete". The
/// binding decision for when Task 6 builds them: after
/// `SyncBackend.deleteAccount()`'s RPC succeeds, the flow must also call
/// `signOut()` locally and reset `accountStateProvider` — see
/// `task-4-report.md` for the full writeup.
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  AccountState get _account => ref.read(accountStateProvider);

  void _setAccountState(AccountState next) {
    ref.read(accountStateProvider.notifier).state = next;
  }

  Future<void> _sendOtp() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Veuillez saisir une adresse e-mail.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(syncBackendProvider).signInWithOtp(email);
      _setAccountState(_account.otpRequested(email));
    } catch (e) {
      setState(() => _error = _authErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyOtp() async {
    final email = _account.email;
    final code = _codeController.text.trim();
    if (email == null) return;
    if (code.length != 6) {
      setState(() => _error = 'Le code doit comporter 6 chiffres.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = await ref
          .read(syncBackendProvider)
          .verifyOtp(email: email, code: code);
      if (user == null) {
        setState(() => _error = 'Code invalide.');
        return;
      }
      _setAccountState(_account.signedIn(user.uid, user.email ?? email));
      _codeController.clear();
      // Best-effort, not on the critical path of the sign-in transition
      // itself: push the local pseudo (and current cumulative km) to the
      // now-signed-in profile, then kick off the first sync.
      unawaited(_pushInitialProfile());
      unawaited(runAutoSync(ref));
    } catch (e) {
      setState(() => _error = _authErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pushInitialProfile() async {
    try {
      final identity = await ref.read(identityStoreProvider).get();
      final totalKm = await TotalDistanceStore().totalKm();
      // Routes through SupabaseLeaderboardRepository now that
      // accountStateProvider is signedIn — see leaderboard/repository.dart.
      await ref.read(leaderboardRepositoryProvider).submit(identity, totalKm);
    } catch (_) {
      // Best-effort: the next trip's own submit (main.dart's
      // _onSessionEnded) retries this regardless.
    }
  }

  void _resendOrCancel({required bool cancel}) {
    if (cancel) {
      _setAccountState(_account.reset());
      _codeController.clear();
      setState(() => _error = null);
      return;
    }
    _emailController.text = _account.email ?? '';
    _sendOtp();
  }

  Future<void> _signOut() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(syncBackendProvider).signOut();
    } catch (_) {
      // Best-effort: still clear local state below even if the backend
      // call itself failed (offline sign-out must still work locally).
    } finally {
      if (mounted) {
        _setAccountState(_account.signOut());
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _manualSync() async {
    setState(() => _busy = true);
    try {
      await runAutoSync(ref);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountStateProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Compte')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: switch (account.phase) {
            AccountPhase.unconfigured => const _UnconfiguredBody(),
            AccountPhase.signedOut => _SignedOutBody(
              emailController: _emailController,
              busy: _busy,
              error: _error,
              onSubmit: _sendOtp,
            ),
            AccountPhase.otpSent => _OtpSentBody(
              email: account.email ?? '',
              codeController: _codeController,
              busy: _busy,
              error: _error,
              onVerify: _verifyOtp,
              onResend: () => _resendOrCancel(cancel: false),
              onCancel: () => _resendOrCancel(cancel: true),
            ),
            AccountPhase.signedIn => _SignedInBody(
              email: account.email,
              busy: _busy,
              onSync: _manualSync,
              onSignOut: _signOut,
            ),
          },
        ),
      ),
    );
  }
}

/// French copy for an auth-flow failure — [SyncAuthError] (backend
/// rejected the OTP/email) vs. [SyncNetworkError] (couldn't even ask).
String _authErrorMessage(Object error) {
  if (error is SyncAuthError) return 'Code invalide ou expiré.';
  if (error is SyncNetworkError) {
    return 'Connexion impossible. Réessayez plus tard.';
  }
  return "Une erreur inattendue s'est produite.";
}

class _UnconfiguredBody extends StatelessWidget {
  const _UnconfiguredBody();

  @override
  Widget build(BuildContext context) => const Text(
    "La synchronisation n'est pas configurée pour cette installation.",
  );
}

class _SignedOutBody extends StatelessWidget {
  const _SignedOutBody({
    required this.emailController,
    required this.busy,
    required this.error,
    required this.onSubmit,
  });

  final TextEditingController emailController;
  final bool busy;
  final String? error;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Connectez-vous par e-mail pour synchroniser votre progression '
        'entre plusieurs appareils et apparaître sur le classement en '
        'ligne.',
      ),
      const SizedBox(height: 16),
      TextField(
        controller: emailController,
        keyboardType: TextInputType.emailAddress,
        autocorrect: false,
        enabled: !busy,
        decoration: const InputDecoration(labelText: 'Adresse e-mail'),
        onSubmitted: (_) => onSubmit(),
      ),
      const SizedBox(height: 8),
      if (error != null) _ErrorText(error!),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton(
          onPressed: busy ? null : onSubmit,
          child: busy ? const _ButtonSpinner() : const Text('Recevoir un code'),
        ),
      ),
    ],
  );
}

class _OtpSentBody extends StatelessWidget {
  const _OtpSentBody({
    required this.email,
    required this.codeController,
    required this.busy,
    required this.error,
    required this.onVerify,
    required this.onResend,
    required this.onCancel,
  });

  final String email;
  final TextEditingController codeController;
  final bool busy;
  final String? error;
  final VoidCallback onVerify;
  final VoidCallback onResend;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Un code à 6 chiffres a été envoyé à $email.'),
      const SizedBox(height: 16),
      TextField(
        controller: codeController,
        keyboardType: TextInputType.number,
        maxLength: 6,
        enabled: !busy,
        decoration: const InputDecoration(labelText: 'Code reçu par e-mail'),
        onSubmitted: (_) => onVerify(),
      ),
      if (error != null) _ErrorText(error!),
      Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        children: [
          TextButton(
            onPressed: busy ? null : onCancel,
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: busy ? null : onResend,
            child: const Text('Renvoyer le code'),
          ),
          FilledButton(
            onPressed: busy ? null : onVerify,
            child: busy ? const _ButtonSpinner() : const Text('Valider'),
          ),
        ],
      ),
    ],
  );
}

class _SignedInBody extends ConsumerWidget {
  const _SignedInBody({
    required this.email,
    required this.busy,
    required this.onSync,
    required this.onSignOut,
  });

  final String? email;
  final bool busy;
  final VoidCallback onSync;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(lastSyncResultProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.check_circle_outline),
          title: const Text('Connecté'),
          subtitle: Text(email ?? ''),
        ),
        const Divider(height: 32),
        Text(
          _syncResultText(result),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: busy ? null : onSync,
            icon: busy ? const _ButtonSpinner() : const Icon(Icons.sync),
            label: const Text('Synchroniser maintenant'),
          ),
        ),
        const Divider(height: 32),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: busy ? null : onSignOut,
            child: const Text('Se déconnecter'),
          ),
        ),
      ],
    );
  }

  String _syncResultText(SyncResult? result) {
    if (result == null) {
      return 'Aucune synchronisation effectuée pour le moment.';
    }
    if (result.isSuccess) {
      final report = result.report!;
      return 'Dernière synchronisation : ${report.pushedCount} envoyé(s), '
          '${report.pulledCount} reçu(s).';
    }
    return 'Dernière synchronisation échouée : ${result.errorMessage}';
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 4),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 16,
    height: 16,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
