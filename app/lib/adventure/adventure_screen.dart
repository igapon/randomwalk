import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../game/game_state_provider.dart';
import '../game/grid.dart' show cellIdFor, quartierCompletion;
import '../game/poi_loader.dart';
import '../game/pois.dart' show PoiStore;
import '../game/reducers.dart';
import '../map/game_layer.dart';
import '../map/initial_camera.dart' show resolveInitialCameraCenter;
import '../map/map_screen.dart' show kMapStyleUrlLight, kMapStyleUrlDark;
import '../theme/tokens.dart';
import 'badge_labels.dart';
import 'hud_format.dart';

/// True when nothing in [state] shows any sign of play yet — no ground
/// covered, no cells revealed, no landmark ever visited.
///
/// This is what drives the discreet "Explorez en marchant !" empty state,
/// and it deliberately cannot distinguish "no game data exists at all" (no
/// POIs downloaded, no journal ever written — `gameStateProvider` resolves
/// to the zero `GameState` in both failure cases, per its own "game never
/// blocks" doc comment) from "a brand-new player who simply hasn't walked
/// yet": both render the exact same screen, which is the correct behaviour
/// either way.
bool isAdventureEmpty(GameState state) =>
    state.totalKm == 0 &&
    state.cellsRevealed == 0 &&
    state.landmarksVisited == 0;

/// The 4th tab: a dedicated fog-of-war map (revealed corridor/landmark
/// discs, unrevealed ground drawn as a soft, theme-tinted "papier non
/// exploré" veil), the landmark diamonds around the current viewport, and a
/// compact HUD that opens the badges/stats sheet — the fog+landmark wiring
/// itself lives in `map/game_layer.dart` (Task 2j), shared verbatim with
/// `MapScreen`'s own "couche Aventure" toggle.
///
/// Owns its own [MapLibreMapController] — like `MapScreen`, this cannot be
/// widget-tested directly (native platform view); see `adventure_screen_
/// test.dart` for the extracted [AdventureHud]/[AdventureEmptyBanner]/
/// [BadgesSheet] widgets and `adventure_screen_logic_test.dart` for
/// [isAdventureEmpty], which *are* unit/widget-testable in isolation.
class AdventureScreen extends ConsumerStatefulWidget {
  const AdventureScreen({super.key});

  @override
  ConsumerState<AdventureScreen> createState() => _AdventureScreenState();
}

class _AdventureScreenState extends ConsumerState<AdventureScreen> {
  MapLibreMapController? _controller;

  /// Task 2j: the fog+landmark wiring shared verbatim with `MapScreen`'s own
  /// "couche Aventure" toggle — see `map/game_layer.dart`. This tab always
  /// shows it (no toggle here: Aventure IS the game screen), so [GameLayer.
  /// visible] is simply left at its default `true` for the life of this
  /// State.
  final _gameLayer = GameLayer();

  /// Injectable purely so a future test could pin the clock; production
  /// never overrides it.
  DateTime Function() clock = DateTime.now;

  /// Resolved once at startup — see [_resolveInitialCamera] — before the map
  /// is built at all: last-known position when there is one, else Geneva.
  /// Null while that resolution is still in flight.
  ///
  /// Task 2e item 1 (owner device-QA: "le mode aventure ne dévoile pas la
  /// carte de la ou j'ai été et ne montre pas ma position"): before this
  /// fix, [MapLibreMap] below hard-coded `kDefaultCameraCenter` (Geneva) as
  /// its `initialCameraPosition` regardless of where the walker actually
  /// was — a real walk anywhere else opened this tab looking at ground the
  /// walker had never explored (all-ink fog, correctly nothing revealed
  /// there) with no blue dot to say where they actually were, which reads
  /// exactly as "fog doesn't reveal, position missing". [MapScreen] already
  /// resolves this correctly (`_resolveInitialCamera`); this reuses the
  /// exact same [resolveInitialCameraCenter] helper — the "même source" the
  /// brief asks for — rather than inventing a second way to do it.
  LatLng? _initialCameraCenter;

