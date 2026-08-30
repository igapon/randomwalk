import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';

import 'device_channel.dart';

/// The three states that matter to us out of permission_handler's six:
/// `restricted`/`limited`/`provisional` are iOS-only concepts and collapse
/// into [denied] here.
enum PermissionState { granted, denied, permanentlyDenied }

/// How much of a trip Android will actually let us record.
enum TrackingMode {
  /// "Autoriser tout le temps" granted: the foreground service keeps
  /// recording with the screen off and the app swiped away.
  background,

  /// Only "pendant l'utilisation" granted. The service still runs, but the
  /// user is told the OS may cut tracking when the screen goes off — which
  /// OEM battery managers do in practice.
  foregroundOnly,
}

enum TripPermissionOutcome {
  /// Enough was granted to start recording (see [TripPermissions.mode]).
  ready,

  /// Location is switched off device-wide. A location foreground service
  /// cannot legally be started in this state (Android 14+ throws).
  locationServiceOff,

  /// The user refused precise location. Nothing can be recorded.
  locationDenied,

  /// We sent the user to the Android settings screen to pick "Autoriser
  /// tout le temps". The trip is deliberately NOT started: the app is on
  /// its way to the background, and starting a `location` foreground
  /// service from the background without background-location permission
  /// throws `ForegroundServiceStartNotAllowedException` on Android 14+.
  openedSettings,
}

class TripPermissions {
  final TripPermissionOutcome outcome;
  final TrackingMode mode;

  /// Whether the step counter can be read (ACTIVITY_RECOGNITION, API 29+).
  /// A refusal never blocks a trip — distance is the thing being recorded.
  final bool stepsAvailable;

  const TripPermissions({
    required this.outcome,
    this.mode = TrackingMode.foregroundOnly,
    this.stepsAvailable = false,
  });

  bool get canStart => outcome == TripPermissionOutcome.ready;
}

/// Everything the coordinator needs from the platform, as an interface, so
/// the flow below — which is nearly all of the UX risk in this feature — is
/// testable without an Android device or a plugin harness.
abstract class TripPermissionService {
  Future<int> androidSdkInt();
  Future<bool> isLocationServiceEnabled();

  Future<PermissionState> notificationStatus();
  Future<PermissionState> requestNotifications();

  Future<PermissionState> fineLocationStatus();
  Future<PermissionState> requestFineLocation();

  Future<PermissionState> backgroundLocationStatus();
  Future<PermissionState> requestBackgroundLocation();

  Future<PermissionState> activityRecognitionStatus();
  Future<PermissionState> requestActivityRecognition();

  Future<void> openSettings();
}

/// Remembers which prompts have already been shown, so a refusal is
/// respected instead of re-asked on every single trip start.
abstract class PermissionMemory {
  Future<bool> wasAsked(String key);
  Future<void> markAsked(String key);
}

class PrefsPermissionMemory implements PermissionMemory {
  static const _prefix = 'perm_asked_';

  @override
  Future<bool> wasAsked(String key) async =>
      (await SharedPreferences.getInstance()).getBool('$_prefix$key') ?? false;

  @override
  Future<void> markAsked(String key) async =>
      (await SharedPreferences.getInstance()).setBool('$_prefix$key', true);
}

const _kAskedNotifications = 'notifications';
const _kAskedBackgroundLocation = 'background_location';
const _kAskedActivityRecognition = 'activity_recognition';

/// Runs the permission sequence at the one moment it makes sense — the
/// first time the user starts a trip — rather than in a burst at first
/// launch (brief §4).
///
/// The order is deliberate and is asserted by the tests:
///  1. notifications (Android 13+), so the persistent trip notification is
///     visible at all;
///  2. precise location, the only genuinely blocking one;
///  3. a French rationale screen explaining what "Autoriser tout le temps"
///     buys, *before* the system prompt — Android 11+ answers that prompt
///     with a silent permanent denial, so an unexplained redirect to the
///     settings screen would be baffling;
///  4. activity recognition for the step counter.
///
/// Every prompt is shown at most once per install ([PermissionMemory]); a
/// refusal degrades the trip instead of blocking it, except for precise
/// location, which nothing can substitute for.
class TripPermissionCoordinator {
  final TripPermissionService _service;
  final PermissionMemory _memory;

  /// Shows the "Autoriser tout le temps" explanation and resolves to
  /// whether the user wants to continue to the system prompt.
  final Future<bool> Function() showBackgroundRationale;

  TripPermissionCoordinator(
    this._service, {
    required this.showBackgroundRationale,
    PermissionMemory? memory,
  }) : _memory = memory ?? PrefsPermissionMemory();

