import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:randomwalk/exploration/track_sampler.dart' show kTrackMaxPoints;
import 'package:randomwalk/nav/nav_fields.dart';
import 'package:randomwalk/nav/tts.dart';
import 'package:randomwalk/session/recorder.dart' show GpsSample;
import 'package:randomwalk/session/session_controller.dart';
import 'package:randomwalk/tracking/adaptive_gps.dart';
import 'package:randomwalk/tracking/motion_channel.dart';
import 'package:randomwalk/tracking/nav_seed.dart';
import 'package:randomwalk/tracking/steps.dart';
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
}) => TripSnapshot(
  status: status,
  distanceKm: distanceKm,
  steps: steps,
  startedAt: DateTime.utc(2026, 8, 30, 10, 0),
  updatedAt: DateTime.utc(
    2026,
    8,
    30,
    10,
    0,
  ).add(Duration(minutes: elapsedMinutes)),
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
        tripNotificationText(
          snapshot(distanceKm: 0),
          DateTime.utc(2026, 8, 30, 10, 0),
        ),
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
          recordingSince: since,
        ),
        isFalse,
      );
    });

    test('a minute without a single fix is silence', () {
      expect(
        isGpsSilent(
          now: DateTime.utc(2026, 8, 30, 10, 5),
          lastFixAt: DateTime.utc(2026, 8, 30, 10, 3, 30),
          recordingSince: since,
        ),
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
          recordingSince: since,
        ),
        isFalse,
      );
      expect(
        isGpsSilent(
          now: DateTime.utc(2026, 8, 30, 10, 2),
          lastFixAt: null,
          recordingSince: since,
        ),
        isTrue,
      );
    });

    test('a fix arriving after a silent spell clears it', () {
      expect(
        isGpsSilent(
          now: DateTime.utc(2026, 8, 30, 10, 10),
          lastFixAt: DateTime.utc(2026, 8, 30, 10, 9, 59),
          recordingSince: since,
        ),
        isFalse,
      );
    });

    test('the threshold is the documented one minute', () {
      expect(kGpsSilenceThreshold, const Duration(seconds: 60));
    });

    test('fix round 2 (I2): a recordingSince reset AFTER the last fix grants '
        'a fresh grace window instead of being ignored', () {
      // The bug: `lastFixAt ?? recordingSince` never falls back to
      // recordingSince once a single fix has ever arrived, so resetting
      // recordingSince on resume (the round-1 fix) had no effect on a
      // real trip — lastFixAt, potentially minutes stale, always won.
      final lastFixAt = DateTime.utc(2026, 8, 31, 9, 0);
      final resumedAt = DateTime.utc(2026, 8, 31, 9, 5); // well after
      expect(
        isGpsSilent(
          now: resumedAt.add(const Duration(seconds: 30)),
          lastFixAt: lastFixAt,
          recordingSince: resumedAt,
        ),
        isFalse,
        reason:
            'the fresh recordingSince must be the anchor, not the '
            'stale (5 min old) lastFixAt',
      );

      // But it is a WINDOW, not a permanent exemption: once the
      // threshold elapses past the resume moment itself with still no
      // fresh fix, silence must surface again.
      expect(
        isGpsSilent(
          now: resumedAt.add(const Duration(seconds: 61)),
          lastFixAt: lastFixAt,
          recordingSince: resumedAt,
        ),
        isTrue,
      );

      // And a lastFixAt genuinely AFTER recordingSince (the ordinary,
      // non-resume case) is unaffected — same as before this fix.
      expect(
        isGpsSilent(
          now: lastFixAt.add(const Duration(seconds: 30)),
          lastFixAt: lastFixAt,
          recordingSince: resumedAt.subtract(const Duration(minutes: 10)),
        ),
        isFalse,
      );
    });
  });

  group('gpsSilenceThresholdFor (item 3 regression)', () {
    test('at the close 3 m filter, the threshold is the base one minute', () {
      expect(
        gpsSilenceThresholdFor(kNavCloseDistanceFilterM),
        const Duration(seconds: 60),
      );
    });

    test('at the far 12 m filter, the threshold scales to keep the same '
        'floor speed as the close filter (0.18 km/h)', () {
      final threshold = gpsSilenceThresholdFor(kNavFarDistanceFilterM);
      expect(threshold, const Duration(minutes: 4));

      // 0.18 km/h at both filters — the false-positive this exists for
      // (12 m / 60 s = 0.72 km/h) never appears if this ratio holds.
      final closeFloorKmh =
          kNavCloseDistanceFilterM / kGpsSilenceThreshold.inSeconds * 3.6;
      final farFloorKmh = kNavFarDistanceFilterM / threshold.inSeconds * 3.6;
      expect(farFloorKmh, closeTo(closeFloorKmh, 1e-9));
    });

    test('never returns less than the documented base threshold', () {
      // Filters below the close filter are not expected in practice, but
      // the scaling must be a floor, never a tightening.
      expect(
        gpsSilenceThresholdFor(1).inSeconds,
        greaterThanOrEqualTo(kGpsSilenceThreshold.inSeconds),
      );
    });

    test('a walker slower than the close-filter floor still reads as '
        'silent at the far filter — this is not a "never fires" escape '
        'hatch', () {
      final since = DateTime.utc(2026, 8, 30, 10, 0);
      final threshold = gpsSilenceThresholdFor(kNavFarDistanceFilterM);
      expect(
        isGpsSilent(
          now: since.add(threshold + const Duration(seconds: 1)),
          lastFixAt: null,
          recordingSince: since,
          threshold: threshold,
        ),
        isTrue,
      );
    });
  });

  group('resumePoint', () {
    test(
      'a restarted service picks up the persisted progress, not the seed',
      () {
        // Android restarted the service mid-trip (allowAutoRestart): resuming
        // from the seed would reset 2.4 km to 0.
        final resumed = resumePoint(
          snapshot(distanceKm: 2.4),
          snapshot(distanceKm: 0, steps: 0, elapsedMinutes: 0),
        );
        expect(resumed!.distanceKm, closeTo(2.4, 1e-9));
        expect(resumed.steps, 3100);
      },
    );

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
        replanning: true,
      ),
    );

    test(
      'a restarting incarnation keeps the distance and drops the guidance',
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
        expect(fresh.navReplanning, isFalse);
      },
    );

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

    Future<void> seedPrefs({required bool routeBound, NavSeed? navSeed}) async {
      final seed = TripSnapshot.starting(
        startedAt: DateTime.utc(2026, 8, 31, 9),
        profile: RoutingProfile.walk,
        routeBound: routeBound,
      );
      SharedPreferences.setMockInitialValues({
        '$_prefsPrefix'
            'randomwalk_seed_snapshot': jsonEncode(
          seed.toJson(),
        ),
        '$_prefsPrefix'
                'randomwalk_snapshot_path':
            '${tempDir.path}/snapshot.json',
        '$_prefsPrefix'
                'randomwalk_tts_enabled':
            true,
        '$_prefsPrefix'
                'randomwalk_haptics_enabled':
            true,
        if (navSeed != null)
          '$_prefsPrefix'
              'randomwalk_nav_seed': jsonEncode(
            navSeed.toJson(),
          ),
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
        DateTime.utc(2026, 8, 31, 9),
        TaskStarter.developer,
      );

      expect(constructed, 0);
      expect(handler.debugIsRecording, isTrue);
    });

    test('a hung speaker init on a route-bound trip never blocks the GPS '
        'subscription from starting', () async {
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

  group('TripTaskHandler.onStart — arrival latch survives a restart '
      '(final review item 2)', () {
    late Directory tempDir;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rw_arrival_restart');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    /// Seeds a genuine restart: an on-disk snapshot already `recording`,
    /// `routeBound`, with `updatedAt` past `startedAt` (so `resumePoint`
    /// treats it as a restart, not a fresh seed — see `isFreshTripSeed`),
    /// carrying [navLeftArrivalRadius] the way a previous incarnation would
    /// have persisted it. `SharedPreferences`' own seed is a plain
    /// `TripSnapshot.starting` (what the UI always writes before starting
    /// the service) — `onStart` must read the resumed value from the ON
    /// DISK snapshot, not from that prefs seed.
    Future<String> seedRestart({required bool navLeftArrivalRadius}) async {
      final snapshotPath = '${tempDir.path}/snapshot.json';
      final route = fakeRoute();
      final onDisk = TripSnapshot(
        status: TripStatus.recording,
        distanceKm: 1.0,
        steps: 1500,
        startedAt: DateTime.utc(2026, 8, 31, 9),
        updatedAt: DateTime.utc(2026, 8, 31, 9, 20),
        profile: RoutingProfile.walk,
        routeBound: true,
      ).copyWith(nav: NavFields(leftArrivalRadius: navLeftArrivalRadius));
      await File(snapshotPath).writeAsString(jsonEncode(onDisk.toJson()));

      final seed = TripSnapshot.starting(
        startedAt: DateTime.utc(2026, 8, 31, 9),
        profile: RoutingProfile.walk,
        routeBound: true,
      );
      SharedPreferences.setMockInitialValues({
        '$_prefsPrefix'
            'randomwalk_seed_snapshot': jsonEncode(
          seed.toJson(),
        ),
        '$_prefsPrefix'
                'randomwalk_snapshot_path':
            snapshotPath,
        '$_prefsPrefix'
                'randomwalk_tts_enabled':
            true,
        '$_prefsPrefix'
                'randomwalk_haptics_enabled':
            true,
        '$_prefsPrefix'
            'randomwalk_nav_seed': jsonEncode(
          NavSeed(
            route: route,
            destLat: route.shape.last.$1,
            destLon: route.shape.last.$2,
            profile: RoutingProfile.walk,
            tileDirPath: null,
          ).toJson(),
        ),
      });
      return snapshotPath;
    }

    /// Polls the on-disk snapshot for [navArrived] to flip true — the
    /// publish after a nav fix is fire-and-forget (`_publish` does not
    /// await `_writer.submit`), same pattern the pendingVisits tests above
    /// use.
    Future<TripSnapshot?> pollUntilArrived(String snapshotPath) async {
      TripSnapshot? persisted;
      for (var i = 0; i < 20 && persisted?.navArrived != true; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        persisted = await FileTripSnapshotStore(File(snapshotPath)).read();
      }
      return persisted;
    }

    test('a restarted service already near the destination, latch seeded '
        'true from the resumed snapshot, arrives on the first fix', () async {
      final snapshotPath = await seedRestart(navLeftArrivalRadius: true);
      final route = fakeRoute();
      final handler = TripTaskHandler();
      await handler.onStart(
        DateTime.utc(2026, 8, 31, 9, 20),
        TaskStarter.developer,
      );

      final end = route.shape.last;
      await handler.debugOnFix(
        GpsSample(
          lat: end.$1,
          lon: end.$2,
          accuracyM: 5,
          speedMps: 0.5,
          time: DateTime.utc(2026, 8, 31, 9, 20, 5),
        ),
      );

      final persisted = await pollUntilArrived(snapshotPath);
      expect(persisted?.navArrived, isTrue);
    });

    test('a fresh (non-restart) trip seed still cannot false-arrive at km 0 '
        '— navLeftArrivalRadius defaults to false', () async {
      final snapshotPath = '${tempDir.path}/snapshot.json';
      final route = fakeRoute();
      final seed = TripSnapshot.starting(
        startedAt: DateTime.utc(2026, 8, 31, 9),
        profile: RoutingProfile.walk,
        routeBound: true,
      );
      SharedPreferences.setMockInitialValues({
        '$_prefsPrefix'
            'randomwalk_seed_snapshot': jsonEncode(
          seed.toJson(),
        ),
        '$_prefsPrefix'
                'randomwalk_snapshot_path':
            snapshotPath,
        '$_prefsPrefix'
                'randomwalk_tts_enabled':
            true,
        '$_prefsPrefix'
                'randomwalk_haptics_enabled':
            true,
        '$_prefsPrefix'
            'randomwalk_nav_seed': jsonEncode(
          NavSeed(
            route: route,
            destLat: route.shape.last.$1,
            destLon: route.shape.last.$2,
            profile: RoutingProfile.walk,
            tileDirPath: null,
          ).toJson(),
        ),
      });

      final handler = TripTaskHandler();
      await handler.onStart(
        DateTime.utc(2026, 8, 31, 9),
        TaskStarter.developer,
      );

      // First-ever fix, right at the start (== near the destination for
      // a route whose start and end happen to be close together is not
      // this fixture, but the point stands generically): must not arrive
      // on a fresh, unseeded follower.
      final start = route.shape.first;
      await handler.debugOnFix(
        GpsSample(
          lat: start.$1,
          lon: start.$2,
          accuracyM: 5,
          speedMps: 0.5,
          time: DateTime.utc(2026, 8, 31, 9, 0, 1),
        ),
      );

      TripSnapshot? persisted;
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        persisted = await FileTripSnapshotStore(File(snapshotPath)).read();
        if (persisted != null) break;
      }
      expect(persisted?.navArrived, isNot(isTrue));
    });
  });

  group('TripTaskHandler — Task 2g auto-finish at arrival', () {
    late Directory tempDir;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rw_auto_finish_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
      // Restore the real (unmocked) call — see `stopServiceCall`'s own doc
      // comment for why this is a swappable static field at all.
      TripTaskHandler.stopServiceCall = () async {
        await FlutterForegroundTask.stopService();
      };
    });

    /// Seeds a genuine restart already near the destination with the
    /// arrival latch pre-armed (`navLeftArrivalRadius: true`) — same shape
    /// the "arrival latch survives a restart" group above uses — so a
    /// single fix right at the route's end latches arrival immediately.
    Future<String> seedArrivingTrip() async {
      final snapshotPath = '${tempDir.path}/snapshot.json';
      final route = fakeRoute();
      final onDisk = TripSnapshot(
        status: TripStatus.recording,
        distanceKm: 1.0,
        steps: 1500,
        startedAt: DateTime.utc(2026, 8, 31, 9),
        updatedAt: DateTime.utc(2026, 8, 31, 9, 20),
        profile: RoutingProfile.walk,
        routeBound: true,
      ).copyWith(nav: const NavFields(leftArrivalRadius: true));
      await File(snapshotPath).writeAsString(jsonEncode(onDisk.toJson()));

      final seed = TripSnapshot.starting(
        startedAt: DateTime.utc(2026, 8, 31, 9),
        profile: RoutingProfile.walk,
        routeBound: true,
      );
      SharedPreferences.setMockInitialValues({
        '$_prefsPrefix'
            'randomwalk_seed_snapshot': jsonEncode(
          seed.toJson(),
        ),
        '$_prefsPrefix'
                'randomwalk_snapshot_path':
            snapshotPath,
        '$_prefsPrefix'
                'randomwalk_tts_enabled':
            true,
        '$_prefsPrefix'
                'randomwalk_haptics_enabled':
            true,
        '$_prefsPrefix'
            'randomwalk_nav_seed': jsonEncode(
          NavSeed(
            route: route,
            destLat: route.shape.last.$1,
            destLon: route.shape.last.$2,
            profile: RoutingProfile.walk,
            tileDirPath: null,
          ).toJson(),
        ),
      });
      return snapshotPath;
    }

    Future<TripSnapshot?> pollUntilIdle(String snapshotPath) async {
      TripSnapshot? persisted;
      for (var i = 0; i < 25 && persisted?.isRecording != false; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        persisted = await FileTripSnapshotStore(File(snapshotPath)).read();
      }
      return persisted;
    }

    test(
      'a guided trip that latches arrival stops itself exactly once, '
      'with a final status:idle snapshot the UI can reconcile through',
      () async {
        var stopCalls = 0;
        TripTaskHandler.stopServiceCall = () async => stopCalls++;

        final snapshotPath = await seedArrivingTrip();
        final route = fakeRoute();
        final handler = TripTaskHandler();
        await handler.onStart(
          DateTime.utc(2026, 8, 31, 9, 20),
          TaskStarter.developer,
        );

        final end = route.shape.last;
        await handler.debugOnFix(
          GpsSample(
            lat: end.$1,
            lon: end.$2,
            accuracyM: 5,
            speedMps: 0.5,
            time: DateTime.utc(2026, 8, 31, 9, 20, 5),
          ),
        );

        final persisted = await pollUntilIdle(snapshotPath);
        expect(persisted?.isRecording, isFalse);
        expect(persisted?.navArrived, isTrue);
        expect(persisted?.routeBound, isTrue);

        // stopServiceCall() runs AFTER the final snapshot write (see
        // `_autoFinishOnArrival`'s own doc comment on that ordering) — poll
        // for it separately rather than assuming it has already landed the
        // instant the snapshot itself does.
        for (var i = 0; i < 25 && stopCalls == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(stopCalls, 1);

        // A second fix at the same spot — Android's teardown is asynchronous
        // and does not necessarily happen before the very next fix arrives —
        // must not queue a second stop attempt.
        await handler.debugOnFix(
          GpsSample(
            lat: end.$1,
            lon: end.$2,
            accuracyM: 5,
            speedMps: 0.5,
            time: DateTime.utc(2026, 8, 31, 9, 20, 7),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(stopCalls, 1);
      },
    );

    test('a free (unguided) trip never auto-finishes, no matter how many '
        'fixes it sees', () async {
      var stopCalls = 0;
      TripTaskHandler.stopServiceCall = () async => stopCalls++;

      final snapshotPath = '${tempDir.path}/snapshot_free.json';
      final seed = TripSnapshot.starting(
        startedAt: DateTime.utc(2026, 8, 31, 9),
        profile: RoutingProfile.walk,
        routeBound: false,
      );
      SharedPreferences.setMockInitialValues({
        '$_prefsPrefix'
            'randomwalk_seed_snapshot': jsonEncode(
          seed.toJson(),
        ),
        '$_prefsPrefix'
                'randomwalk_snapshot_path':
            snapshotPath,
        '$_prefsPrefix'
                'randomwalk_tts_enabled':
            true,
        '$_prefsPrefix'
                'randomwalk_haptics_enabled':
            true,
        // No nav seed at all — a free trip never builds a follower.
      });

      final handler = TripTaskHandler();
      await handler.onStart(
        DateTime.utc(2026, 8, 31, 9),
        TaskStarter.developer,
      );

      for (var i = 0; i < 5; i++) {
        await handler.debugOnFix(
          GpsSample(
            lat: 46.5 + i * 0.001,
            lon: 6.6,
            accuracyM: 5,
            speedMps: 1.0,
            time: DateTime.utc(2026, 8, 31, 9, 0, i),
          ),
        );
      }
      // A free trip never touches `_publish` via `_onNavFix` at all (no
      // `_nav` to guide) — the periodic tick is what actually persists a
      // snapshot in production; drive it once so there is something on
      // disk to assert `isRecording` against.
      handler.onRepeatEvent(DateTime.utc(2026, 8, 31, 9, 0, 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(stopCalls, 0);
      final persisted = await FileTripSnapshotStore(File(snapshotPath)).read();
      expect(persisted?.isRecording, isTrue);
    });
  });

  group('TripTaskHandler.onStart — M4 track sampling', () {
    late Directory tempDir;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rw_track_onstart_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    Future<void> seedPrefs(String snapshotPath) async {
      final seed = TripSnapshot.starting(
        startedAt: DateTime.utc(2026, 8, 31, 9),
        profile: RoutingProfile.walk,
        routeBound: false,
      );
      SharedPreferences.setMockInitialValues({
        '$_prefsPrefix'
            'randomwalk_seed_snapshot': jsonEncode(
          seed.toJson(),
        ),
        '$_prefsPrefix'
                'randomwalk_snapshot_path':
            snapshotPath,
        '$_prefsPrefix'
                'randomwalk_tts_enabled':
            true,
        '$_prefsPrefix'
                'randomwalk_haptics_enabled':
            true,
      });
    }

    test('a fresh (non-restart) start discards a leftover track file left '
        'by an earlier, already-finalised trip', () async {
      final snapshotPath = '${tempDir.path}/snapshot.json';
      final trackPath = '${tempDir.path}/active_track.jsonl';
      await File(
        trackPath,
      ).writeAsString('${jsonEncode({'lat': 1.0, 'lon': 2.0})}\n');
      await seedPrefs(snapshotPath); // no on-disk snapshot -> not a restart.

      final handler = TripTaskHandler();
      await handler.onStart(
        DateTime.utc(2026, 8, 31, 9),
        TaskStarter.developer,
      );

      expect(await File(trackPath).exists(), isFalse);
    });

    test('a genuine restart (an already-recording on-disk snapshot) keeps '
        'the existing track file\'s content rather than wiping it', () async {
      final snapshotPath = '${tempDir.path}/snapshot.json';
      final trackPath = '${tempDir.path}/active_track.jsonl';
      final onDiskSnapshot = TripSnapshot(
        status: TripStatus.recording,
        distanceKm: 1.0,
        steps: 10,
        startedAt: DateTime.utc(2026, 8, 31, 9),
        updatedAt: DateTime.utc(2026, 8, 31, 9, 5),
        profile: RoutingProfile.walk,
        routeBound: false,
      );
      await File(
        snapshotPath,
      ).writeAsString(jsonEncode(onDiskSnapshot.toJson()));
      final trackLine = '${jsonEncode({'lat': 46.5, 'lon': 6.6})}\n';
      await File(trackPath).writeAsString(trackLine);
      await seedPrefs(snapshotPath);

      final handler = TripTaskHandler();
      await handler.onStart(
        DateTime.utc(2026, 8, 31, 9, 10),
        TaskStarter.developer,
      );

      expect(await File(trackPath).readAsString(), trackLine);
    });

    test('no leftover track file at all is not an error — onStart still '
        'reaches recording', () async {
      final snapshotPath = '${tempDir.path}/snapshot.json';
      await seedPrefs(snapshotPath);
      final handler = TripTaskHandler();
      await handler.onStart(
        DateTime.utc(2026, 8, 31, 9),
        TaskStarter.developer,
      );
      expect(handler.debugIsRecording, isTrue);
    });

    test('a freshly-seeded on-disk snapshot (updatedAt == startedAt) is NOT '
        'treated as a restart even though its status is recording — fix '
        'round 1 finding 1: isRecording alone was the whole bug', () async {
      final snapshotPath = '${tempDir.path}/snapshot.json';
      final trackPath = '${tempDir.path}/active_track.jsonl';
      // Mirrors exactly what ForegroundServiceTripTracker.start() itself
      // writes to disk for a brand-new trip, before it ever calls
      // startService — see that method's own doc comment. Before fix round
      // 1, `persisted.isRecording` alone made this indistinguishable from a
      // genuine restart, and the leftover track below would have survived.
      final freshOnDisk = TripSnapshot.starting(
        startedAt: DateTime.utc(2026, 8, 31, 9),
        profile: RoutingProfile.walk,
        routeBound: false,
      );
      await File(snapshotPath).writeAsString(jsonEncode(freshOnDisk.toJson()));
      await File(
        trackPath,
      ).writeAsString('${jsonEncode({'lat': 1.0, 'lon': 2.0})}\n');
      await seedPrefs(snapshotPath);

      final handler = TripTaskHandler();
      await handler.onStart(
        DateTime.utc(2026, 8, 31, 9),
        TaskStarter.developer,
      );

      expect(await File(trackPath).exists(), isFalse);
    });

    test('the on-disk track stays bounded at kTrackMaxPoints even after far '
        'more fixes than that, kept in sync via the thinned-rewrite — fix '
        'round 1 finding 2', () async {
      final snapshotPath = '${tempDir.path}/snapshot.json';
      final trackPath = '${tempDir.path}/active_track.jsonl';
      await seedPrefs(snapshotPath);
      final handler = TripTaskHandler();
      await handler.onStart(
        DateTime.utc(2026, 8, 31, 9),
        TaskStarter.developer,
      );

      // Each step is ~33 m north — comfortably over the 25 m distance
      // filter default, so every fix is kept by TrackSampler.
      var lat = 46.5;
      for (var i = 0; i < kTrackMaxPoints + 500; i++) {
        lat += 0.0003;
        await handler.debugOnFix(
          GpsSample(
            lat: lat,
            lon: 6.63,
            accuracyM: 5,
            speedMps: 1.2,
            time: DateTime.utc(2026, 8, 31, 9, 0, 0, i),
          ),
        );
      }

      final lines = await File(trackPath).readAsLines();
      expect(lines.length, lessThanOrEqualTo(kTrackMaxPoints));
      // Not merely bounded — genuinely still recording new ground, not
      // stuck at some tiny prefix.
      expect(lines.length, greaterThan(kTrackMaxPoints ~/ 2));
    });
  });

  group('isFreshTripSeed (fix round 1 finding 1)', () {
    test('a brand-new TripSnapshot.starting is fresh', () {
      final seed = TripSnapshot.starting(
        startedAt: DateTime.utc(2026, 8, 31, 9),
        profile: RoutingProfile.walk,
        routeBound: false,
      );
      expect(isFreshTripSeed(seed), isTrue);
    });

    test('a snapshot whose updatedAt has moved past startedAt (a real '
        'restart, or a resume) is not fresh', () {
      final seed = TripSnapshot(
        status: TripStatus.recording,
        distanceKm: 1.0,
        steps: 10,
        startedAt: DateTime.utc(2026, 8, 31, 9),
        updatedAt: DateTime.utc(2026, 8, 31, 9, 5),
        profile: RoutingProfile.walk,
        routeBound: false,
      );
      expect(isFreshTripSeed(seed), isFalse);
    });

    test('a resumeInterrupted-style seed (same startedAt, freshly-stamped '
        'updatedAt) is not fresh', () {
      final original = TripSnapshot.starting(
        startedAt: DateTime.utc(2026, 8, 31, 9),
        profile: RoutingProfile.walk,
        routeBound: false,
        distanceKm: 2.4,
      );
      // Mirrors TripController.resumeInterrupted's own
      // `copyWith(status: recording, updatedAt: _clock(), ...)`.
      final resumedSeed = original.copyWith(
        status: TripStatus.recording,
        updatedAt: DateTime.utc(2026, 8, 31, 9, 20),
      );
      expect(isFreshTripSeed(resumedSeed), isFalse);
    });
  });

  group('TripTaskHandler — M4 Task 5 landmark visit detection', () {
    late Directory tempDir;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rw_visits_onstart_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    const churchLat = 46.5200, churchLon = 6.6300;
    const bankLat = 46.5210, bankLon = 6.6310;

    Future<String> writePoisFixture(List<Map<String, Object?>> pois) async {
      final path = '${tempDir.path}/pois.json.gz';
      final bytes = utf8.encode(jsonEncode(pois));
      await File(path).writeAsBytes(gzip.encode(bytes));
      return path;
    }

    Future<TripTaskHandler> startedHandler({
      required String snapshotPath,
      String? poisFilePath,
    }) async {
      final seed = TripSnapshot.starting(
        startedAt: DateTime.utc(2026, 8, 31, 9),
        profile: RoutingProfile.walk,
        routeBound: false,
      );
      SharedPreferences.setMockInitialValues({
        '$_prefsPrefix'
            'randomwalk_seed_snapshot': jsonEncode(
          seed.toJson(),
        ),
        '$_prefsPrefix'
                'randomwalk_snapshot_path':
            snapshotPath,
        '$_prefsPrefix'
                'randomwalk_tts_enabled':
            true,
        '$_prefsPrefix'
                'randomwalk_haptics_enabled':
            true,
        if (poisFilePath != null)
          '$_prefsPrefix'
                  'randomwalk_pois_file_path':
              poisFilePath,
      });
      final handler = TripTaskHandler();
      await handler.onStart(
        DateTime.utc(2026, 8, 31, 9),
        TaskStarter.developer,
      );
      await handler.debugPoiStoreLoad;
      return handler;
    }

    test(
      'no poisFilePath at all: recording still works, no visits ever',
      () async {
        final snapshotPath = '${tempDir.path}/snapshot.json';
        final handler = await startedHandler(
          snapshotPath: snapshotPath,
          poisFilePath: null,
        );
        expect(handler.debugIsRecording, isTrue);

        await handler.debugOnFix(
          GpsSample(
            lat: churchLat,
            lon: churchLon,
            accuracyM: 5,
            speedMps: 1.2,
            time: DateTime.utc(2026, 8, 31, 9, 0, 10),
          ),
        );

        expect(handler.debugPendingVisits, isEmpty);
      },
    );

    test('a dwell of >=5s within 25m of a landmark publishes it via '
        'pendingVisits on the snapshot', () async {
      final snapshotPath = '${tempDir.path}/snapshot.json';
      final poisPath = await writePoisFixture([
        {
          'id': 'node/1',
          'kind': 'reveal',
          'lat': churchLat,
          'lon': churchLon,
          'name': 'Église Saint-Pierre',
        },
      ]);
      final handler = await startedHandler(
        snapshotPath: snapshotPath,
        poisFilePath: poisPath,
      );

      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      await handler.debugOnFix(
        GpsSample(
          lat: churchLat,
          lon: churchLon,
          accuracyM: 5,
          speedMps: 0,
          time: t0,
        ),
      );
      await handler.debugOnFix(
        GpsSample(
          lat: churchLat,
          lon: churchLon,
          accuracyM: 5,
          speedMps: 0,
          time: t0.add(const Duration(seconds: 5)),
        ),
      );

      expect(handler.debugPendingVisits, hasLength(1));
      final visit = handler.debugPendingVisits.single;
      expect(visit.poiId, 'node/1');
      expect(visit.kind, 'reveal');
      expect(visit.name, 'Église Saint-Pierre');
      expect(visit.lat, churchLat);
      expect(visit.lon, churchLon);
      expect(visit.ts, t0.add(const Duration(seconds: 5)));

      // The publish path (`_snapshotAt`/`_publish`, driven here by a repeat
      // event exactly like the periodic tick would) surfaces the same visit
      // on the persisted snapshot — not just on the debug accessor above.
      handler.onRepeatEvent(t0.add(const Duration(seconds: 6)));
      TripSnapshot? persisted;
      for (
        var i = 0;
        i < 20 && persisted?.pendingVisits.isEmpty != false;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        persisted = await FileTripSnapshotStore(File(snapshotPath)).read();
      }
      expect(persisted?.pendingVisits, hasLength(1));
      expect(persisted!.pendingVisits.single.poiId, 'node/1');
    });

    test(
      'a landmark far outside the 3km disc is never even a candidate',
      () async {
        final snapshotPath = '${tempDir.path}/snapshot.json';
        final poisPath = await writePoisFixture([
          {
            // Comfortably beyond a 3km disc around the church.
            'id': 'node/far',
            'kind': 'reveal',
            'lat': churchLat + 1.0,
            'lon': churchLon,
          },
        ]);
        final handler = await startedHandler(
          snapshotPath: snapshotPath,
          poisFilePath: poisPath,
        );

        final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
        await handler.debugOnFix(
          GpsSample(
            lat: churchLat,
            lon: churchLon,
            accuracyM: 5,
            speedMps: 0,
            time: t0,
          ),
        );
        await handler.debugOnFix(
          GpsSample(
            lat: churchLat,
            lon: churchLon,
            accuracyM: 5,
            speedMps: 0,
            time: t0.add(const Duration(seconds: 30)),
          ),
        );

        expect(handler.debugPendingVisits, isEmpty);
      },
    );

    test(
      'pendingVisits is capped at kPendingVisitsMax, oldest dropped first',
      () async {
        final snapshotPath = '${tempDir.path}/snapshot.json';
        // kPendingVisitsMax + 3 distinct landmarks, each far enough apart
        // (~15m spacing north) to have its own geofence, all within the same
        // initial 3km disc around the church.
        final pois = [
          for (var i = 0; i < kPendingVisitsMax + 3; i++)
            {
              'id': 'node/$i',
              'kind': 'reveal',
              'lat': churchLat + i * 0.0003,
              'lon': churchLon,
            },
        ];
        final poisPath = await writePoisFixture(pois);
        final handler = await startedHandler(
          snapshotPath: snapshotPath,
          poisFilePath: poisPath,
        );

        var t = DateTime.utc(2026, 8, 31, 9, 0, 0);
        for (var i = 0; i < pois.length; i++) {
          final lat = churchLat + i * 0.0003;
          await handler.debugOnFix(
            GpsSample(
              lat: lat,
              lon: churchLon,
              accuracyM: 5,
              speedMps: 0,
              time: t,
            ),
          );
          t = t.add(const Duration(seconds: 5));
          await handler.debugOnFix(
            GpsSample(
              lat: lat,
              lon: churchLon,
              accuracyM: 5,
              speedMps: 0,
              time: t,
            ),
          );
          t = t.add(const Duration(seconds: 1));
        }

        expect(handler.debugPendingVisits, hasLength(kPendingVisitsMax));
        // The oldest (node/0) must have been dropped; the newest survives.
        final ids = handler.debugPendingVisits.map((v) => v.poiId).toList();
        expect(ids, isNot(contains('node/0')));
        expect(ids.last, 'node/${pois.length - 1}');
      },
    );

    test(
      'a landmark already visited via debugOnFix is never detected twice',
      () async {
        final snapshotPath = '${tempDir.path}/snapshot.json';
        final poisPath = await writePoisFixture([
          {'id': 'node/1', 'kind': 'coins', 'lat': bankLat, 'lon': bankLon},
        ]);
        final handler = await startedHandler(
          snapshotPath: snapshotPath,
          poisFilePath: poisPath,
        );

        var t = DateTime.utc(2026, 8, 31, 9, 0, 0);
        await handler.debugOnFix(
          GpsSample(
            lat: bankLat,
            lon: bankLon,
            accuracyM: 5,
            speedMps: 0,
            time: t,
          ),
        );
        t = t.add(const Duration(seconds: 5));
        await handler.debugOnFix(
          GpsSample(
            lat: bankLat,
            lon: bankLon,
            accuracyM: 5,
            speedMps: 0,
            time: t,
          ),
        );
        // Keep dwelling at the same spot for a long time afterwards.
        t = t.add(const Duration(minutes: 5));
        await handler.debugOnFix(
          GpsSample(
            lat: bankLat,
            lon: bankLon,
            accuracyM: 5,
            speedMps: 0,
            time: t,
          ),
        );

        expect(handler.debugPendingVisits, hasLength(1));
      },
    );

    test('a genuine restart seeds pendingVisits from the previous '
        "incarnation's last persisted snapshot, rather than dropping them "
        '(fix round 1, item 4) — and the seeded poiId is not re-detected '
        'even if the walker is still dwelling there', () async {
      final snapshotPath = '${tempDir.path}/snapshot.json';
      final priorVisit = PendingVisit(
        poiId: 'node/1',
        kind: 'coins',
        lat: bankLat,
        lon: bankLon,
        ts: DateTime.utc(2026, 8, 31, 9, 0, 5),
      );
      final onDiskSnapshot = TripSnapshot(
        status: TripStatus.recording,
        distanceKm: 1.0,
        steps: 10,
        startedAt: DateTime.utc(2026, 8, 31, 9),
        // After startedAt: a genuine restart, not a fresh trip seed (see
        // isFreshTripSeed).
        updatedAt: DateTime.utc(2026, 8, 31, 9, 5),
        profile: RoutingProfile.walk,
        routeBound: false,
        pendingVisits: [priorVisit],
      );
      await File(
        snapshotPath,
      ).writeAsString(jsonEncode(onDiskSnapshot.toJson()));

      final poisPath = await writePoisFixture([
        {'id': 'node/1', 'kind': 'coins', 'lat': bankLat, 'lon': bankLon},
      ]);
      final seed = TripSnapshot.starting(
        startedAt: DateTime.utc(2026, 8, 31, 9),
        profile: RoutingProfile.walk,
        routeBound: false,
      );
      SharedPreferences.setMockInitialValues({
        '$_prefsPrefix'
            'randomwalk_seed_snapshot': jsonEncode(
          seed.toJson(),
        ),
        '$_prefsPrefix'
                'randomwalk_snapshot_path':
            snapshotPath,
        '$_prefsPrefix'
                'randomwalk_tts_enabled':
            true,
        '$_prefsPrefix'
                'randomwalk_haptics_enabled':
            true,
        '$_prefsPrefix'
                'randomwalk_pois_file_path':
            poisPath,
      });

      final handler = TripTaskHandler();
      await handler.onStart(
        DateTime.utc(2026, 8, 31, 9, 10),
        TaskStarter.developer,
      );
      await handler.debugPoiStoreLoad;

      // Seeded immediately, before any fix at all.
      expect(handler.debugPendingVisits, hasLength(1));
      expect(handler.debugPendingVisits.single.poiId, 'node/1');

      // Still dwelling at the same spot post-restart must not re-detect it.
      var t = DateTime.utc(2026, 8, 31, 9, 10, 0);
      await handler.debugOnFix(
        GpsSample(
          lat: bankLat,
          lon: bankLon,
          accuracyM: 5,
          speedMps: 0,
          time: t,
        ),
      );
      t = t.add(const Duration(seconds: 5));
      await handler.debugOnFix(
        GpsSample(
          lat: bankLat,
          lon: bankLon,
          accuracyM: 5,
          speedMps: 0,
          time: t,
        ),
      );

      expect(handler.debugPendingVisits, hasLength(1));
    });
  });

  group(
    'ForegroundServiceTripTracker.deleteTrackFile (fix round 1 finding 1)',
    () {
      late Directory tempDir;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp('rw_delete_track_test');
      });

      tearDown(() async {
        await tempDir.delete(recursive: true);
      });

      test('deletes the sibling active_track.jsonl file if present', () async {
        final snapshotFile = File('${tempDir.path}/trip_snapshot.json');
        final trackFile = File('${tempDir.path}/active_track.jsonl');
        await trackFile.writeAsString('leftover\n');
        final tracker = ForegroundServiceTripTracker(snapshotFile);

        await tracker.deleteTrackFile();

        expect(await trackFile.exists(), isFalse);
      });

      test('is a silent no-op when no track file exists', () async {
        final snapshotFile = File('${tempDir.path}/trip_snapshot.json');
        final tracker = ForegroundServiceTripTracker(snapshotFile);
        await expectLater(tracker.deleteTrackFile(), completes);
      });
    },
  );

  group('TripTaskHandler — low-power mode (M5 Task 2d)', () {
    late Directory tempDir;
    late DateTime now;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rw_low_power_test');
      now = DateTime.utc(2026, 8, 31, 9);
      // Fix round 1, I5: MotionPolicy no longer accepts an explicit
      // DateTime per call — it reads this controllable clock instead, the
      // same pattern `AdaptiveGpsRateLimiter`'s own tests already use.
      TripTaskHandler.motionClockFactory = () => now;
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
      TripTaskHandler.motionChannelFactory = MotionChannel.new;
      TripTaskHandler.motionClockFactory = DateTime.now;
      TripTaskHandler.fallbackStepSensorFactory = ChannelStepSensor.new;
      TripTaskHandler.sessionControllerFactory = SessionController.new;
    });

    Future<void> seedPrefs({
      required bool routeBound,
      NavSeed? navSeed,
      DateTime? startedAt,
    }) async {
      final seed = TripSnapshot.starting(
        startedAt: startedAt ?? DateTime.utc(2026, 8, 31, 9),
        profile: RoutingProfile.walk,
        routeBound: routeBound,
      );
      SharedPreferences.setMockInitialValues({
        '$_prefsPrefix'
            'randomwalk_seed_snapshot': jsonEncode(
          seed.toJson(),
        ),
        '$_prefsPrefix'
                'randomwalk_snapshot_path':
            '${tempDir.path}/snapshot.json',
        '$_prefsPrefix'
                'randomwalk_tts_enabled':
            true,
        '$_prefsPrefix'
                'randomwalk_haptics_enabled':
            true,
        if (navSeed != null)
          '$_prefsPrefix'
              'randomwalk_nav_seed': jsonEncode(
            navSeed.toJson(),
          ),
      });
    }

    /// Polls [condition] rather than a single `pumpEventQueue()` — every
    /// motion-policy action reaches its effect through at least one
    /// `unawaited(...)` hop (`onRepeatEvent`/`onReceiveData` are `void`, by
    /// design: production must never let low-power bookkeeping block the
    /// framework's own callback), so a single microtask pump is not always
    /// enough to observe the settled state.
    Future<void> pollUntil(bool Function() condition) async {
      for (var i = 0; i < 50 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(condition(), isTrue);
    }

    test('fallback mode: sustained stillness pauses after 3 min, notification '
        'switches, and a movement fix resumes immediately', () async {
      await seedPrefs(routeBound: false);
      final handler = TripTaskHandler();
      await handler.onStart(now, TaskStarter.developer);

      // No native Activity Recognition on a host test (no method channel
      // mocked for randomwalk/motion) — this is exercising the fallback
      // path by construction, same as the emulator does in CI.
      await handler.debugOnFix(
        GpsSample(lat: 46.5, lon: 6.6, accuracyM: 5, speedMps: 0, time: now),
      );

      now = now.add(const Duration(minutes: 3));
      handler.onRepeatEvent(now);
      await pollUntil(() => handler.debugLowPowerPaused);
      expect(
        handler.debugLastNotificationText,
        kLowPowerPausedNotificationText,
      );

      // ~100 m away — well past the fallback movement threshold: the
      // walker moved, so this reads as an immediate resume.
      now = now.add(const Duration(seconds: 5));
      await handler.debugOnFix(
        GpsSample(
          lat: 46.5009,
          lon: 6.6,
          accuracyM: 5,
          speedMps: 1.2,
          time: now,
        ),
      );
      await pollUntil(() => !handler.debugLowPowerPaused);
      expect(
        handler.debugLastNotificationText,
        isNot(kLowPowerPausedNotificationText),
      );
    });

    test('a still spell shorter than 3 min never pauses — a red light must '
        'never suspend', () async {
      await seedPrefs(routeBound: false);
      final handler = TripTaskHandler();
      await handler.onStart(now, TaskStarter.developer);

      await handler.debugOnFix(
        GpsSample(lat: 46.5, lon: 6.6, accuracyM: 5, speedMps: 0, time: now),
      );
      // Moves away again after 90 s — well under the 3 min threshold.
      now = now.add(const Duration(seconds: 90));
      await handler.debugOnFix(
        GpsSample(
          lat: 46.5009,
          lon: 6.6,
          accuracyM: 5,
          speedMps: 1.2,
          time: now,
        ),
      );

      now = now.add(const Duration(minutes: 5));
      handler.onRepeatEvent(now);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(handler.debugLowPowerPaused, isFalse);
    });

    test('navGuided doubles the threshold to 6 minutes', () async {
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
      await handler.onStart(now, TaskStarter.developer);

      final start = route.shape.first;
      await handler.debugOnFix(
        GpsSample(
          lat: start.$1,
          lon: start.$2,
          accuracyM: 5,
          speedMps: 0,
          time: now,
        ),
      );

      now = now.add(const Duration(minutes: 3));
      handler.onRepeatEvent(now);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        handler.debugLowPowerPaused,
        isFalse,
        reason: 'the free-trip threshold must not apply while nav-guided',
      );

      now = now.add(const Duration(minutes: 3));
      handler.onRepeatEvent(now);
      await pollUntil(() => handler.debugLowPowerPaused);
    });

    test('gpsSilent is suppressed while paused — an intentional pause is not '
        'a GPS malfunction', () async {
      await seedPrefs(routeBound: false);
      final handler = TripTaskHandler();
      await handler.onStart(now, TaskStarter.developer);

      await handler.debugOnFix(
        GpsSample(lat: 46.5, lon: 6.6, accuracyM: 5, speedMps: 0, time: now),
      );
      now = now.add(const Duration(minutes: 3));
      handler.onRepeatEvent(now);
      await pollUntil(() => handler.debugLowPowerPaused);

      // Well past the ordinary 60 s GPS-silence threshold, with no fix at
      // all in the meantime — exactly what a genuine GPS failure would
      // also look like, which is the point of the assertion below.
      now = now.add(const Duration(minutes: 2));
      handler.onRepeatEvent(now);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final snapshotPath = '${tempDir.path}/snapshot.json';
      TripSnapshot? persisted;
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        persisted = await FileTripSnapshotStore(File(snapshotPath)).read();
        if (persisted?.lowPowerPaused == true) break;
      }
      expect(persisted?.lowPowerPaused, isTrue);
      expect(persisted?.gpsSilent, isFalse);
    });

    test(
      'fix round 2 — I2: resume does not publish a stale gpsSilent verdict '
      '(re-pointed through a real, SessionController-delivered fix)',
      () async {
        // Round 1's version of this test drove everything via debugOnFix,
        // which calls straight into _onFix and never touches `_session` at
        // all — so `_session.lastFixAt` stayed null for the whole test, and
        // the assertion only ever exercised the (already-correct)
        // recordingSince branch. A real trip's `lastFixAt` is set on every
        // fix and only ever nulled in `start()`, so it is essentially
        // always non-null well before a pause — this test now routes a
        // real fix through a fake `SessionController` (via
        // [TripTaskHandler.sessionControllerFactory]) to reproduce that.
        final positionControllers = <StreamController<Position>>[];
        Stream<Position> fakeStream(LocationSettings _) {
          final c = StreamController<Position>();
          positionControllers.add(c);
          return c.stream;
        }

        TripTaskHandler.sessionControllerFactory =
            ({
              required store,
              getPositionStream,
              getClock,
              checkPermissions,
              getCurrentPosition,
              locationSettings,
              onSessionEnded,
              onSessionError,
              onFix,
            }) => SessionController(
              store: store,
              getPositionStream: fakeStream,
              // Same simulated clock `motionClockFactory` drives — so
              // `lastFixAt` genuinely goes several (simulated) minutes
              // stale while paused, not just milliseconds of real time.
              getClock: () => now,
              checkPermissions: checkPermissions,
              getCurrentPosition: getCurrentPosition,
              locationSettings: locationSettings,
              onSessionEnded: onSessionEnded,
              onSessionError: onSessionError,
              onFix: onFix,
            );

        await seedPrefs(routeBound: false);
        final handler = TripTaskHandler();
        await handler.onStart(now, TaskStarter.developer);

        // A real, accurate fix — sets `_session.lastFixAt` exactly as a
        // real trip would, and (via the same onFix hook) starts the
        // fallback stillness timer.
        positionControllers.single.add(
          Position(
            latitude: 46.5,
            longitude: 6.6,
            accuracy: 5,
            speed: 0,
            speedAccuracy: 0,
            heading: 0,
            headingAccuracy: 0,
            timestamp: now,
            altitudeAccuracy: 0,
            altitude: 0,
          ),
        );
        await pumpEventQueue();

        now = now.add(const Duration(minutes: 3));
        handler.onRepeatEvent(now);
        await pollUntil(() => handler.debugLowPowerPaused);

        // Sit paused well past the ordinary 60 s silence threshold —
        // `lastFixAt` is now several minutes stale on the shared clock.
        now = now.add(const Duration(minutes: 4));
        handler.onRepeatEvent(now);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Movement resumes — the very publish that clears the pause must
        // not carry a stale gpsSilent verdict.
        handler.onReceiveData({'steps': 1});
        await pollUntil(() => !handler.debugLowPowerPaused);

        expect(
          handler.debugIsGpsSilentAt(now),
          isFalse,
          reason:
              'the resume must not show a GPS-failure banner at the exact '
              'moment the walker starts moving again, even though the '
              'pre-pause fix is now several minutes stale',
        );
      },
    );

    test('one safety fix is attempted every 3 min while paused', () async {
      await seedPrefs(routeBound: false);
      final handler = TripTaskHandler();
      await handler.onStart(now, TaskStarter.developer);

      await handler.debugOnFix(
        GpsSample(lat: 46.5, lon: 6.6, accuracyM: 5, speedMps: 0, time: now),
      );
      now = now.add(const Duration(minutes: 3));
      handler.onRepeatEvent(now);
      await pollUntil(() => handler.debugLowPowerPaused);
      expect(handler.debugSafetyFixCount, 0);

      now = now.add(const Duration(minutes: 3) - const Duration(seconds: 1));
      handler.onRepeatEvent(now);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(handler.debugSafetyFixCount, 0);

      now = now.add(const Duration(seconds: 1));
      handler.onRepeatEvent(now);
      await pollUntil(() => handler.debugSafetyFixCount == 1);
    });

    test(
      'a step-counter delta resumes immediately, fallback-mode style',
      () async {
        await seedPrefs(routeBound: false);
        final handler = TripTaskHandler();
        await handler.onStart(now, TaskStarter.developer);

        await handler.debugOnFix(
          GpsSample(lat: 46.5, lon: 6.6, accuracyM: 5, speedMps: 0, time: now),
        );
        now = now.add(const Duration(minutes: 3));
        handler.onRepeatEvent(now);
        await pollUntil(() => handler.debugLowPowerPaused);

        handler.onReceiveData({'steps': 42});
        await pollUntil(() => !handler.debugLowPowerPaused);
      },
    );

    test('native mode: a fake MotionSignalSource drives pause/resume through '
        'the same channel real STILL enter/exit events would', () async {
      final fake = FakeMotionSignalSource();
      TripTaskHandler.motionChannelFactory = () => fake;

      await seedPrefs(routeBound: false);
      final handler = TripTaskHandler();
      await handler.onStart(now, TaskStarter.developer);

      await pollUntil(() => fake.started);
      expect(fake.stopped, isFalse);

      fake.emit(true); // STILL entered
      await Future<void>.delayed(const Duration(milliseconds: 50));

      now = now.add(const Duration(minutes: 3));
      handler.onRepeatEvent(now);
      await pollUntil(() => handler.debugLowPowerPaused);

      fake.emit(false); // STILL exited
      await pollUntil(() => !handler.debugLowPowerPaused);
    });

    group('fix round 1 — C1 (resume racing an in-flight pause)', () {
      test(
        'a resume signal following a pause decision very closely still '
        'converges on a coherent, correctly-published resumed state',
        () async {
          await seedPrefs(routeBound: false);
          final handler = TripTaskHandler();
          await handler.onStart(now, TaskStarter.developer);

          await handler.debugOnFix(
            GpsSample(
              lat: 46.5,
              lon: 6.6,
              accuracyM: 5,
              speedMps: 0,
              time: now,
            ),
          );
          now = now.add(const Duration(minutes: 3));
          // tick() decides to pause; before that reconciliation has
          // settled, an independent, unserialized trigger (a step delta)
          // decides to resume — the C1 interleaving, reproduced at the
          // handler's own dispatch layer (`_motionReconcileChain`) rather
          // than SessionController's own `_transitionChain`, which has its
          // own dedicated, fully deterministic regression test in
          // session_controller_test.dart.
          handler.onRepeatEvent(now);
          handler.onReceiveData({'steps': 1});

          await pollUntil(() => !handler.debugLowPowerPaused);
          expect(
            handler.debugLastNotificationText,
            isNot(kLowPowerPausedNotificationText),
          );

          // Coherent: the safety-fix schedule must have been cancelled by
          // the resume, not left running from the superseded pause —
          // advancing past what would have been the first safety-fix mark
          // must not fire one.
          now = now.add(const Duration(minutes: 4));
          handler.onRepeatEvent(now);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(handler.debugSafetyFixCount, 0);
        },
      );
    });

    group('fix round 1 — I3 (safety-fix movement guard)', () {
      Future<TripTaskHandler> pausedHandler() async {
        await seedPrefs(routeBound: false);
        final handler = TripTaskHandler();
        await handler.onStart(now, TaskStarter.developer);
        await handler.debugOnFix(
          GpsSample(lat: 46.5, lon: 6.6, accuracyM: 5, speedMps: 0, time: now),
        );
        now = now.add(const Duration(minutes: 3));
        handler.onRepeatEvent(now);
        await pollUntil(() => handler.debugLowPowerPaused);
        return handler;
      }

      test('an inaccurate safety fix neither pauses nor resumes', () async {
        final handler = await pausedHandler();

        // ~100 m from the anchor — well past the 15 m movement threshold —
        // but far too imprecise (80 m accuracy) to trust either way.
        await handler.debugHandleSafetyFixResult(
          GpsSample(
            lat: 46.5009,
            lon: 6.6,
            accuracyM: 80,
            speedMps: 0,
            time: now,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          handler.debugLowPowerPaused,
          isTrue,
          reason:
              'an unusably imprecise fix must not resolve the doubt '
              'either way — it retries on the normal cadence instead',
        );
        expect(handler.debugSafetyFixCount, 1);
      });

      test('an accurate safety fix showing movement resumes', () async {
        final handler = await pausedHandler();

        await handler.debugHandleSafetyFixResult(
          GpsSample(
            lat: 46.5009,
            lon: 6.6,
            accuracyM: 5,
            speedMps: 1.2,
            time: now,
          ),
        );
        await pollUntil(() => !handler.debugLowPowerPaused);
      });

      test('an accurate safety fix within the anchor threshold leaves the '
          'pause untouched', () async {
        final handler = await pausedHandler();

        await handler.debugHandleSafetyFixResult(
          GpsSample(
            lat: 46.500002,
            lon: 6.6,
            accuracyM: 5,
            speedMps: 0,
            time: now,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(handler.debugLowPowerPaused, isTrue);
      });

      test('a failed safety fix (null) neither pauses nor resumes, and still '
          'counts as an attempt', () async {
        final handler = await pausedHandler();

        await handler.debugHandleSafetyFixResult(null);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(handler.debugLowPowerPaused, isTrue);
        expect(handler.debugSafetyFixCount, 1);
      });
    });

    group('fix round 1 — I4 (fallback-mode step-counter polling)', () {
      test('polls the step counter directly every 30 s while paused, resuming '
          'within one poll — the screen-off scenario the UI-driven step push '
          'cannot reach', () async {
        final stepSensor = FakeStepSensor(value: 1000);
        TripTaskHandler.fallbackStepSensorFactory = () => stepSensor;

        await seedPrefs(routeBound: false);
        final handler = TripTaskHandler();
        await handler.onStart(now, TaskStarter.developer);

        await handler.debugOnFix(
          GpsSample(lat: 46.5, lon: 6.6, accuracyM: 5, speedMps: 0, time: now),
        );
        now = now.add(const Duration(minutes: 3));
        handler.onRepeatEvent(now);
        await pollUntil(() => handler.debugLowPowerPaused);

        // The first tick while paused establishes the poll baseline.
        now = now.add(const Duration(seconds: 1));
        handler.onRepeatEvent(now);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(handler.debugLowPowerPaused, isTrue);

        // "Screen off" scenario: the UI's own step push (onReceiveData)
        // never arrives — that is exactly the gap I4 exists to close.
        // Only the service's own poll, 30 s later, catches this.
        stepSensor.value = 1050;
        now = now.add(TripTaskHandler.kFallbackStepPollInterval);
        handler.onRepeatEvent(now);
        await pollUntil(() => !handler.debugLowPowerPaused);
      });

      test('fix round 2 — I4: a null first read (sensor not yet registered) '
          'does not push the baseline out to a second 30 s interval', () async {
        // Bug: _lastFallbackStepPollAt used to be stamped BEFORE reading
        // the sensor, so a null first read (the listener registers
        // asynchronously in start(), just above) silently rate-limited
        // the real baseline-establishing read to a full interval later —
        // doubling the documented worst-case latency to ~60 s.
        final stepSensor = FakeStepSensor(value: 1000, nullReadsBeforeReady: 1);
        TripTaskHandler.fallbackStepSensorFactory = () => stepSensor;

        await seedPrefs(routeBound: false);
        final handler = TripTaskHandler();
        await handler.onStart(now, TaskStarter.developer);

        await handler.debugOnFix(
          GpsSample(lat: 46.5, lon: 6.6, accuracyM: 5, speedMps: 0, time: now),
        );
        now = now.add(const Duration(minutes: 3));
        // Pause decided; the poll this same tick triggers reads null.
        handler.onRepeatEvent(now);
        await pollUntil(() => handler.debugLowPowerPaused);

        // The very next tick, shortly after (not a full 30 s later),
        // must retry and succeed in establishing the baseline.
        now = now.add(const Duration(seconds: 2));
        handler.onRepeatEvent(now);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Exactly one interval after THAT (not two) is enough to catch
        // the step delta.
        stepSensor.value = 1050;
        now = now.add(TripTaskHandler.kFallbackStepPollInterval);
        handler.onRepeatEvent(now);
        await pollUntil(() => !handler.debugLowPowerPaused);
      });

      test(
        'does not resume before the 30 s poll interval has elapsed',
        () async {
          final stepSensor = FakeStepSensor(value: 1000);
          TripTaskHandler.fallbackStepSensorFactory = () => stepSensor;

          await seedPrefs(routeBound: false);
          final handler = TripTaskHandler();
          await handler.onStart(now, TaskStarter.developer);

          await handler.debugOnFix(
            GpsSample(
              lat: 46.5,
              lon: 6.6,
              accuracyM: 5,
              speedMps: 0,
              time: now,
            ),
          );
          now = now.add(const Duration(minutes: 3));
          // Pause decided; the poll this same tick triggers establishes the
          // baseline (1000) immediately — fix round 2 (I4) makes this
          // reliable (previously a race with _doReconcileStream's own
          // baseline reset could silently drop this first poll's stamp,
          // only really taking effect one tick later — see that fix's own
          // doc comment).
          handler.onRepeatEvent(now);
          await pollUntil(() => handler.debugLowPowerPaused);

          stepSensor.value = 1050;
          now = now.add(
            TripTaskHandler.kFallbackStepPollInterval -
                const Duration(seconds: 1),
          );
          handler.onRepeatEvent(now); // 29 s after the baseline — not due yet
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(handler.debugLowPowerPaused, isTrue);
        },
      );

      test('is never consulted in native mode', () async {
        final fake = FakeMotionSignalSource();
        TripTaskHandler.motionChannelFactory = () => fake;
        var stepSensorStarted = false;
        TripTaskHandler.fallbackStepSensorFactory = () {
          stepSensorStarted = true;
          return FakeStepSensor(value: 1000);
        };

        await seedPrefs(routeBound: false);
        final handler = TripTaskHandler();
        await handler.onStart(now, TaskStarter.developer);
        await pollUntil(() => fake.started);

        fake.emit(true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        now = now.add(const Duration(minutes: 3));
        handler.onRepeatEvent(now);
        await pollUntil(() => handler.debugLowPowerPaused);

        now = now.add(TripTaskHandler.kFallbackStepPollInterval * 2);
        handler.onRepeatEvent(now);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          stepSensorStarted,
          isFalse,
          reason:
              'native mode has its own signal — polling the step '
              'counter too would be pointless extra battery cost',
        );
      });
    });
  });
}

/// A fake [MotionSignalSource] — the native Activity Recognition Transition
/// API has no way to be exercised from a host-run `flutter test` (see
/// `MotionChannel`'s own doc comment), so `TripTaskHandler`'s low-power-mode
/// tests swap this in via [TripTaskHandler.motionChannelFactory] to drive
/// the native-available path directly.
class FakeMotionSignalSource implements MotionSignalSource {
  FakeMotionSignalSource({this.startResult = true});

  final bool startResult;
  bool started = false;
  bool stopped = false;
  final _controller = StreamController<bool>.broadcast();

  @override
  Future<bool> start() async {
    started = true;
    return startResult;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Stream<bool> get transitions => _controller.stream;

  void emit(bool stillEntered) => _controller.add(stillEntered);
}
