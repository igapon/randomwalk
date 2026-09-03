// Pure formatting helpers for the "Historique" screens — kept apart from
// the widgets so the string logic is unit-testable without pumping
// anything, same split `adventure/hud_format.dart` uses for its HUD.

const _kMonthsFr = [
  'janvier',
  'février',
  'mars',
  'avril',
  'mai',
  'juin',
  'juillet',
  'août',
  'septembre',
  'octobre',
  'novembre',
  'décembre',
];

/// `30 août 2026` — [d] read in local time, since a trip's calendar date is
/// whatever day the walker actually experienced it on, not UTC's.
String formatHistoryDate(DateTime d) {
  final local = d.toLocal();
  return '${local.day} ${_kMonthsFr[local.month - 1]} ${local.year}';
}

/// `1 h 24` above an hour, `24 min` below — deliberately coarser than
/// `session_screen.dart`'s live "Xh Ym Zs" readout: a finished trip's history
/// entry has no use for second-level precision.
String formatTripDuration(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes % 60;
  if (hours > 0) return '$hours h ${minutes.toString().padLeft(2, '0')}';
  return '$minutes min';
}

/// `4,20 km` — comma decimal separator, matching the French-locale style
/// already used for a banked distance elsewhere (see `main.dart`'s
/// `InterruptedTripBanner`).
String formatTripDistance(double km) =>
    '${km.toStringAsFixed(2).replaceAll('.', ',')} km';

/// `11,4 km/h`.
String formatTripSpeed(double kmh) =>
    '${kmh.toStringAsFixed(1).replaceAll('.', ',')} km/h';
