import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/exploration/track_sampler.dart' show kTrackMaxPoints;
import 'package:randomwalk/nav/nav_fields.dart';
import 'package:randomwalk/nav/tts.dart';
import 'package:randomwalk/session/recorder.dart' show GpsSample;
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

  group('gpsSilenceThresholdFor (item 3 regression)', () {
    test('at the close 3 m filter, the threshold is the base one minute',
        () {
      expect(gpsSilenceThresholdFor(kNavCloseDistanceFilterM),
          const Duration(seconds: 60));
    });

    test('at the far 12 m filter, the threshold scales to keep the same '
        'floor speed as the close filter (0.18 km/h)', () {
      final threshold = gpsSilenceThresholdFor(kNavFarDistanceFilterM);
      expect(threshold, const Duration(minutes: 4));

      // 0.18 km/h at both filters — the false-positive this exists for
      // (12 m / 60 s = 0.72 km/h) never appears if this ratio holds.
      final closeFloorKmh = kNavCloseDistanceFilterM /
          kGpsSilenceThreshold.inSeconds *
          3.6;
      final farFloorKmh = kNavFarDistanceFilterM / threshold.inSeconds * 3.6;
      expect(farFloorKmh, closeTo(closeFloorKmh, 1e-9));
    });

    test('never returns less than the documented base threshold', () {
      // Filters below the close filter are not expected in practice, but
      // the scaling must be a floor, never a tightening.
      expect(gpsSilenceThresholdFor(1).inSeconds,
          greaterThanOrEqualTo(kGpsSilenceThreshold.inSeconds));
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
            replanning: true,
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
      expect(fresh.navReplanning, isFalse);
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
        '$_prefsPrefix' 'randomwalk_seed_snapshot': jsonEncode(seed.toJson()),
        '$_prefsPrefix' 'randomwalk_snapshot_path': snapshotPath,
        '$_prefsPrefix' 'randomwalk_tts_enabled': true,
        '$_prefsPrefix' 'randomwalk_haptics_enabled': true,
      });
    }

    test('a fresh (non-restart) start discards a leftover track file left '
        'by an earlier, already-finalised trip', () async {
      final snapshotPath = '${tempDir.path}/snapshot.json';
      final trackPath = '${tempDir.path}/active_track.jsonl';
      await File(trackPath).writeAsString(
          '${jsonEncode({'lat': 1.0, 'lon': 2.0})}\n');
      await seedPrefs(snapshotPath); // no on-disk snapshot -> not a restart.

      final handler = TripTaskHandler();
      await handler.onStart(
          DateTime.utc(2026, 8, 31, 9), TaskStarter.developer);

      expect(await File(trackPath).exists(), isFalse);
    });

    test('a genuine restart (an already-recording on-disk snapshot) keeps '
        'the existing track file\'s content rather than wiping it',
        () async {
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
      await File(snapshotPath)
          .writeAsString(jsonEncode(onDiskSnapshot.toJson()));
      final trackLine = '${jsonEncode({'lat': 46.5, 'lon': 6.6})}\n';
      await File(trackPath).writeAsString(trackLine);
      await seedPrefs(snapshotPath);

      final handler = TripTaskHandler();
      await handler.onStart(
          DateTime.utc(2026, 8, 31, 9, 10), TaskStarter.developer);

      expect(await File(trackPath).readAsString(), trackLine);
    });

    test('no leftover track file at all is not an error — onStart still '
        'reaches recording', () async {
      final snapshotPath = '${tempDir.path}/snapshot.json';
      await seedPrefs(snapshotPath);
      final handler = TripTaskHandler();
      await handler.onStart(
          DateTime.utc(2026, 8, 31, 9), TaskStarter.developer);
      expect(handler.debugIsRecording, isTrue);
    });

    test(
        'a freshly-seeded on-disk snapshot (updatedAt == startedAt) is NOT '
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
      await File(trackPath)
          .writeAsString('${jsonEncode({'lat': 1.0, 'lon': 2.0})}\n');
      await seedPrefs(snapshotPath);

      final handler = TripTaskHandler();
      await handler.onStart(
          DateTime.utc(2026, 8, 31, 9), TaskStarter.developer);

      expect(await File(trackPath).exists(), isFalse);
    });

    test(
        'the on-disk track stays bounded at kTrackMaxPoints even after far '
        'more fixes than that, kept in sync via the thinned-rewrite — fix '
        'round 1 finding 2', () async {
      final snapshotPath = '${tempDir.path}/snapshot.json';
      final trackPath = '${tempDir.path}/active_track.jsonl';
      await seedPrefs(snapshotPath);
      final handler = TripTaskHandler();
      await handler.onStart(
          DateTime.utc(2026, 8, 31, 9), TaskStarter.developer);

      // Each step is ~33 m north — comfortably over the 25 m distance
      // filter default, so every fix is kept by TrackSampler.
      var lat = 46.5;
      for (var i = 0; i < kTrackMaxPoints + 500; i++) {
        lat += 0.0003;
        await handler.debugOnFix(GpsSample(
          lat: lat,
          lon: 6.63,
          accuracyM: 5,
          speedMps: 1.2,
          time: DateTime.utc(2026, 8, 31, 9, 0, 0, i),
        ));
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

    test(
        'a snapshot whose updatedAt has moved past startedAt (a real '
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

    test(
        'a resumeInterrupted-style seed (same startedAt, freshly-stamped '
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
        '$_prefsPrefix' 'randomwalk_seed_snapshot': jsonEncode(seed.toJson()),
        '$_prefsPrefix' 'randomwalk_snapshot_path': snapshotPath,
        '$_prefsPrefix' 'randomwalk_tts_enabled': true,
        '$_prefsPrefix' 'randomwalk_haptics_enabled': true,
        if (poisFilePath != null)
          '$_prefsPrefix' 'randomwalk_pois_file_path': poisFilePath,
      });
      final handler = TripTaskHandler();
      await handler.onStart(
          DateTime.utc(2026, 8, 31, 9), TaskStarter.developer);
      await handler.debugPoiStoreLoad;
      return handler;
    }

    test('no poisFilePath at all: recording still works, no visits ever',
        () async {
      final snapshotPath = '${tempDir.path}/snapshot.json';
      final handler =
          await startedHandler(snapshotPath: snapshotPath, poisFilePath: null);
      expect(handler.debugIsRecording, isTrue);

      await handler.debugOnFix(GpsSample(
        lat: churchLat,
        lon: churchLon,
        accuracyM: 5,
        speedMps: 1.2,
        time: DateTime.utc(2026, 8, 31, 9, 0, 10),
      ));

      expect(handler.debugPendingVisits, isEmpty);
    });

    test(
        'a dwell of >=5s within 25m of a landmark publishes it via '
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
          snapshotPath: snapshotPath, poisFilePath: poisPath);

      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      await handler.debugOnFix(GpsSample(
          lat: churchLat,
          lon: churchLon,
          accuracyM: 5,
          speedMps: 0,
          time: t0));
      await handler.debugOnFix(GpsSample(
          lat: churchLat,
          lon: churchLon,
          accuracyM: 5,
          speedMps: 0,
          time: t0.add(const Duration(seconds: 5))));

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
      for (var i = 0; i < 20 && persisted?.pendingVisits.isEmpty != false; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        persisted = await FileTripSnapshotStore(File(snapshotPath)).read();
      }
      expect(persisted?.pendingVisits, hasLength(1));
      expect(persisted!.pendingVisits.single.poiId, 'node/1');
    });

    test('a landmark far outside the 3km disc is never even a candidate',
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
          snapshotPath: snapshotPath, poisFilePath: poisPath);

      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      await handler.debugOnFix(GpsSample(
          lat: churchLat, lon: churchLon, accuracyM: 5, speedMps: 0, time: t0));
      await handler.debugOnFix(GpsSample(
          lat: churchLat,
          lon: churchLon,
          accuracyM: 5,
          speedMps: 0,
          time: t0.add(const Duration(seconds: 30))));

      expect(handler.debugPendingVisits, isEmpty);
    });

    test('pendingVisits is capped at kPendingVisitsMax, oldest dropped first',
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
          snapshotPath: snapshotPath, poisFilePath: poisPath);

      var t = DateTime.utc(2026, 8, 31, 9, 0, 0);
      for (var i = 0; i < pois.length; i++) {
        final lat = churchLat + i * 0.0003;
        await handler.debugOnFix(
            GpsSample(lat: lat, lon: churchLon, accuracyM: 5, speedMps: 0, time: t));
        t = t.add(const Duration(seconds: 5));
        await handler.debugOnFix(
            GpsSample(lat: lat, lon: churchLon, accuracyM: 5, speedMps: 0, time: t));
        t = t.add(const Duration(seconds: 1));
      }

      expect(handler.debugPendingVisits, hasLength(kPendingVisitsMax));
      // The oldest (node/0) must have been dropped; the newest survives.
      final ids = handler.debugPendingVisits.map((v) => v.poiId).toList();
      expect(ids, isNot(contains('node/0')));
      expect(ids.last, 'node/${pois.length - 1}');
    });

    test('a landmark already visited via debugOnFix is never detected twice',
        () async {
      final snapshotPath = '${tempDir.path}/snapshot.json';
      final poisPath = await writePoisFixture([
        {'id': 'node/1', 'kind': 'coins', 'lat': bankLat, 'lon': bankLon},
      ]);
      final handler = await startedHandler(
          snapshotPath: snapshotPath, poisFilePath: poisPath);

      var t = DateTime.utc(2026, 8, 31, 9, 0, 0);
      await handler.debugOnFix(
          GpsSample(lat: bankLat, lon: bankLon, accuracyM: 5, speedMps: 0, time: t));
      t = t.add(const Duration(seconds: 5));
      await handler.debugOnFix(
          GpsSample(lat: bankLat, lon: bankLon, accuracyM: 5, speedMps: 0, time: t));
      // Keep dwelling at the same spot for a long time afterwards.
      t = t.add(const Duration(minutes: 5));
      await handler.debugOnFix(
          GpsSample(lat: bankLat, lon: bankLon, accuracyM: 5, speedMps: 0, time: t));

      expect(handler.debugPendingVisits, hasLength(1));
    });
  });

  group('ForegroundServiceTripTracker.deleteTrackFile (fix round 1 finding 1)',
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
  });
}
