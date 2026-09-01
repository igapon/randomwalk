import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/tracking/permissions.dart';

/// Scriptable stand-in for permission_handler + the OS location switch.
/// Records the exact order calls were made in, because "never nag" and
/// "foreground location before background location" are both ordering
/// properties, not value properties.
class FakePermissionService implements TripPermissionService {
  FakePermissionService({
    this.sdkInt = 34,
    this.locationServiceEnabled = true,
    this.notifications = PermissionState.granted,
    this.fineLocation = PermissionState.granted,
    this.backgroundLocation = PermissionState.denied,
    this.backgroundLocationOnRequest,
    this.activityRecognition = PermissionState.granted,
  });

  int sdkInt;
  bool locationServiceEnabled;
  PermissionState notifications;
  PermissionState fineLocation;
  PermissionState backgroundLocation;
  PermissionState activityRecognition;

  /// What the *request* resolves to, when it differs from the current
  /// status (i.e. the user answers the dialog).
  PermissionState? fineLocationOnRequest;
  PermissionState? backgroundLocationOnRequest;

  final calls = <String>[];
  int settingsOpened = 0;

  @override
  Future<int> androidSdkInt() async => sdkInt;

  @override
  Future<bool> isLocationServiceEnabled() async {
    calls.add('serviceEnabled');
    return locationServiceEnabled;
  }

  @override
  Future<PermissionState> notificationStatus() async => notifications;

  @override
  Future<PermissionState> requestNotifications() async {
    calls.add('requestNotifications');
    return notifications;
  }

  @override
  Future<PermissionState> fineLocationStatus() async => fineLocation;

  @override
  Future<PermissionState> requestFineLocation() async {
    calls.add('requestFineLocation');
    return fineLocationOnRequest ?? fineLocation;
  }

  @override
  Future<PermissionState> backgroundLocationStatus() async =>
      backgroundLocation;

  @override
  Future<PermissionState> requestBackgroundLocation() async {
    calls.add('requestBackgroundLocation');
    return backgroundLocationOnRequest ?? backgroundLocation;
  }

  @override
  Future<PermissionState> activityRecognitionStatus() async =>
      activityRecognition;

  @override
  Future<PermissionState> requestActivityRecognition() async {
    calls.add('requestActivityRecognition');
    return activityRecognition;
  }

  @override
  Future<void> openSettings() async {
    calls.add('openSettings');
    settingsOpened++;
  }
}

class FakeMemory implements PermissionMemory {
  final asked = <String>{};
  @override
  Future<bool> wasAsked(String key) async => asked.contains(key);
  @override
  Future<void> markAsked(String key) async => asked.add(key);
}

