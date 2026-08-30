import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The explanation shown *before* Android's "Autoriser tout le temps"
/// prompt (brief §4).
///
/// It exists because of a quirk of Android 11+: requesting background
/// location there never opens a dialog — the request comes back denied and
/// the only way to grant it is a trip to the app's settings screen. Sending
/// someone there with no explanation reads like the app is broken, so this
/// says what the permission buys and what happens without it, and makes
/// « Plus tard » an equally legitimate answer.
class BackgroundLocationRationale extends StatelessWidget {
  const BackgroundLocationRationale({super.key});

  static Future<bool> show(BuildContext context) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => const BackgroundLocationRationale(),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: const Icon(Icons.my_location),
      title: const Text('Suivre le trajet écran éteint'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pour continuer à mesurer votre trajet quand l\'écran s\'éteint '
            'ou que vous quittez l\'application, Android demande '
            'l\'autorisation de localisation « Autoriser tout le temps ».',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Sur l\'écran suivant, choisissez « Autoriser tout le temps ». '
            'Votre position ne sert qu\'à calculer la distance de vos '
            'trajets, et rien n\'est enregistré hors trajet.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Sans cette autorisation, le trajet est quand même enregistré, '
            'mais le suivi peut s\'arrêter si l\'écran s\'éteint.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Plus tard'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Ouvrir les réglages'),
        ),
      ],
    );
  }
}
