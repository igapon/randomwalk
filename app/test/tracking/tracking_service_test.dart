import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/nav/nav_fields.dart';
import 'package:randomwalk/nav/tts.dart';
import 'package:randomwalk/tracking/adaptive_gps.dart';
import 'package:randomwalk/tracking/nav_seed.dart';
import 'package:randomwalk/tracking/tracking_service.dart';
import 'package:randomwalk/tracking/trip_snapshot.dart';
import 'package:randomwalk/valhalla/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/trip_fakes.dart';

/// The `flutter_foreground_task` prefix every `getData`/`saveData` key is
/// stored under (see that package's `_kPrefsKeyPrefix`, private to it) — not
/// exported, so the literal is duplicated here to seed `SharedPreferences`
/// the same way the plugin itself reads it back.
const _prefsPrefix = 'com.pravera.flutter_foreground_task.prefs.';

/// A speaker whose [init] is fully controlled by the test: either resolves
/// immediately with [available], or — with [hang] — never resolves at all,
/// standing in for a wedged native `OnInitListener` (see
/// `TtsChannel.startEngine`'s doc comment on the native side of this bug).
class FakeInitializableTtsSpeaker implements InitializableTtsSpeaker {
  FakeInitializableTtsSpeaker({this.available = true, this.hang = false});

  final bool available;
  final bool hang;

  @override
  Future<bool> init() =>
      hang ? Completer<bool>().future : Future.value(available);

  @override
  Future<void> speak(String text) async {}
}

TripSnapshot snapshot({
  TripStatus status = TripStatus.recording,
  double distanceKm = 2.4,
  int steps = 3100,
  int elapsedMinutes = 32,
}) =>
    TripSnapshot(
      status: status,
      distanceKm: distanceKm,
      steps: steps,
      startedAt: DateTime.utc(2026, 8, 30, 10, 0),
      updatedAt: DateTime.utc(2026, 8, 30, 10, 0).add(Duration(minutes: elapsedMinutes)),
      profile: RoutingProfile.walk,
      routeBound: false,
    );