void main() {
  late FakePermissionService service;
  late FakeMemory memory;
  late int rationaleShown;
  late bool rationaleAccepted;

  TripPermissionCoordinator coordinator() => TripPermissionCoordinator(
    service,
    memory: memory,
    showBackgroundRationale: () async {
      rationaleShown++;
      return rationaleAccepted;
    },
  );

  setUp(() {
    service = FakePermissionService();
    memory = FakeMemory();
    rationaleShown = 0;
    rationaleAccepted = true;
  });

  group('happy path', () {
    test('everything granted yields background tracking', () async {
      service
        ..backgroundLocation = PermissionState.granted
        ..activityRecognition = PermissionState.granted;

      final decision = await coordinator().ensureForTrip();

      expect(decision.outcome, TripPermissionOutcome.ready);
      expect(decision.mode, TrackingMode.background);
      expect(decision.stepsAvailable, isTrue);
    });

    test(
      'asks in the brief order: notifications, location, then steps',
      () async {
        service
          ..notifications = PermissionState.denied
          ..fineLocation = PermissionState.denied
          ..fineLocationOnRequest = PermissionState.granted
          ..backgroundLocation = PermissionState.granted
          ..activityRecognition = PermissionState.denied;

        await coordinator().ensureForTrip();

        expect(
          service.calls,
          containsAllInOrder(<String>[
            'requestNotifications',
            'requestFineLocation',
            'requestActivityRecognition',
          ]),
        );
      },
    );

    test('already-granted permissions are not re-requested', () async {
      service.backgroundLocation = PermissionState.granted;
      await coordinator().ensureForTrip();
      expect(service.calls, isNot(contains('requestNotifications')));
      expect(service.calls, isNot(contains('requestFineLocation')));
      expect(service.calls, isNot(contains('requestActivityRecognition')));
    });

    test('notifications are not requested below Android 13', () async {
      service
        ..sdkInt = 31
        ..notifications = PermissionState.denied
        ..backgroundLocation = PermissionState.granted;

      final decision = await coordinator().ensureForTrip();

      expect(service.calls, isNot(contains('requestNotifications')));
      expect(decision.outcome, TripPermissionOutcome.ready);
    });
  });

  group('blocking refusals', () {
    test('location services switched off blocks the trip', () async {
      service.locationServiceEnabled = false;
      final decision = await coordinator().ensureForTrip();
      expect(decision.outcome, TripPermissionOutcome.locationServiceOff);
      expect(service.calls, isNot(contains('requestFineLocation')));
    });

    test('fine location refused blocks the trip', () async {
      service.fineLocation = PermissionState.denied;
      final decision = await coordinator().ensureForTrip();
      expect(decision.outcome, TripPermissionOutcome.locationDenied);
    });

    test('fine location permanently refused blocks the trip', () async {
      service.fineLocation = PermissionState.permanentlyDenied;
      final decision = await coordinator().ensureForTrip();
      expect(decision.outcome, TripPermissionOutcome.locationDenied);
    });

    test('a refused fine location never goes on to ask for the rest', () async {
      service.fineLocation = PermissionState.denied;
      await coordinator().ensureForTrip();
      expect(service.calls, isNot(contains('requestBackgroundLocation')));
      expect(service.calls, isNot(contains('requestActivityRecognition')));
      expect(rationaleShown, 0);
    });
  });

  group('background location — the "Autoriser tout le temps" step', () {
    test('the rationale is shown before the system request', () async {
      service.backgroundLocationOnRequest = PermissionState.granted;
      final decision = await coordinator().ensureForTrip();
      expect(rationaleShown, 1);
      expect(decision.mode, TrackingMode.background);
    });

    test('declining the rationale degrades to foreground-only', () async {
      rationaleAccepted = false;
      final decision = await coordinator().ensureForTrip();
      expect(decision.outcome, TripPermissionOutcome.ready);
      expect(decision.mode, TrackingMode.foregroundOnly);
      expect(service.calls, isNot(contains('requestBackgroundLocation')));
    });

    test('declining the rationale still starts the trip', () async {
      rationaleAccepted = false;
      final decision = await coordinator().ensureForTrip();
      expect(decision.outcome, TripPermissionOutcome.ready);
    });

    test('Android 11+ permanent denial redirects to settings, once', () async {
      service.backgroundLocationOnRequest = PermissionState.permanentlyDenied;
      final decision = await coordinator().ensureForTrip();

      expect(service.settingsOpened, 1);
      // Deliberately does NOT start the trip: the app is being sent to the
      // settings screen, and starting a location foreground service from the
      // background without "allow all the time" throws on Android 14+.
      expect(decision.outcome, TripPermissionOutcome.openedSettings);
    });

    test(
      'a plain denial degrades to foreground-only without settings',
      () async {
        service.backgroundLocationOnRequest = PermissionState.denied;
        final decision = await coordinator().ensureForTrip();
        expect(service.settingsOpened, 0);
        expect(decision.outcome, TripPermissionOutcome.ready);
        expect(decision.mode, TrackingMode.foregroundOnly);
      },
    );

    test('background location is never requested before foreground', () async {
      service
        ..fineLocation = PermissionState.denied
        ..fineLocationOnRequest = PermissionState.granted
        ..backgroundLocationOnRequest = PermissionState.granted;
      await coordinator().ensureForTrip();
      expect(
        service.calls.indexOf('requestFineLocation'),
        lessThan(service.calls.indexOf('requestBackgroundLocation')),
      );
    });
  });

  group('never nag', () {
    test('the rationale is shown at most once per install', () async {
      rationaleAccepted = false;
      await coordinator().ensureForTrip();
      await coordinator().ensureForTrip();
      await coordinator().ensureForTrip();
      expect(rationaleShown, 1);
    });

    test('a refused background permission is not re-requested', () async {
      service.backgroundLocationOnRequest = PermissionState.denied;
      await coordinator().ensureForTrip();
      service.calls.clear();
      await coordinator().ensureForTrip();
      expect(service.calls, isNot(contains('requestBackgroundLocation')));
    });

    test('a refused step permission is not re-requested', () async {
      service.activityRecognition = PermissionState.denied;
      service.backgroundLocation = PermissionState.granted;
      await coordinator().ensureForTrip();
      service.calls.clear();
      await coordinator().ensureForTrip();
      expect(service.calls, isNot(contains('requestActivityRecognition')));
    });

    test('a refused notification permission is not re-requested', () async {
      service.notifications = PermissionState.denied;
      service.backgroundLocation = PermissionState.granted;
      await coordinator().ensureForTrip();
      service.calls.clear();
      await coordinator().ensureForTrip();
      expect(service.calls, isNot(contains('requestNotifications')));
    });

    test('granting later is picked up without asking again', () async {
      service.backgroundLocationOnRequest = PermissionState.denied;
      expect(
        (await coordinator().ensureForTrip()).mode,
        TrackingMode.foregroundOnly,
      );

      // The user went to Android settings on their own and allowed it.
      service.backgroundLocation = PermissionState.granted;
      final second = await coordinator().ensureForTrip();
      expect(second.mode, TrackingMode.background);
      expect(rationaleShown, 1);
    });
  });

  group('steps availability', () {
    test('refusing activity recognition still starts the trip', () async {
      service
        ..activityRecognition = PermissionState.denied
        ..backgroundLocation = PermissionState.granted;
      final decision = await coordinator().ensureForTrip();
      expect(decision.outcome, TripPermissionOutcome.ready);
      expect(decision.stepsAvailable, isFalse);
    });

    test('activity recognition is not requested below Android 10', () async {
      service
        ..sdkInt = 28
        ..activityRecognition = PermissionState.denied
        ..backgroundLocation = PermissionState.granted;
      final decision = await coordinator().ensureForTrip();
      expect(service.calls, isNot(contains('requestActivityRecognition')));
      // Below API 29 the sensor needs no runtime permission at all.
      expect(decision.stepsAvailable, isTrue);
    });
  });
}