  /// Mirrors `MapLibreMap.myLocationEnabled` — see [MapScreenState]'s field
  /// of the same name for the full rationale (never unconditionally true,
  /// only flipped once permission is actually known to be granted). Also
  /// part of the Task 2e item 1 fix: this tab previously never enabled the
  /// location layer at all, so the walker's position never appeared on the
  /// Aventure map — "réutiliser la même source" as the main map's blue dot.
  bool _myLocationEnabled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_resolveInitialCamera());
    unawaited(_checkExistingLocationPermission());
  }

  /// Last-known position (no permission prompt) when there is one, else
  /// Geneva — see [resolveInitialCameraCenter]. Awaited before the map is
  /// ever built (see [build]): `initialCameraPosition` is only read once, at
  /// native platform-view creation, so there is no way to correct it after
  /// the fact short of moving the camera again.
  Future<void> _resolveInitialCamera() async {
    final center = await resolveInitialCameraCenter(() async {
      final pos = await Geolocator.getLastKnownPosition();
      return pos == null ? null : (pos.latitude, pos.longitude);
    });
    if (!mounted) return;
    setState(() => _initialCameraCenter = center);
  }

  /// A passive, no-prompt read of whatever permission state already exists
  /// (e.g. granted from the main map, or a previous session) so the location
  /// dot can appear the moment this tab opens, without this tab ever running
  /// its own permission-request flow — that flow belongs to starting a trip
  /// (`TripController`/`TripPermissionCoordinator`), not to browsing fog.
  Future<void> _checkExistingLocationPermission() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse) {
        _enableMyLocation();
      }
    } catch (_) {
      // Nothing to enable yet; permission granted later (from the main map's
      // own flow) simply never reaches this tab until it is reopened, same
      // as any other cold read — not worth chasing with a live listener.
    }
  }

  /// Flips `MapLibreMap.myLocationEnabled` on. A no-op past the first call —
  /// same rationale as `MapScreenState._enableMyLocation`: the native
  /// location component is never asked to enable itself before permission is
  /// actually known to be granted.
  void _enableMyLocation() {
    if (_myLocationEnabled || !mounted) return;
    setState(() => _myLocationEnabled = true);
  }

  void _onMapCreated(MapLibreMapController c) {
    _controller = c;
    _gameLayer.reset();
  }

  Future<void> _onStyleLoaded() async {
    final controller = _controller;
    try {
      if (controller != null && mounted) {
        await _gameLayer.install(
          controller,
          brightness: Theme.of(context).brightness,
        );
      }
    } catch (_) {
      // Game never blocks the tool: a style/layer failure just means no fog
      // is drawn this session, not a crash.
    }
    _refreshMapContent();
  }

  /// Fired on every camera-idle (post-pan/zoom) and once right after the
  /// gameState/PoiStore providers first resolve — `unawaited` since neither
  /// caller can usefully wait on it, and [GameLayer.refresh] is itself
  /// best-effort (see its own try/catch on each half).
  void _refreshMapContent() {
    final controller = _controller;
    if (controller == null) return;
    final state = ref.read(gameStateProvider).valueOrNull;
    if (state == null) return;
    final store = ref.read(poisStoreProvider).valueOrNull;
    unawaited(
      _gameLayer.refresh(controller, state: state, store: store, clock: clock),
    );
  }

  void _openBadgesSheet(GameState state) {
    final center = _controller?.cameraPosition?.target;
    final quartierPercent = center == null
        ? 0.0
        : quartierCompletion(
            cellIdFor(center.latitude, center.longitude),
            parseRevealedCells(state),
          );
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => BadgesSheet(
        unlockedBadges: state.badges,
        streakDays: state.streakDays,
        totalKm: state.totalKm,
        cellsRevealed: state.cellsRevealed,
        quartierPercent: quartierPercent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final initialCenter = _initialCameraCenter;
    if (initialCenter == null) {
      // Resolving the initial camera (last-known position, else Geneva —
      // see [_resolveInitialCamera]) is normally sub-frame fast; this only
      // ever shows for the handful of milliseconds that takes.
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // Re-runs the map refreshes whenever the underlying data changes, e.g. a
    // trip ends / a visit is recorded while this tab is on screen (the
    // journal replay itself already runs off the frame path inside
    // `gameStateProvider` — see that provider's own doc comment). `ref.listen`
    // rather than `ref.watch` here: only the HUD/empty-state text below needs
    // this build() to re-run on new data; the map refresh is an imperative,
    // side-effecting follow-up, not something to fold into the widget tree.
    ref.listen<AsyncValue<GameState>>(gameStateProvider, (_, __) {
      _refreshMapContent();
    });
    ref.listen<AsyncValue<PoiStore>>(poisStoreProvider, (_, __) {
      _refreshMapContent();
    });

    final gameStateAsync = ref.watch(gameStateProvider);
    final state = gameStateAsync.valueOrNull ?? const GameState();
    final brightness = Theme.of(context).brightness;
    final styleUrl = brightness == Brightness.dark
        ? kMapStyleUrlDark
        : kMapStyleUrlLight;
    final empty = isAdventureEmpty(state);

    return Scaffold(
      body: Stack(
        children: [
          MapLibreMap(
            key: ValueKey(styleUrl),
            styleString: styleUrl,
            initialCameraPosition: CameraPosition(
              target: initialCenter,
              zoom: 14,
            ),
            trackCameraPosition: true,
            myLocationEnabled: _myLocationEnabled,
            myLocationTrackingMode: MyLocationTrackingMode.none,
            attributionButtonPosition: AttributionButtonPosition.bottomLeft,
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
            onCameraIdle: _refreshMapContent,
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Align(
                alignment: Alignment.topLeft,
                child: AdventureHud(
                  coins: state.coins,
                  energy: state.energy,
                  xp: state.xp,
                  level: state.level,
                  onTap: () => _openBadgesSheet(state),
                ),
              ),
            ),
          ),
          if (empty)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Center(child: AdventureEmptyBanner()),
            ),
        ],
      ),
    );
  }
}