  Future<TripPermissions> ensureForTrip() async {
    final sdkInt = await _service.androidSdkInt();

    // 1. Notifications — Android 13+ only; before that the FGS notification
    // needs no permission.
    if (sdkInt >= 33) {
      await _askOnce(
        _kAskedNotifications,
        _service.notificationStatus,
        _service.requestNotifications,
      );
    }

    // 2. The two blocking checks, in the order Android itself requires:
    // the device switch first, then the app permission.
    if (!await _service.isLocationServiceEnabled()) {
      return const TripPermissions(
          outcome: TripPermissionOutcome.locationServiceOff);
    }
    var fine = await _service.fineLocationStatus();
    if (fine != PermissionState.granted) {
      fine = await _service.requestFineLocation();
    }
    if (fine != PermissionState.granted) {
      return const TripPermissions(
          outcome: TripPermissionOutcome.locationDenied);
    }

    // 3. Background location. Requested only after foreground is granted —
    // Android rejects the pair asked together.
    final background = await _resolveBackgroundLocation();
    if (background == _BackgroundOutcome.sentToSettings) {
      return const TripPermissions(
          outcome: TripPermissionOutcome.openedSettings);
    }

    // 4. Steps. Never blocking, and below API 29 the sensor is readable
    // with no runtime permission at all.
    final stepsAvailable = sdkInt < 29 ||
        await _askOnce(
              _kAskedActivityRecognition,
              _service.activityRecognitionStatus,
              _service.requestActivityRecognition,
            ) ==
            PermissionState.granted;

    return TripPermissions(
      outcome: TripPermissionOutcome.ready,
      mode: background == _BackgroundOutcome.granted
          ? TrackingMode.background
          : TrackingMode.foregroundOnly,
      stepsAvailable: stepsAvailable,
    );
  }

  /// Re-reads the background-location state without prompting. Called when
  /// the app comes back to the foreground, so a user who granted "Autoriser
  /// tout le temps" in the settings screen sees the degraded-mode banner
  /// disappear without having to restart the trip.
  Future<TrackingMode> currentTrackingMode() async =>
      await _service.backgroundLocationStatus() == PermissionState.granted
          ? TrackingMode.background
          : TrackingMode.foregroundOnly;

  Future<_BackgroundOutcome> _resolveBackgroundLocation() async {
    if (await _service.backgroundLocationStatus() == PermissionState.granted) {
      return _BackgroundOutcome.granted;
    }
    // Asked once, refused once: respect it. The user can still change their
    // mind from the banner's own action, which goes straight to settings.
    if (await _memory.wasAsked(_kAskedBackgroundLocation)) {
      return _BackgroundOutcome.denied;
    }
    await _memory.markAsked(_kAskedBackgroundLocation);

    if (!await showBackgroundRationale()) return _BackgroundOutcome.denied;

    final result = await _service.requestBackgroundLocation();
    if (result == PermissionState.granted) return _BackgroundOutcome.granted;
    if (result == PermissionState.permanentlyDenied) {
      // Android 11+ answers this request without ever showing a dialog:
      // "Autoriser tout le temps" can only be picked in system settings.
      await _service.openSettings();
      return _BackgroundOutcome.sentToSettings;
    }
    return _BackgroundOutcome.denied;
  }

  Future<PermissionState> _askOnce(
    String key,
    Future<PermissionState> Function() status,
    Future<PermissionState> Function() request,
  ) async {
    final current = await status();
    if (current == PermissionState.granted) return current;
    if (await _memory.wasAsked(key)) return current;
    await _memory.markAsked(key);
    return request();
  }
}

enum _BackgroundOutcome { granted, denied, sentToSettings }

/// permission_handler (+ the app's own [DeviceChannel] for the API level)
/// behind [TripPermissionService].
class PluginPermissionService implements TripPermissionService {
  final DeviceChannel _device;
  int? _sdkInt;

  PluginPermissionService([DeviceChannel? device])
      : _device = device ?? const DeviceChannel();

  static PermissionState _map(ph.PermissionStatus status) {
    if (status.isGranted || status.isLimited || status.isProvisional) {
      return PermissionState.granted;
    }
    if (status.isPermanentlyDenied || status.isRestricted) {
      return PermissionState.permanentlyDenied;
    }
    return PermissionState.denied;
  }

  @override
  Future<int> androidSdkInt() async => _sdkInt ??= await _device.sdkInt();

  @override
  Future<bool> isLocationServiceEnabled() async =>
      ph.Permission.location.serviceStatus.isEnabled;

  @override
  Future<PermissionState> notificationStatus() async =>
      _map(await ph.Permission.notification.status);

  @override
  Future<PermissionState> requestNotifications() async =>
      _map(await ph.Permission.notification.request());

  @override
  Future<PermissionState> fineLocationStatus() async =>
      _map(await ph.Permission.locationWhenInUse.status);

  @override
  Future<PermissionState> requestFineLocation() async =>
      _map(await ph.Permission.locationWhenInUse.request());

  @override
  Future<PermissionState> backgroundLocationStatus() async =>
      _map(await ph.Permission.locationAlways.status);

  @override
  Future<PermissionState> requestBackgroundLocation() async =>
      _map(await ph.Permission.locationAlways.request());

  @override
  Future<PermissionState> activityRecognitionStatus() async =>
      _map(await ph.Permission.activityRecognition.status);

  @override
  Future<PermissionState> requestActivityRecognition() async =>
      _map(await ph.Permission.activityRecognition.request());

  @override
  Future<void> openSettings() async => ph.openAppSettings();
}
