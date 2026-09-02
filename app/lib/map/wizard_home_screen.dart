/// Task 2i: the trip-start wizard's step 1 — the Carte tab's resting screen
/// whenever no trip is active and no route is being planned (see
/// `carte_tab.dart`). Sober balisage identity, no map anywhere in this file
/// or anything it imports (the perf requirement this task is pinned on: no
/// `MaplibreMap` before step 3).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../history/history_format.dart';
import '../history/trip_history_store.dart';
import '../theme/tokens.dart';
import '../theme/waymark_glyph.dart';
import '../trip/trip_controller.dart';
import '../valhalla/models.dart';
import 'plan_mode.dart';
import 'wizard_actions.dart';
import 'wizard_defaults_store.dart';
import 'wizard_destination_flow.dart';
import 'wizard_promenade_screen.dart';

class WizardHomeScreen extends ConsumerWidget {
  const WizardHomeScreen({super.key, required this.onEnterMap});

  final EnterMapCallback onEnterMap;

  Future<void> _openDestination(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WizardDestinationSearchScreen(onEnterMap: onEnterMap),
      ),
    );
  }

  Future<void> _openPromenade(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WizardPromenadeScreen(onEnterMap: onEnterMap),
      ),
    );
  }

  void _openExplore() => onEnterMap();

  /// « Repartir » — brief point 4, "2 taps total to relaunch": this tap
  /// itself, then « Démarrer » on the result banner [WizardHandoff.
  /// autoAcceptBestCandidate] lands the walker on directly, skipping the
  /// fullscreen candidate row entirely.
  Future<void> _repartir(WidgetRef ref, RoutingProfile profile) async {
    final defaults = await WizardDefaultsStore().load(profile);
    final handoff = await commitPromenadePlan(
      ref.read(tripControllerProvider),
      mode: defaults.mode,
      loopTargetKm: defaults.loopTargetKm,
      durationTarget: defaults.durationTarget,
      profile: profile,
      autoAcceptBestCandidate: true,
    );
    onEnterMap(handoff);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final trip = ref.watch(tripControllerProvider);
    final latestTrip = ref.watch(tripHistoryLatestProvider);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.xl,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _WizardIdentityHeader(),
            const SizedBox(height: AppSpacing.xl),
            latestTrip.when(
              data: (entry) => entry == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: _RepartirCard(
                        entry: entry,
                        onTap: () => _repartir(ref, trip.profile),
                      ),
                    ),
              loading: () => const SizedBox.shrink(),
              error: (error, stackTrace) => const SizedBox.shrink(),
            ),
            _WizardBigCard(
              title: 'Destination',
              subtitle: 'Choisissez une adresse à atteindre',
              icon: const WaymarkDiamond(size: 28, color: AppColors.ink),
              iconBackground: theme.colorScheme.primaryContainer,
              onTap: () => _openDestination(context),
            ),
            const SizedBox(height: AppSpacing.md),
            _WizardBigCard(
              title: 'Promenade',
              subtitle: 'Une boucle depuis votre position',
              icon: Icon(
                Icons.all_inclusive,
                size: 28,
                color: theme.colorScheme.onSecondaryContainer,
              ),
              iconBackground: theme.colorScheme.secondaryContainer,
              onTap: () => _openPromenade(context),
            ),
            const SizedBox(height: AppSpacing.lg),
            Center(
              child: TextButton.icon(
                onPressed: _openExplore,
                icon: const Icon(Icons.map_outlined, size: 18),
                label: const Text('Explorer la carte'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// « nom/identité discrets » — brief point 1: small, muted, never competing
/// with the two cards below for attention.
class _WizardIdentityHeader extends StatelessWidget {
  const _WizardIdentityHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Row(
      children: [
        WaymarkDiamond(size: 18, color: muted, filled: false),
        const SizedBox(width: AppSpacing.sm),
        Text(
          'RANDOMWALK',
          style: theme.textTheme.labelLarge?.copyWith(color: muted),
        ),
      ],
    );
  }
}

/// One of the two step-1 "cartes-boutons" — large, tappable, an icon in a
/// tinted chip plus a title/subtitle pair. Generous padding (balisage
/// identity: whitespace over density).
class _WizardBigCard extends StatelessWidget {
  const _WizardBigCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconBackground,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final Widget icon;
  final Color iconBackground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: iconBackground,
                  shape: BoxShape.circle,
                ),
                child: icon,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// « Repartir » quick-start (brief point 4) — shown only once
/// [TripHistoryStore] has at least one entry (see [WizardHomeScreen.build]).
/// Reuses that entry's own summary (distance/profile) rather than whatever
/// the memorized wizard defaults happen to be — the walker is shown the
/// trip this is reminiscent of, not the raw numbers `Promenade` will
/// actually be re-planned with (those may differ slightly, since planning is
/// never pixel-exact to a target).
class _RepartirCard extends StatelessWidget {
  const _RepartirCard({required this.entry, required this.onTap});

  final TripHistoryEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profileLabel = entry.profile == RoutingProfile.walk
        ? 'Marche'
        : 'Vélo';
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.primaryContainer,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(Icons.replay, color: theme.colorScheme.onPrimaryContainer),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Repartir',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                    Text(
                      '${formatTripDistance(entry.distanceKm)} · $profileLabel',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
