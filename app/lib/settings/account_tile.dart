import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../sync/account_state.dart';
import '../sync/providers.dart';
import 'account_screen.dart';

/// Settings entry point for the account/sync feature (M5). The only piece
/// of M5 UI visible with no backend configured — a quiet tile whose
/// subtitle says so and whose tap explains it, never a dialog or screen
/// that implies sync is one tap away when it isn't.
class AccountTile extends ConsumerWidget {
  const AccountTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountStateProvider);
    final unconfigured = account.phase == AccountPhase.unconfigured;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.cloud_outlined),
      title: const Text('Compte'),
      subtitle: Text(_subtitleFor(account)),
      onTap: () => unconfigured
          ? showDialog<void>(
              context: context,
              builder: (context) => const _SyncUnconfiguredDialog(),
            )
          : Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const AccountScreen())),
    );
  }

  String _subtitleFor(AccountState account) {
    switch (account.phase) {
      case AccountPhase.unconfigured:
        return 'Synchronisation non configurée';
      case AccountPhase.signedOut:
        return 'Non connecté';
      case AccountPhase.otpSent:
        return 'Code envoyé à ${account.email ?? ''}';
      case AccountPhase.signedIn:
        final email = account.email;
        return email == null ? 'Connecté' : 'Connecté ($email)';
    }
  }
}

class _SyncUnconfiguredDialog extends StatelessWidget {
  const _SyncUnconfiguredDialog();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Compte'),
    content: const Text(
      "La synchronisation multi-appareils n'est pas configurée pour cette "
      'installation de RandomWalk. Vos données (parcours, progression) '
      "restent uniquement sur cet appareil : rien n'est envoyé en ligne.\n\n"
      "Le propriétaire de l'application peut activer un compte optionnel "
      '(connexion par e-mail) pour synchroniser la progression entre '
      'plusieurs appareils et partager le classement en ligne.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Fermer'),
      ),
    ],
  );
}
