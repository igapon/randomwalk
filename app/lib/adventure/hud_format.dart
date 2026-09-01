import 'dart:math' as math;

/// Pure HUD formatting/derivation helpers for the Aventure tab — kept apart
/// from `adventure_screen.dart`'s widgets so the arithmetic (XP-progress,
/// energy-bar fraction) is unit-testable without pumping anything.

/// Cumulative XP required to *reach* [level] — mirrors `reducers.dart`'s
/// private `_levelForXp` threshold (`100 * n^1.5`), duplicated here (rather
/// than exported from reducers.dart) since it is presentation math, not
/// state-reduction logic: level 0's threshold is 0 XP, matching that
/// `_levelForXp` returns 0 for any `xp < 100 * 1^1.5`.
double xpThresholdForLevel(int level) =>
    level <= 0 ? 0 : 100 * math.pow(level, 1.5).toDouble();

/// Fraction (0.0-1.0) of the way from [level]'s own cumulative XP threshold
/// to the next level's, given the player's total [xp]. Used to draw the HUD's
/// "niveau + progression XP" bar.
///
/// Clamped to `[0, 1]`: a [xp]/[level] pair that is inconsistent with
/// [xpThresholdForLevel] (e.g. a stale [level] read a frame before [xp]
/// updates) never produces a nonsensical bar past either end.
double xpProgressFraction(int xp, int level) {
  final lower = xpThresholdForLevel(level);
  final upper = xpThresholdForLevel(level + 1);
  if (upper <= lower) return 1.0;
  return ((xp - lower) / (upper - lower)).clamp(0.0, 1.0);
}

/// Fraction (0.0-1.0) for the energy bar, from a `GameState.energy` value
/// that is normally already clamped to `[0, 100]` by the reducers — clamped
/// again here defensively since this is a display concern, not a state
/// invariant this file can rely on staying true forever.
double energyFraction(double energy) => (energy / 100).clamp(0.0, 1.0);

/// `1 234` — thin-space-grouped thousands, matching the Bricolage
/// display-number style used for distance/duration elsewhere in the app
/// (brief: "pièces · énergie · niveau + progression XP (Bricolage
/// numbers)"). Negative numbers are not expected (coins/xp never go
/// negative — see reducers.dart) and are not specially handled.
String formatWholeNumber(num value) {
  final digits = value.round().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    final fromEnd = digits.length - i;
    if (i > 0 && fromEnd % 3 == 0) buffer.write(' '); // thin space
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Whole-percent label for a `quartierCompletion`-style fraction, e.g.
/// `0.256` → `'26 %'`.
String formatPercent(double fraction) =>
    '${(fraction.clamp(0.0, 1.0) * 100).round()} %';
