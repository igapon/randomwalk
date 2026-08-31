/// `Build.MANUFACTURER` values (see `DeviceChannel.kt`) for Android OEMs
/// known to kill background location aggressively beyond stock Android's
/// doze/app-standby — e.g. via custom "autostart"/per-app battery managers.
/// Lower-case: comparisons are case-insensitive (`Build.MANUFACTURER` is
/// typically lower-case already, e.g. "xiaomi", but this does not rely on
/// that).
const kAggressiveBatteryOems = <String>{
  'xiaomi',
  'oppo',
  'vivo',
  'oneplus',
  'huawei',
  'samsung',
};

/// True when [manufacturer] (`Build.MANUFACTURER`, case-insensitive)
/// belongs to [kAggressiveBatteryOems]. Settings uses this to show its
/// "Suivi fiable en arrière-plan" tile only on devices where it is actually
/// useful — showing it unconditionally would be noise on stock/Pixel-like
/// builds, where doze is the only mechanism (already covered elsewhere by
/// the "Autoriser tout le temps" rationale).
bool isAggressiveBatteryOem(String? manufacturer) {
  if (manufacturer == null) return false;
  return kAggressiveBatteryOems.contains(manufacturer.toLowerCase());
}
