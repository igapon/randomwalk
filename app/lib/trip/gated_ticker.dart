import 'dart:async';

/// Starts/stops a periodic callback based on a boolean gate, idempotently.
///
/// Extracted out of `MapScreen`/`SessionScreen` so the "only tick while a
/// trip is recording" gating is unit-testable without a widget harness —
/// both screens poll `TripController`'s live distance/duration once a
/// second while recording (it only notifies listeners on start/stop, not
/// per GPS fix — see trip_controller.dart), and the naive version of that
/// (an unconditional `Timer.periodic` started in `initState`) kept ticking
/// — and rebuilding the screen — even while idle, burning battery for no
/// visible effect.
class GatedTicker {
  final void Function() onTick;
  final Duration interval;
  Timer? _timer;

  GatedTicker({
    required this.onTick,
    this.interval = const Duration(seconds: 1),
  });

  /// Whether the periodic callback is currently running.
  bool get isActive => _timer != null;

  /// Starts the ticker if [active] and not already running; stops it if
  /// not [active]. Safe to call every build — a no-op when the desired
  /// state already matches.
  void sync(bool active) {
    if (active) {
      _timer ??= Timer.periodic(interval, (_) => onTick());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