void main() {
  group('notification text', () {
    test('reads as a sober one-liner in French formatting', () {
      expect(
        tripNotificationText(snapshot(), DateTime.utc(2026, 8, 30, 10, 32)),
        '2,4 km · 32 min',
      );
    });

    test('starts at zero rather than blank', () {
      expect(
        tripNotificationText(snapshot(distanceKm: 0),
            DateTime.utc(2026, 8, 30, 10, 0)),
        '0,0 km · 0 min',
      );
    });
  });

  group('isGpsSilent', () {
    final since = DateTime.utc(2026, 8, 30, 10, 0);

    test('a fix a moment ago is not silence', () {
      expect(
        isGpsSilent(
            now: DateTime.utc(2026, 8, 30, 10, 5),
            lastFixAt: DateTime.utc(2026, 8, 30, 10, 4, 30),
            recordingSince: since),
        isFalse,
      );
    });

    test('a minute without a single fix is silence', () {
      expect(
        isGpsSilent(
            now: DateTime.utc(2026, 8, 30, 10, 5),
            lastFixAt: DateTime.utc(2026, 8, 30, 10, 3, 30),
            recordingSince: since),
        isTrue,
      );
    });

    test('before the first fix the clock runs from the trip start', () {
      // The failure this exists for — geolocator not working in the service
      // isolate — never produces a first fix at all, so a null lastFixAt
      // must not read as "fine".
      expect(
        isGpsSilent(
            now: DateTime.utc(2026, 8, 30, 10, 0, 30),
            lastFixAt: null,
            recordingSince: since),
        isFalse,
      );
      expect(
        isGpsSilent(
            now: DateTime.utc(2026, 8, 30, 10, 2),
            lastFixAt: null,
            recordingSince: since),
        isTrue,
      );
    });

    test('a fix arriving after a silent spell clears it', () {
      expect(
        isGpsSilent(
            now: DateTime.utc(2026, 8, 30, 10, 10),
            lastFixAt: DateTime.utc(2026, 8, 30, 10, 9, 59),
            recordingSince: since),
        isFalse,
      );
    });

    test('the threshold is the documented one minute', () {
      expect(kGpsSilenceThreshold, const Duration(seconds: 60));
    });
  });

  group('resumePoint', () {
    test('a restarted service picks up the persisted progress, not the seed',
        () {
      // Android restarted the service mid-trip (allowAutoRestart): resuming
      // from the seed would reset 2.4 km to 0.
      final resumed = resumePoint(snapshot(distanceKm: 2.4),
          snapshot(distanceKm: 0, steps: 0, elapsedMinutes: 0));
      expect(resumed!.distanceKm, closeTo(2.4, 1e-9));
      expect(resumed.steps, 3100);
    });

    test('a first start with nothing on disk uses the seed', () {
      final seed = snapshot(distanceKm: 0, steps: 0);
      expect(resumePoint(null, seed), same(seed));
    });

    test('a finished trip left on disk does not resurrect itself', () {
      final seed = snapshot(distanceKm: 0, steps: 0);
      expect(resumePoint(snapshot(status: TripStatus.idle), seed), same(seed));
    });

    test('nothing to resume from at all yields nothing', () {
      expect(resumePoint(null, null), isNull);
    });
  });

  group('withoutNavigation', () {
    TripSnapshot navigating() => snapshot().copyWith(
          nav: const NavFields(
            instruction: 'Tournez à gauche sur la rue de Bourg',
            distanceToManeuverM: 120,
            remainingKm: 2.4,
            etaSeconds: 1920,
            offRoute: true,
            arrived: true,
            replanCount: 3,
            routeShapeEnc: '_izlhA~rlgdF',
          ),
        );

    test('a restarting incarnation keeps the distance and drops the guidance',
        () {
      // The failure this exists for: with no nav seed to read (blank or
      // corrupt), the new incarnation builds no follower, so nothing would
      // ever overwrite these — the UI would show the dead incarnation's
      // instruction, and its route line, for the rest of the trip.
      final fresh = withoutNavigation(navigating());

      expect(fresh.distanceKm, closeTo(2.4, 1e-9));
      expect(fresh.steps, 3100);
      expect(fresh.navInstruction, isNull);
      expect(fresh.navDistanceToManeuverM, isNull);
      expect(fresh.navRemainingKm, isNull);
      expect(fresh.navEtaSeconds, isNull);
      expect(fresh.navRouteShapeEnc, isNull);
      expect(fresh.navOffRoute, isFalse);
      expect(fresh.navArrived, isFalse);
      expect(fresh.navReplanCount, 0);
    });

    test('a snapshot that was never navigating comes back unchanged', () {
      final free = withoutNavigation(snapshot());
      expect(free.navInstruction, isNull);
      expect(free.distanceKm, closeTo(2.4, 1e-9));
      expect(free.updatedAt, snapshot().updatedAt);
    });
  });

  group('TripTaskHandler.onStart — TTS binding (item 1 regression)', () {
    late Directory tempDir;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rw_tts_onstart_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
      TripTaskHandler.speakerFactory = NativeTtsSpeaker.new;
    });

    Future<void> seedPrefs({
      required bool routeBound,
      NavSeed? navSeed,
    }) async {
      final seed = TripSnapshot.starting(
        startedAt: DateTime.utc(2026, 8, 31, 9),
        profile: RoutingProfile.walk,
        routeBound: routeBound,
      );
      SharedPreferences.setMockInitialValues({
        '$_prefsPrefix' 'randomwalk_seed_snapshot': jsonEncode(seed.toJson()),
        '$_prefsPrefix' 'randomwalk_snapshot_path':
            '${tempDir.path}/snapshot.json',
        '$_prefsPrefix' 'randomwalk_tts_enabled': true,
        '$_prefsPrefix' 'randomwalk_haptics_enabled': true,
        if (navSeed != null)
          '$_prefsPrefix' 'randomwalk_nav_seed': jsonEncode(navSeed.toJson()),
      });
    }

    test('a free session never constructs a speaker at all', () async {
      var constructed = 0;
      TripTaskHandler.speakerFactory = () {
        constructed++;
        return FakeInitializableTtsSpeaker();
      };
      await seedPrefs(routeBound: false);

      final handler = TripTaskHandler();
      await handler.onStart(
          DateTime.utc(2026, 8, 31, 9), TaskStarter.developer);

      expect(constructed, 0);
      expect(handler.debugIsRecording, isTrue);
    });

    test(
        'a hung speaker init on a route-bound trip never blocks the GPS '
        'subscription from starting',
        () async {
      TripTaskHandler.speakerFactory = () =>
          FakeInitializableTtsSpeaker(hang: true);
      final route = fakeRoute();
      await seedPrefs(
        routeBound: true,
        navSeed: NavSeed(
          route: route,
          destLat: route.shape.last.$1,
          destLon: route.shape.last.$2,
          profile: RoutingProfile.walk,
          tileDirPath: null,
        ),
      );

      final handler = TripTaskHandler();
      // Before the fix, `await _initSpeaker()` ran ahead of
      // `session.start()` and a hung `init()` (the native-side defect item
      // 1 also fixes) would wedge this forever. Bounding it here turns a
      // regression into a failing test instead of a hung test run.
      await handler
          .onStart(DateTime.utc(2026, 8, 31, 9), TaskStarter.developer)
          .timeout(const Duration(seconds: 5));

      expect(handler.debugIsRecording, isTrue);
    });
  });
}
