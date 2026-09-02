import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../adventure/hud_format.dart' show formatWholeNumber;
import '../map/map_screen.dart' show kMapStyleUrlLight, kMapStyleUrlDark;
import '../theme/tokens.dart';
import 'history_format.dart';
import 'trip_history_screen.dart' show iconForProfile;
import 'trip_history_store.dart';

/// One trip's detail: its track drawn on a map, plus the [TripHistoryStats]
/// card over it (brief §2: "détail avec la trace affichée sur une carte +
/// stats").
///
/// Takes an [id], not a [TripHistoryEntry] — review fix round 1 (Critical
/// 2): the list screen's `TripHistoryTile` only ever holds a summary entry
/// (no track — see `TripHistoryStore.list`'s doc comment), so this screen
/// fetches its own full row, track included, via [tripHistoryDetailProvider]
/// once it's actually opened, rather than the list screen loading every
/// trip's track just so whichever one gets tapped already has it in memory.
///
/// Like `AdventureScreen`/`MapScreen`, this owns a real
/// `MapLibreMapController` (a platform view) and cannot be widget-tested at
/// all — see those screens' own doc comments for the same limitation. Only
/// [TripHistoryStats] (the pure stats card) is pumped directly in
/// `trip_history_screen_test.dart`.
class TripHistoryDetailScreen extends ConsumerStatefulWidget {
  const TripHistoryDetailScreen({super.key, required this.id});

  final int id;

  @override
  ConsumerState<TripHistoryDetailScreen> createState() =>
      _TripHistoryDetailScreenState();
}

class _TripHistoryDetailScreenState
    extends ConsumerState<TripHistoryDetailScreen> {
  MapLibreMapController? _controller;

  /// Cached from the last `data` build so [_onStyleLoaded] — a MapLibre
  /// callback with no async/provider access of its own — can read the
  /// already-resolved entry. Safe: the `MapLibreMap` widget below (whose
  /// style-loaded callback this is) is only ever built once [ref.watch]
  /// has resolved to `data`, so this is never null by the time MapLibre can
  /// actually call it.
  TripHistoryEntry? _entry;

  Future<void> _onStyleLoaded() async {
    final track = _entry?.track ?? const [];
    if (track.length < 2) return;
    final geometry = [for (final (lat, lon) in track) LatLng(lat, lon)];
    try {
      // Wide ink casing under a narrower yellow line, exactly like the
      // planned-route line (`map_screen.dart`) and for the same reason:
      // one balisage identity for every line this app draws on a map.
      await _controller?.addLine(
        LineOptions(
          geometry: geometry,
          lineColor: AppColors.routeLineCasingHex,
          lineWidth: 6,
        ),
      );
      await _controller?.addLine(
        LineOptions(
          geometry: geometry,
          lineColor: AppColors.routeLineHex,
          lineWidth: 3,
        ),
      );
      await _controller?.animateCamera(_boundsFor(geometry));
    } catch (_) {
      // A failed line/camera call just leaves the base map showing with no
      // trace drawn — never worth crashing the detail screen over.
    }
  }

  CameraUpdate _boundsFor(List<LatLng> points) {
    var minLat = points.first.latitude;
    var maxLat = points.first.latitude;
    var minLon = points.first.longitude;
    var maxLon = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    return CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(minLat, minLon),
        northeast: LatLng(maxLat, maxLon),
      ),
      left: 48,
      top: 48,
      right: 48,
      bottom: 160,
    );
  }

  @override
  Widget build(BuildContext context) {
    final entryAsync = ref.watch(tripHistoryDetailProvider(widget.id));
    return entryAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      // Best-effort like every other local-store read in this feature: a
      // provider-level failure reads as "not found", never an error screen.
      error: (_, __) => const _TripNotFoundScaffold(),
      data: (entry) {
        if (entry == null) return const _TripNotFoundScaffold();
        _entry = entry;
        return _DetailScaffold(
          entry: entry,
          onMapCreated: (c) => _controller = c,
          onStyleLoaded: _onStyleLoaded,
        );
      },
    );
  }
}

class _DetailScaffold extends StatelessWidget {
  const _DetailScaffold({
    required this.entry,
    required this.onMapCreated,
    required this.onStyleLoaded,
  });

  final TripHistoryEntry entry;
  final void Function(MapLibreMapController) onMapCreated;
  final Future<void> Function() onStyleLoaded;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final styleUrl = brightness == Brightness.dark
        ? kMapStyleUrlDark
        : kMapStyleUrlLight;
    final hasTrack = entry.track.length >= 2;
    final center = hasTrack
        ? entry.track[entry.track.length ~/ 2]
        : (46.2044, 6.1432); // Geneva fallback — same default as the map tab.

    return Scaffold(
      appBar: AppBar(title: Text(formatHistoryDate(entry.startedAt))),
      body: Stack(
        children: [
          if (hasTrack)
            MapLibreMap(
              key: ValueKey(styleUrl),
              styleString: styleUrl,
              initialCameraPosition: CameraPosition(
                target: LatLng(center.$1, center.$2),
                zoom: 13,
              ),
              attributionButtonPosition: AttributionButtonPosition.bottomLeft,
              onMapCreated: onMapCreated,
              onStyleLoadedCallback: onStyleLoaded,
            )
          else
            const _NoTrackPlaceholder(),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: TripHistoryStats(entry: entry),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when [tripHistoryDetailProvider] resolves to `null` (the row was
/// deleted or is corrupt) or fails outright — this trip simply isn't
/// openable any more, distinctly from "still loading".
class _TripNotFoundScaffold extends StatelessWidget {
  const _TripNotFoundScaffold();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Trajet')),
    body: const Center(child: Text('Ce trajet est introuvable.')),
  );
}

class _NoTrackPlaceholder extends StatelessWidget {
  const _NoTrackPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.route_outlined,
                size: 40,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Trace indisponible pour ce trajet',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pure stats card: date, profile, distance, duration, average speed, and
/// XP (when known) — extracted specifically so it is testable without the
/// map above it (see [TripHistoryDetailScreen]'s own doc comment).
class TripHistoryStats extends StatelessWidget {
  const TripHistoryStats({super.key, required this.entry});

  final TripHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(AppRadii.card),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(iconForProfile(entry.profile), size: 18),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  formatHistoryDate(entry.startedAt),
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _Stat(
                  label: 'Distance',
                  value: formatTripDistance(entry.distanceKm),
                ),
                _Stat(
                  label: 'Durée',
                  value: formatTripDuration(entry.duration),
                ),
                _Stat(
                  label: 'Vitesse moy.',
                  value: formatTripSpeed(entry.avgSpeedKmh),
                ),
                if (entry.xpEarned != null)
                  _Stat(
                    label: 'XP',
                    value: '+${formatWholeNumber(entry.xpEarned!)}',
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        Text(value, style: theme.textTheme.labelLarge),
      ],
    );
  }
}
