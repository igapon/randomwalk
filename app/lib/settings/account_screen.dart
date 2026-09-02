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
import 'local_purge.dart';

/// The account/sync screen (M5 Task 4): email → 6-digit OTP → signed in.
///
/// Reached from `AccountTile` only once a backend is configured (the
/// unconfigured case shows an explanatory dialog instead and never
/// navigates here — see that class) — the `AccountPhase.unconfigured`
/// branch below is a defensive fallback, not a state this screen is
/// expected to actually render in production.
///
/// Export (Task 6) deliberately lives on `SettingsScreen`, not here — see
/// `data_export.dart`'s `ExportDataTile` doc comment for why (this screen
/// is unreachable when `AccountPhase.unconfigured`, but local game data is
/// exportable regardless of account state).
///
/// Account deletion (Task 6) IS implemented here (`_deleteAccount`), per the
/// binding decision recorded by Task 4/5's reviews: after
/// `SyncBackend.deleteAccount()`'s RPC succeeds, the flow calls `signOut()`
/// locally and resets `accountStateProvider` (`_clearLocalSession`, shared
/// with the plain "Se déconnecter" button), then separately OFFERS — never
/// implies — an optional local purge, run via `local_purge.dart`'s
/// `runLocalPurge` (which refuses to run at all while a trip is recording —
/// see its own dartdoc — and shares its `PurgeRetryState` bookkeeping with
/// `Réglages`'s `PurgeRetryTile`, review round 1's answer to a partial
/// failure otherwise having no way back in). See `LocalDataPurge`'s own
/// dartdoc for the full, binding purge inventory. Fix round 1
/// (Task 4 review C2): `SyncStateStore`'s checkpoint is scoped by uid
/// (`PrefsSyncStateStore`), so a re-signup after delete (a fresh uid)
/// automatically starts from a clean sync checkpoint even when the player
/// declines the local purge.
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
      await _clearLocalSession();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The local half of both "Se déconnecter" and "Supprimer mon compte" —
  /// asks the backend to end the session (best-effort: still clears local
  /// state below even if that call itself fails, since an offline/already-
  /// invalidated-by-`deleteAccount` sign-out must still work locally), then
  /// resets [accountStateProvider] to `signedOut`. Requires
  /// `AccountPhase.signedIn` (the only phase [AccountState.signOut] accepts
  /// — see that method's dartdoc), which both call sites already are.
  Future<void> _clearLocalSession() async {
    try {
      await ref.read(syncBackendProvider).signOut();
    } catch (_) {
      // See doc comment above.
    } finally {
      if (mounted) _setAccountState(_account.signOut());
    }
  }

  /// "Supprimer mon compte" — Task 6's binding flow:
  /// 1. Two sequential French confirmation dialogs, each cancellable
  ///    (`_confirmDeleteStep1`/`_confirmDeleteStep2`) — "confirmation
  ///    double" per `task-6-brief.md`.
  /// 2. `SyncBackend.deleteAccount()` — the server-side cascade (Task 2's
  ///    `delete_account` RPC). A failure here stops the flow entirely and
  ///    surfaces a French error; nothing local is touched (game-never-
  ///    blocks: a failed deletion must leave the player's session and data
  ///    exactly as they were, not half-torn-down).
  /// 3. On success: `_clearLocalSession()` — the pre-made Task 4/5 binding
  ///    decision (see this class's own dartdoc).
  /// 4. A THIRD, separate dialog (`_confirmLocalPurge`) offers — never
  ///    implies — deleting this device's own local game data too
  ///    (`LocalDataPurge`). Declining leaves every local file untouched:
  ///    account deletion and local purge are deliberately independent
  ///    decisions (local-first data belongs to the device owner).
  Future<void> _deleteAccount() async {
    if (!(await _confirmDeleteStep1() ?? false)) return;
    if (!mounted) return;
    if (!(await _confirmDeleteStep2() ?? false)) return;
    if (!mounted) return;

    final deletedUid = _account.uid;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(syncBackendProvider).deleteAccount();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _deleteErrorMessage(e);
        });
      }
      return;
    }

    await _clearLocalSession();
    if (mounted) setState(() => _busy = false);
    if (!mounted) return;

    final purgeAlso = await _confirmLocalPurge();
    if (purgeAlso == true) {
      // runLocalPurge (local_purge.dart) owns the app-support-directory
      // derivation, the refuse-while-a-trip-is-recording guard (Task 6
      // review round 1, I1), and PurgeRetryState bookkeeping — shared with
      // PurgeRetryTile's own retry so both call sites agree on all three.
      final outcome = await runLocalPurge(ref, uid: deletedUid);
      if (mounted) {
        if (outcome.refusedTripActive) {
          _showSnack('Termine ton trajet avant de supprimer les données.');
        } else if (outcome.isFullSuccess) {
          _showSnack('Compte et données locales supprimés.');
        } else {
          _showSnack(
            "Compte supprimé. Certaines données locales n'ont pas pu être "
            'supprimées : ${frenchPurgeLabels(outcome.failures)}. '
            'Réessayez depuis Réglages.',
          );
        }
      }
    } else if (mounted) {
      _showSnack(
        'Compte supprimé. Vos données de jeu restent sur cet appareil.',
      );
    }
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<bool?> _confirmDeleteStep1() => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Supprimer le compte ?'),
      content: const Text(
        'La suppression de votre compte est effectuée côté serveur : votre '
        'profil, votre position au classement et votre historique '
        "synchronisé seront effacés et ne pourront pas être récupérés. Vos "
        'données de jeu restent sur cet appareil ; vous pourrez choisir de '
        'les supprimer aussi à une étape suivante.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Annuler'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Continuer'),
        ),
      ],
    ),
  );

  Future<bool?> _confirmDeleteStep2() => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Confirmation finale'),
      content: const Text(
        'Dernière confirmation : la suppression du compte est immédiate et '
        'irréversible. Voulez-vous vraiment continuer ?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Annuler'),
        ),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Supprimer définitivement'),
        ),
      ],
    ),
  );

  Future<bool?> _confirmLocalPurge() => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Supprimer aussi les données locales ?'),
      content: const Text(
        'Votre compte vient d\'être supprimé côté serveur. Vos données de '
        'jeu (parcours, XP, badges, zones explorées) restent sur cet '
        "appareil, car RandomWalk fonctionne aussi hors connexion. Vous "
        'pouvez choisir de les supprimer maintenant : cette suppression '
        'locale est, elle aussi, irréversible.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Conserver mes données'),
        ),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Supprimer aussi mes données'),
        ),
      ],
    ),
  );

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
              error: _error,
              onSync: _manualSync,
              onSignOut: _signOut,
              onDelete: _deleteAccount,
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

/// French copy for a [SyncBackend.deleteAccount] failure — deliberately
/// distinct wording from [_authErrorMessage]: this is never "your code was
/// wrong", it's "the deletion itself didn't go through", so the player
/// knows their account (and local session) are untouched and it's safe to
/// retry.
String _deleteErrorMessage(Object error) {
  if (error is SyncNetworkError) {
    return 'Connexion impossible : le compte n\'a pas été supprimé. '
        'Réessayez plus tard.';
  }
  return "La suppression du compte a échoué. Réessayez plus tard.";
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
    required this.error,
    required this.onSync,
    required this.onSignOut,
    required this.onDelete,
  });

  final String? email;
  final bool busy;
  final String? error;
  final VoidCallback onSync;
  final VoidCallback onSignOut;
  final VoidCallback onDelete;

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
        const Divider(height: 32),
        if (error != null) _ErrorText(error!),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: busy ? null : onDelete,
            icon: busy
                ? const _ButtonSpinner()
                : const Icon(Icons.delete_forever_outlined),
            label: const Text('Supprimer mon compte'),
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
