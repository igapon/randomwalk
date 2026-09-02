import 'package:flutter/material.dart';
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
/// Like `AdventureScreen`/`MapScreen`, this owns a real
/// `MapLibreMapController` (a platform view) and cannot be widget-tested at
/// all — see those screens' own doc comments for the same limitation. Only
/// [TripHistoryStats] (the pure stats card) is pumped directly in
/// `trip_history_screen_test.dart`.
class TripHistoryDetailScreen extends StatefulWidget {
  const TripHistoryDetailScreen({super.key, required this.entry});

  final TripHistoryEntry entry;

  @override
  State<TripHistoryDetailScreen> createState() =>
      _TripHistoryDetailScreenState();
}

class _TripHistoryDetailScreenState extends State<TripHistoryDetailScreen> {
  MapLibreMapController? _controller;

  Future<void> _onStyleLoaded() async {
    final track = widget.entry.track;
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
    final entry = widget.entry;
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
              onMapCreated: (c) => _controller = c,
              onStyleLoadedCallback: _onStyleLoaded,
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
