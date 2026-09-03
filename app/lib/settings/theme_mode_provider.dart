/// The live, app-wide "Thème" preference — see `theme_mode_store.dart`'s
/// own doc comment for why this is a plain [ThemeMode] rather than a
/// bespoke enum.
///
/// Overridden once at boot in `main.dart` with whatever [ThemeModeStore]
/// already has persisted (same "resolve before `runApp`" shape
/// `onboarded`/`trip.restore()` already use there, so the very first frame
/// renders in the right mode instead of flashing "Système" first) —
/// [ThemeModeTile] (`theme_mode_tile.dart`) is the only other writer,
/// applying a change LIVE via `.notifier.state =` (picked up immediately by
/// `MaterialApp.themeMode` in `main.dart`'s `RandomWalkApp`, no restart)
/// alongside persisting it for next launch.
library;

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'theme_mode_store.dart';

final themeModeProvider = StateProvider<ThemeMode>((ref) => kThemeModeDefault);
