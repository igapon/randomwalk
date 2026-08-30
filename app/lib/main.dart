import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:randomwalk/map/map_screen.dart';

void main() => runApp(const ProviderScope(child: RandomWalkApp()));

class RandomWalkApp extends StatelessWidget {
  const RandomWalkApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'RandomWalk',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const HomeShell(),
      );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  static final _screens = <Widget>[
    const MapScreen(),
    const Center(child: Text('Session')),    // remplacé Task 9
    const Center(child: Text('Classement')), // remplacé Task 10
  ];
  @override
  Widget build(BuildContext context) => Scaffold(
        body: _screens[_tab],
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
