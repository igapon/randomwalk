import 'package:shared_preferences/shared_preferences.dart';

import '../valhalla/models.dart';

/// How much weight a single session's speed carries against the running
/// average. Low enough that one outlier session (a bus caught mid-walk, a
/// coasting descent) cannot swing the estimate on its own; high enough that
/// a handful of sessions is enough to feel like it has "learned" the user.
const double _kEmaAlpha = 0.3;

/// Starting points for a profile with no recorded history yet — a brisk
/// walk and a moderate ride, picked to be usable (for loop-length maths, see
/// task 6) before the first session has ever completed.
const double _kDefaultWalkKmh = 4.5;
const double _kDefaultBikeKmh = 16.0;

/// Plausibility bounds (brief §Task 3): a computed session speed outside
/// these is not "a fast/slow walk" or "a fast/slow ride", it is GPS noise, a
/// mode of transport other than the selected profile, or a session recorded
/// while stationary with drift — the point is catching those, not policing
/// pace. A session outside its profile's bounds is ignored outright: no EMA
/// update, and no history at all for a session that clearly wasn't what it
/// claims to be.
const double _kWalkMinKmh = 2;
const double _kWalkMaxKmh = 10;
const double _kBikeMinKmh = 8;
const double _kBikeMaxKmh = 35;

/// Below either of these a session is too short to say anything meaningful
/// about pace — the same reasoning as `trip_snapshot.dart`'s plausibility
/// minimum, but for speed rather than step count. Ignored silently: a short
/// session is common (a false start, a walk to check the mailbox) and must
/// never nudge the estimate.
const double _kMinSessionKm = 0.3;
const Duration _kMinSessionDuration = Duration(minutes: 3);

const _kWalkKey = 'speed_ema_walk';
const _kBikeKey = 'speed_ema_bike';

/// Per-profile average speed, learned session by session so loop-length
/// planning (task 6) can turn a target duration into a target distance
/// without asking the user how fast they walk or ride.
///
/// One exponential moving average per [RoutingProfile], persisted in
/// `shared_preferences` under `speed_ema_walk`/`speed_ema_bike` so it
/// survives app restarts and is available on the very first trip of a fresh
/// install (via the profile's default).
class SpeedHistoryStore {
  /// The learned (or default, if no session has ever qualified) average
  /// speed for [profile].
  Future<double> speedKmh(RoutingProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyFor(profile)) ?? _defaultFor(profile);
  }

  /// Folds one finished session into [profile]'s average, unless it is too
  /// short to be meaningful or its speed falls outside what that profile can
  /// plausibly produce — either way, silently ignored: a rejected session
  /// must never throw or otherwise interrupt the trip it came from.
  Future<void> recordSession(
      RoutingProfile profile, double sessionKm, Duration elapsed) async {
    if (sessionKm <= _kMinSessionKm || elapsed <= _kMinSessionDuration) {
      return;
    }
    final hours = elapsed.inMicroseconds / Duration.microsecondsPerHour;
    final speedKmh = sessionKm / hours;
    if (!_isPlausible(profile, speedKmh)) return;

    final prefs = await SharedPreferences.getInstance();
    final key = _keyFor(profile);
    final current = prefs.getDouble(key) ?? _defaultFor(profile);
    final next = _kEmaAlpha * speedKmh + (1 - _kEmaAlpha) * current;
    await prefs.setDouble(key, next);
  }

  static String _keyFor(RoutingProfile profile) =>
      profile == RoutingProfile.walk ? _kWalkKey : _kBikeKey;

  static double _defaultFor(RoutingProfile profile) =>
      profile == RoutingProfile.walk ? _kDefaultWalkKmh : _kDefaultBikeKmh;

  static bool _isPlausible(RoutingProfile profile, double speedKmh) =>
      profile == RoutingProfile.walk
          ? speedKmh >= _kWalkMinKmh && speedKmh <= _kWalkMaxKmh
          : speedKmh >= _kBikeMinKmh && speedKmh <= _kBikeMaxKmh;
}
