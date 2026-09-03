import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'theme_mode_provider.dart';
import 'theme_mode_store.dart';

/// Task 2l brief item 2 (owner: "ajoute un mode jour") — a sober Réglages
/// tile ("tuile Réglages sobre" per the brief) for the Système/Jour/Nuit
/// theme override. Same `ListTile` + `AlertDialog` shape as
/// `account_tile.dart`'s `AccountTile`, for consistency.
class ThemeModeTile extends ConsumerWidget {
  const ThemeModeTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.brightness_6_outlined),
      title: const Text('Thème'),
      subtitle: Text(_labelFor(mode)),
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => _ThemeModeDialog(current: mode),
      ),
    );
  }

  static String _labelFor(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'Système',
    ThemeMode.light => 'Jour',
    ThemeMode.dark => 'Nuit',
  };
}

class _ThemeModeDialog extends ConsumerWidget {
  const _ThemeModeDialog({required this.current});

  final ThemeMode current;

  Future<void> _choose(
    BuildContext context,
    WidgetRef ref,
    ThemeMode mode,
  ) async {
    // Applied LIVE first — the walker sees the map/app repaint immediately,
    // before the (already-fast, but still async) SharedPreferences write
    // completes — then persisted so it survives a cold start.
    ref.read(themeModeProvider.notifier).state = mode;
    Navigator.of(context).pop();
    await ThemeModeStore().save(mode);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => SimpleDialog(
    title: const Text('Thème'),
    children: [
      // `RadioListTile.groupValue`/`.onChanged` are deprecated since Flutter
      // 3.32 in favor of an ancestor `RadioGroup` — this is that ancestor.
      RadioGroup<ThemeMode>(
        groupValue: current,
        onChanged: (value) {
          if (value != null) unawaited(_choose(context, ref, value));
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in ThemeMode.values)
              RadioListTile<ThemeMode>(
                title: Text(ThemeModeTile._labelFor(mode)),
                value: mode,
              ),
          ],
        ),
      ),
    ],
  );
}
