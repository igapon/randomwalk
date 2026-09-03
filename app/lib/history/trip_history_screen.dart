import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../adventure/hud_format.dart' show formatWholeNumber;
import '../theme/tokens.dart';
import '../valhalla/models.dart';
import 'history_format.dart';
import 'trip_history_detail_screen.dart';
import 'trip_history_store.dart';

/// `Icons.directions_walk`/`Icons.directions_bike` — the same profile
/// iconography used everywhere else a [RoutingProfile] is shown (session
/// screen, map screen, planner), reused rather than reinvented.
IconData iconForProfile(RoutingProfile profile) =>
    profile == RoutingProfile.walk
    ? Icons.directions_walk
    : Icons.directions_bike;

/// Wired into `settings/settings_screen.dart` (brief §2: "onglet Aventure
/// ou Réglages, choisir le plus naturel"). Réglages was chosen over the
/// Aventure tab: that screen is already a list of things to look at/manage
/// (pseudo, identité, réglages d'alerte, à propos des données, compte) —
/// one more `ListTile` fits it exactly — whereas the Aventure tab is a
/// full-screen `MapLibreMap` (see `AdventureScreen`'s own doc comment) with
/// no natural slot for a new destination and, like every screen built on a
/// real map controller, cannot be widget-tested; adding the entry point
/// here keeps this feature's own tests independent of that screen entirely.
class TripHistorySettingsTile extends StatelessWidget {
  const TripHistorySettingsTile({super.key});

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.history),
    title: const Text('Historique des trajets'),
    subtitle: const Text('Vos trajets enregistrés localement'),
    onTap: () => Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const TripHistoryScreen())),
  );
}

/// « Historique » — every finalised trip, antichronological (brief §2). See
/// [TripHistorySettingsTile]'s doc comment for why this is reached from
/// Réglages.
class TripHistoryScreen extends ConsumerWidget {
  const TripHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entriesAsync = ref.watch(tripHistoryListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Historique des trajets')),
      body: SafeArea(
        child: entriesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          // Best-effort like every other local store in this app: a broken
          // history read shows the same inviting empty state a fresh
          // install would, never an error screen.
          error: (_, __) => const TripHistoryEmptyState(),
          data: (entries) => entries.isEmpty
              ? const TripHistoryEmptyState()
              : TripHistoryList(entries: entries),
        ),
      ),
    );
  }
}

/// Extracted so it — and the list below — can be pumped directly in a
/// widget test without a `MapLibreMapController` anywhere in the tree.
class TripHistoryList extends StatelessWidget {
  const TripHistoryList({super.key, required this.entries});

  final List<TripHistoryEntry> entries;

  @override
  Widget build(BuildContext context) => ListView.separated(
    padding: const EdgeInsets.all(AppSpacing.md),
    itemCount: entries.length,
    separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
    itemBuilder: (context, i) => TripHistoryTile(entry: entries[i]),
  );
}

class TripHistoryTile extends StatelessWidget {
  const TripHistoryTile({super.key, required this.entry});

  final TripHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppRadii.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.card),
        // Navigates by id, not by handing the already-in-memory `entry`
        // along: `entry` came from the summary-only `tripHistoryListProvider`
        // (no track — see `TripHistoryStore.list`'s doc comment), and the
        // detail screen fetches its own full row, track included, by id.
        onTap: entry.id == null
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TripHistoryDetailScreen(id: entry.id!),
                ),
              ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Icon(
                iconForProfile(entry.profile),
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formatHistoryDate(entry.startedAt),
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${formatTripDistance(entry.distanceKm)} · '
                      '${formatTripDuration(entry.duration)}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              if (entry.xpEarned != null) ...[
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '+${formatWholeNumber(entry.xpEarned!)} XP',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
              const SizedBox(width: AppSpacing.xs),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// « Vide = état d'invitation FR » (brief §2) — shown when no trip has ever
/// been finalised yet, or the store could not be read.
class TripHistoryEmptyState extends StatelessWidget {
  const TripHistoryEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.map_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Aucun trajet pour le moment',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Terminez une marche ou une balade à vélo pour la retrouver ici.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
