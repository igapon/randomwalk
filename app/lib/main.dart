import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:randomwalk/coverage/coverage_repository.dart';
import 'package:randomwalk/exploration/edges_store.dart';
import 'package:randomwalk/exploration/exploration_recorder.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/leaderboard/leaderboard_screen.dart';
import 'package:randomwalk/leaderboard/repository.dart';
import 'package:randomwalk/map/map_screen.dart';
import 'package:randomwalk/session/recorder.dart';
import 'package:randomwalk/session/session_screen.dart';
import 'package:randomwalk/settings/identity.dart';
import 'package:randomwalk/settings/settings_screen.dart';
import 'package:randomwalk/theme/theme.dart';
import 'package:randomwalk/theme/tokens.dart';
import 'package:randomwalk/tracking/permission_rationale.dart';
import 'package:randomwalk/tracking/permissions.dart';
import 'package:randomwalk/tracking/tracking_service.dart';
import 'package:randomwalk/trip/active_route_store.dart';
import 'package:randomwalk/trip/trip_controller.dart';
import 'package:randomwalk/trip/trip_messages.dart';
import 'package:randomwalk/valhalla/engine.dart';
import 'package:randomwalk/valhalla/engine_channel.dart';

/// Needed by the permission flow: the "Autoriser tout le temps" rationale
/// is raised by [TripController], which has no `BuildContext` of its own.
final appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Opens the port the foreground-service isolate publishes snapshots on.
  // Must happen before runApp, or early messages are dropped.
  ForegroundServiceTripTracker.initCommunication();

  final trip = await _buildTripController();
  // Restored *before* the first frame so a trip that is still recording —
  // or one the OS killed — is on screen immediately, rather than flashing
  // an idle map first.
  await trip.restore();

  runApp(ProviderScope(
    overrides: [tripControllerProvider.overrideWith((ref) => trip)],
    child: const RandomWalkApp(),
  ));
}

Future<TripController> _buildTripController() async {
  final dir = await getApplicationSupportDirectory();
  // Same root the routing providers use (see `coverageRepositoryProvider`);
  // built here too because the trip controller exists before the
  // ProviderScope does, and only needs the read-only lookup
  // (`cachedTileDirPath`, below — disk only, no network call). The
  // `http.Client()` `CoverageRepository` otherwise requires is therefore
  // never actually used through this instance; closing it immediately
  // avoids leaking a real socket-owning resource for the rest of the app's
  // process lifetime (item 9) rather than keeping one open on the off
  // chance `resolveTileDir` grows a network path later — it would need its
  // own client if it ever does.
  final coverage = CoverageRepository(
      root: Directory('${dir.path}/tiles'), client: http.Client()..close());
  final permissions = TripPermissionCoordinator(
    PluginPermissionService(),
    showBackgroundRationale: () async {
      final context = appNavigatorKey.currentContext;
      if (context == null) return false;
      return BackgroundLocationRationale.show(context);
    },
  );

  // M4 exploration: best-effort post-trip processing (map-matching, covered
  // edges, fog reveal, journal events). `EdgesStore.open` is the only
  // `await` here that can fail outright (sqflite hiccup) — if it does, the
  // whole game layer stays off for this run rather than the app failing to
  // start; every other exploration failure mode is handled inside
  // `ExplorationRecorder` itself.
  Future<void> Function(FinishedTrip trip)? processTripExploration;
  try {
    final edgesStore = await EdgesStore.open('${dir.path}/covered_edges.db');
    final recorder = ExplorationRecorder(
      engineProvider: () => _buildExplorationEngine(coverage),
      edgesStore: edgesStore,
      journal: GameJournal(Directory('${dir.path}/game')),
      trackFile: File('${dir.path}/active_track.jsonl'),
    );
    processTripExploration = recorder.process;
  } catch (e) {
    debugPrint('main: exploration layer unavailable, game disabled: $e');
  }

  return TripController(
    tracker: ForegroundServiceTripTracker(
        File('${dir.path}/trip_snapshot.json')),
    routeStore: FileActiveRouteStore(File('${dir.path}/active_route.json')),
    totalStore: TotalDistanceStore(),
    ensurePermissions: permissions.ensureForTrip,
    readTrackingMode: permissions.currentTrackingMode,
    resolveTileDir: coverage.cachedTileDirPath,
    processTripExploration: processTripExploration,
  );
}

/// Builds and initializes a fresh [RoutingEngine] for one
/// [ExplorationRecorder.process] call's map-matching, or `null` when no tile
/// directory has been downloaded yet or the engine fails to initialize —
/// either way, [ExplorationRecorder] treats that exactly like a failed
/// match (see its `engineProvider` doc comment). A new instance per call
/// rather than a cached one: exploration processing runs at most once per
/// finished trip, far too infrequently to be worth keeping a native actor
/// (and its mmapped tiles) resident between trips.
Future<RoutingEngine?> _buildExplorationEngine(
    CoverageRepository coverage) async {
  final tileDirPath = await coverage.cachedTileDirPath();
  if (tileDirPath == null) return null;
  final engine = ChannelRoutingEngine();
  try {
    await engine.init(tileDirPath);
  } catch (_) {
    return null;
  }
  return engine;
}

