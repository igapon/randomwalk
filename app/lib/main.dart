import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:randomwalk/leaderboard/leaderboard_screen.dart';
import 'package:randomwalk/leaderboard/repository.dart';
import 'package:randomwalk/map/map_screen.dart';
import 'package:randomwalk/session/session_screen.dart';
import 'package:randomwalk/settings/identity.dart';
import 'package:randomwalk/settings/settings_screen.dart';
import 'package:randomwalk/theme/theme.dart';
import 'package:randomwalk/trip/trip_controller.dart';

void main() => runApp(const ProviderScope(child: RandomWalkApp()));

class RandomWalkApp extends StatelessWidget {
  const RandomWalkApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'RandomWalk',
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

class _HomeShellState extends ConsumerState<HomeShell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // The shared SessionController (see trip_controller.dart) outlives
    // every screen — MapScreen and SessionScreen both start/stop trips
    // through it, but only HomeShell's Scaffold is always mounted, so its
    // callbacks are wired here once instead of per-screen.
    final session = ref.read(sessionControllerProvider);
    session.onSessionEnded = _onSessionEnded;
    session.onSessionError = _onSessionError;
  }

  /// Best-effort submit of the newly-updated cumulative total after a
  /// session ends. `totalKm` here is already the cumulative total from
  /// [TotalDistanceStore] (see SessionController._finishSession), not the
  /// single-session distance. On failure the local total remains the
  /// source of truth; it is retried on the next session end or the next
  /// time the leaderboard tab opens.
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
      body: screens[_tab],
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