/// Compact, inset-safe HUD: pièces · énergie (barre fine) · niveau +
/// progression XP. Tapping opens the badges/stats sheet ([BadgesSheet]).
///
/// Pure-data widget (no provider reads of its own) so it can be pumped in
/// isolation with fixed values — see `adventure_screen_test.dart`.
class AdventureHud extends StatelessWidget {
  const AdventureHud({
    super.key,
    required this.coins,
    required this.energy,
    required this.xp,
    required this.level,
    this.onTap,
  });

  final int coins;
  final double energy;
  final int xp;
  final int level;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(AppRadii.stadium),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.stadium),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.paid_outlined,
                size: 18,
                color: theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 4),
              Text(formatWholeNumber(coins), style: theme.textTheme.labelLarge),
              const SizedBox(width: AppSpacing.md),
              Icon(Icons.bolt, size: 18, color: theme.colorScheme.onSurface),
              const SizedBox(width: 4),
              SizedBox(
                width: 48,
                height: 6,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: energyFraction(energy),
                    backgroundColor: theme.colorScheme.outlineVariant,
                    color: theme.colorScheme.secondary,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Text('Niveau $level', style: theme.textTheme.labelLarge),
              const SizedBox(width: 4),
              SizedBox(
                width: 40,
                height: 6,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: xpProgressFraction(xp, level),
                    backgroundColor: theme.colorScheme.outlineVariant,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The discreet "no activity yet" empty state — shown over the (necessarily
/// all-fog) map when [isAdventureEmpty] holds.
class AdventureEmptyBanner extends StatelessWidget {
  const AdventureEmptyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 1,
      borderRadius: BorderRadius.circular(AppRadii.stadium),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.explore_outlined,
              size: 18,
              color: theme.colorScheme.onSurface,
            ),
            const SizedBox(width: AppSpacing.sm),
            Text('Explorez en marchant !', style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// The badges/stats sheet opened by tapping [AdventureHud]: an 8-badge grid
/// (unlocked vs. locked, French labels via `badge_labels.dart`), the current
/// streak, cumulative distance, cells revealed, and the completion of
/// whichever quartier the map's current center sits in.
class BadgesSheet extends StatelessWidget {
  const BadgesSheet({
    super.key,
    required this.unlockedBadges,
    required this.streakDays,
    required this.totalKm,
    required this.cellsRevealed,
    required this.quartierPercent,
  });

  final Set<String> unlockedBadges;
  final int streakDays;
  final double totalKm;
  final int cellsRevealed;
  final double quartierPercent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Badges', style: theme.textTheme.headlineSmall),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final id in kBadgeOrder)
                  _BadgeChip(
                    label: badgeLabel(id),
                    unlocked: unlockedBadges.contains(id),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _StatRow(label: 'Série de jours', value: '$streakDays j'),
            _StatRow(
              label: 'Distance totale',
              value: '${totalKm.toStringAsFixed(1)} km',
            ),
            _StatRow(
              label: 'Cellules révélées',
              value: formatWholeNumber(cellsRevealed),
            ),
            _StatRow(
              label: 'Quartier actuel',
              value: formatPercent(quartierPercent),
            ),
          ],
        ),
      ),
    );
  }
}

class _BadgeChip extends StatelessWidget {
  const _BadgeChip({required this.label, required this.unlocked});
  final String label;
  final bool unlocked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Chip(
      avatar: Icon(
        unlocked ? Icons.emoji_events : Icons.lock_outline,
        size: 16,
      ),
      label: Text(label),
      backgroundColor: unlocked
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHighest,
      labelStyle: theme.textTheme.bodySmall?.copyWith(
        color: unlocked
            ? theme.colorScheme.onPrimaryContainer
            : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          Text(value, style: theme.textTheme.labelLarge),
        ],
      ),
    );
  }
}