class RandomWalkApp extends StatelessWidget {
  const RandomWalkApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'RandomWalk',
        navigatorKey: appNavigatorKey,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.system,
        home: const HomeShell(),
      );
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, this.screensOverride});
  final List<Widget>? screensOverride;

  static final List<Widget> defaultScreens = <Widget>[
    const MapScreen(),
    const SessionScreen(),
    const LeaderboardScreen(),
  ];

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with WidgetsBindingObserver {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The shared TripController outlives every screen — MapScreen and
    // SessionScreen both start/stop trips through it, but only HomeShell is
    // always mounted, so its callbacks are wired here once instead of
    // per-screen.
    final trip = ref.read(tripControllerProvider);
    trip.onSessionEnded = _onSessionEnded;
    trip.onSessionError = _onSessionError;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the Android settings screen is the one moment
    // "Autoriser tout le temps" can have changed under us.
    if (state == AppLifecycleState.resumed) {
      ref.read(tripControllerProvider).refreshTrackingMode();
    }
  }

  /// Best-effort submit of the newly-updated cumulative total after a trip
  /// ends. `totalKm` is already the cumulative total from
  /// [TotalDistanceStore] (see TripController._finalise), not the single
  /// trip's distance. On failure the local total remains the source of
  /// truth; it is retried on the next trip end or the next time the
  /// leaderboard tab opens.
  Future<void> _onSessionEnded(double totalKm) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final identity = await ref.read(identityStoreProvider).get();
      await ref.read(leaderboardRepositoryProvider).submit(identity, totalKm);
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(const SnackBar(
            content:
                Text('Score non synchronisé — nouvelle tentative plus tard.')));
      }
    }
  }

  Future<void> _onSessionError(String? errorMessage) async {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Signal GPS perdu — session enregistrée.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = widget.screensOverride ?? HomeShell.defaultScreens;
    final trip = ref.watch(tripControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('RandomWalk'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Réglages',
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: Column(
        children: [
          if (trip.isInterrupted) const InterruptedTripBanner(),
          if (trip.isRecording && trip.trackingMode == TrackingMode.foregroundOnly)
            const ForegroundOnlyBanner(),
          if (trip.isRecording && trip.gpsSilent) const GpsSilentBanner(),
          // IndexedStack, not `screens[_tab]`: every screen stays mounted
          // across tab switches, so the map keeps its native surface (and
          // everything drawn on it) instead of being rebuilt from scratch
          // each time the user glances at the session tab.
          Expanded(child: IndexedStack(index: _tab, children: screens)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.map), label: 'Carte'),
          NavigationDestination(icon: Icon(Icons.directions_walk), label: 'Session'),
          NavigationDestination(icon: Icon(Icons.emoji_events), label: 'Classement'),
        ],
      ),
    );
  }
}

/// Shown at cold start when a trip was recording and the process was killed
/// (see [TripState.interrupted]). Deliberately above the tab content, not
/// inside a screen: the choice is about the app's state, not the map's.
class InterruptedTripBanner extends ConsumerStatefulWidget {
  const InterruptedTripBanner({super.key});

  @override
  ConsumerState<InterruptedTripBanner> createState() =>
      _InterruptedTripBannerState();
}

class _InterruptedTripBannerState
    extends ConsumerState<InterruptedTripBanner> {
  bool _busy = false;

  Future<void> _run(Future<void> Function(TripController trip) action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action(ref.read(tripControllerProvider));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trip = ref.watch(tripControllerProvider);
    final km = trip.distanceKm.toStringAsFixed(2).replaceAll('.', ',');
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Trajet interrompu', style: theme.textTheme.titleSmall),
                  Text('$km km enregistrés', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            TextButton(
              onPressed: _busy ? null : () => _run((t) => t.finishInterrupted()),
              child: const Text('Terminer'),
            ),
            const SizedBox(width: AppSpacing.xs),
            FilledButton(
              onPressed: _busy ? null : () => _run((t) => t.resumeInterrupted()),
              child: const Text('Reprendre'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The recorder has gone a full minute without a position (see
/// [isGpsSilent]). Worth its own banner because it is the only tracking
/// failure with no other symptom: the trip looks like it is recording and
/// measures nothing, so without this the first the user hears of it is a
/// walk that came out at 0,00 km.
class GpsSilentBanner extends StatelessWidget {
  const GpsSilentBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: InkWell(
        onTap: () => PluginPermissionService().openSettings(),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          child: Row(
            children: [
              const Icon(Icons.gps_off, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(kGpsSilentMessage,
                    style: theme.textTheme.bodySmall),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Degraded mode (brief §4): "Autoriser tout le temps" was refused, so the
/// OS may stop feeding positions once the screen goes off. Tapping the
/// banner goes straight to the Android settings page that fixes it.
class ForegroundOnlyBanner extends ConsumerWidget {
  const ForegroundOnlyBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.tertiaryContainer,
      child: InkWell(
        onTap: () => PluginPermissionService().openSettings(),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Le suivi s\'arrêtera si l\'écran s\'éteint — '
                  'appuyez pour autoriser la localisation tout le temps.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
