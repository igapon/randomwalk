import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/nav/nav_fields.dart';
import 'package:randomwalk/tracking/trip_snapshot.dart';
import 'package:randomwalk/valhalla/models.dart';

TripSnapshot _recording({
  double distanceKm = 1.2,
  int steps = 1600,
  bool routeBound = true,
  RoutingProfile profile = RoutingProfile.walk,
}) =>
    TripSnapshot(
      status: TripStatus.recording,
      distanceKm: distanceKm,
      steps: steps,
      startedAt: DateTime.utc(2026, 8, 30, 10, 0, 0),
      updatedAt: DateTime.utc(2026, 8, 30, 10, 32, 0),
      profile: profile,
      routeBound: routeBound,
    );

void main() {
  group('serialization', () {
    test('round-trips every field through JSON', () {
      final restored =
          TripSnapshot.fromJson(jsonDecode(jsonEncode(_recording().toJson())));

      expect(restored.status, TripStatus.recording);
      expect(restored.distanceKm, closeTo(1.2, 1e-9));
      expect(restored.steps, 1600);
      expect(restored.startedAt, DateTime.utc(2026, 8, 30, 10, 0, 0));
      expect(restored.updatedAt, DateTime.utc(2026, 8, 30, 10, 32, 0));
      expect(restored.profile, RoutingProfile.walk);
      expect(restored.routeBound, true);
    });

    test('timestamps survive as UTC regardless of the local zone', () {
      final local = TripSnapshot(
        status: TripStatus.recording,
        distanceKm: 0,
        steps: 0,
        startedAt: DateTime(2026, 8, 30, 10),
        updatedAt: DateTime(2026, 8, 30, 10, 1),
        profile: RoutingProfile.bike,
        routeBound: false,
      );
      final restored = TripSnapshot.fromJson(jsonDecode(jsonEncode(local.toJson())));
      expect(restored.startedAt.isAtSameMomentAs(local.startedAt), isTrue);
      expect(restored.updatedAt.isAtSameMomentAs(local.updatedAt), isTrue);
    });

    test('carries the service-side GPS silence flag', () {
      final silent = _recording().copyWith(gpsSilent: true);
      expect(
        TripSnapshot.fromJson(jsonDecode(jsonEncode(silent.toJson()))).gpsSilent,
        isTrue,
      );
      expect(
        TripSnapshot.fromJson(jsonDecode(jsonEncode(_recording().toJson())))
            .gpsSilent,
        isFalse,
      );
    });

    test('a document written before the flag existed reads as not silent', () {
      final legacy = _recording().toJson()..remove('gpsSilent');
      expect(TripSnapshot.fromJson(legacy).gpsSilent, isFalse);
    });

    test('carries the navigation fields the service computes', () {
      final navigating = _recording().copyWith(
        nav: const NavFields(
          instruction: 'Tournez à gauche sur la rue de Bourg',
          distanceToManeuverM: 120,
          remainingKm: 2.4,
          etaSeconds: 1920,
          offRoute: true,
          arrived: false,
          replanCount: 2,
          routeShapeEnc: '_izlhA~rlgdF',
          // Deliberately not persisted: it phrases a notification, it is not
          // trip state the UI has to rebuild from disk.
          degraded: true,
        ),
      );
      final restored =
          TripSnapshot.fromJson(jsonDecode(jsonEncode(navigating.toJson())));

      expect(restored.navInstruction, 'Tournez à gauche sur la rue de Bourg');
      expect(restored.navDistanceToManeuverM, closeTo(120, 1e-9));
      expect(restored.navRemainingKm, closeTo(2.4, 1e-9));
      expect(restored.navEtaSeconds, 1920);
      expect(restored.navOffRoute, isTrue);
      expect(restored.navArrived, isFalse);
      expect(restored.navReplanCount, 2);
      expect(restored.navRouteShapeEnc, '_izlhA~rlgdF');
    });

    test('a free trip carries no navigation fields at all', () {
      final restored =
          TripSnapshot.fromJson(jsonDecode(jsonEncode(_recording().toJson())));

      expect(restored.navInstruction, isNull);
      expect(restored.navDistanceToManeuverM, isNull);
      expect(restored.navRemainingKm, isNull);
      expect(restored.navEtaSeconds, isNull);
      expect(restored.navRouteShapeEnc, isNull);
      expect(restored.navOffRoute, isFalse);
      expect(restored.navArrived, isFalse);
      expect(restored.navReplanCount, 0);
    });

    test('a document written before navigation existed reads as not navigating',
        () {
      final legacy = _recording().toJson()
        ..remove('navOffRoute')
        ..remove('navArrived')
        ..remove('navReplanCount');
      final restored = TripSnapshot.fromJson(legacy);

      expect(restored.navOffRoute, isFalse);
      expect(restored.navArrived, isFalse);
      expect(restored.navReplanCount, 0);
      expect(restored.navInstruction, isNull);
      expect(restored.distanceKm, closeTo(1.2, 1e-9));
    });

    test('an unknown profile name degrades to walk rather than throwing', () {
      final json = _recording().toJson()..['profile'] = 'hovercraft';
      expect(TripSnapshot.fromJson(json).profile, RoutingProfile.walk);
    });

    test('elapsed is measured from startedAt', () {
      expect(_recording().elapsedAt(DateTime.utc(2026, 8, 30, 10, 32, 0)),
          const Duration(minutes: 32));
    });

    test('elapsed never goes negative if the clock jumped backwards', () {
      expect(_recording().elapsedAt(DateTime.utc(2026, 8, 30, 9, 0, 0)),
          Duration.zero);
    });
  });

  group('walk plausibility', () {
    test('a walk with a normal cadence is plausible', () {
      expect(_recording(distanceKm: 2.4, steps: 3100).needsReview, isFalse);
    });

    test('kilometres with (almost) no steps is flagged for review', () {
      expect(_recording(distanceKm: 2.4, steps: 12).needsReview, isTrue);
    });

    test('a short trip is never flagged (step sensors warm up slowly)', () {
      expect(_recording(distanceKm: 0.2, steps: 0).needsReview, isFalse);
    });

    test('a bike trip is never flagged for lack of steps', () {
      expect(
          _recording(distanceKm: 8, steps: 0, profile: RoutingProfile.bike)
              .needsReview,
          isFalse);
    });
  });

  group('FileTripSnapshotStore', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('randomwalk_snapshot');
    });
    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    FileTripSnapshotStore store() =>
        FileTripSnapshotStore(File('${dir.path}/trip_snapshot.json'));

    test('read returns null before anything is written', () async {
      expect(await store().read(), isNull);
    });

    test('a snapshot written by one instance is readable by another', () async {
      await store().write(_recording());
      final restored = await store().read();
      expect(restored!.distanceKm, closeTo(1.2, 1e-9));
      expect(restored.steps, 1600);
    });

    test('clear removes the snapshot', () async {
      final s = store();
      await s.write(_recording());
      await s.clear();
      expect(await s.read(), isNull);
    });

    test('a corrupt snapshot reads as null instead of throwing', () async {
      await File('${dir.path}/trip_snapshot.json').writeAsString('{"status":');
      expect(await store().read(), isNull);
    });

    test('writes leave no temp file behind', () async {
      await store().write(_recording());
      expect(
        dir.listSync().map((e) => e.path.split(Platform.pathSeparator).last),
        ['trip_snapshot.json'],
      );
    });
  });

  group('ThrottledSnapshotWriter', () {
    late _RecordingStore store;
    late DateTime now;
    late ThrottledSnapshotWriter writer;

    setUp(() {
      store = _RecordingStore();
      now = DateTime.utc(2026, 8, 30, 10, 0, 0);
      writer = ThrottledSnapshotWriter(store,
          interval: const Duration(seconds: 2), clock: () => now);
    });

    test('the first submit is written straight through', () async {
      await writer.submit(_recording(distanceKm: 0.1));
      expect(store.writes, hasLength(1));
      expect(store.writes.single.distanceKm, closeTo(0.1, 1e-9));
    });

    test('submits inside the interval are coalesced, not written', () async {
      await writer.submit(_recording(distanceKm: 0.1));
      now = now.add(const Duration(milliseconds: 500));
      await writer.submit(_recording(distanceKm: 0.2));
      now = now.add(const Duration(milliseconds: 500));
      await writer.submit(_recording(distanceKm: 0.3));
      expect(store.writes, hasLength(1));
    });

    test('the next submit past the interval writes the latest value', () async {
      await writer.submit(_recording(distanceKm: 0.1));
      now = now.add(const Duration(milliseconds: 500));
      await writer.submit(_recording(distanceKm: 0.2));
      now = now.add(const Duration(seconds: 2));
      await writer.submit(_recording(distanceKm: 0.3));
      expect(store.writes, hasLength(2));
      expect(store.writes.last.distanceKm, closeTo(0.3, 1e-9));
    });

    test('flush writes a coalesced value even inside the interval', () async {
      await writer.submit(_recording(distanceKm: 0.1));
      now = now.add(const Duration(milliseconds: 100));
      await writer.submit(_recording(distanceKm: 0.9));
      await writer.flush();
      expect(store.writes, hasLength(2));
      expect(store.writes.last.distanceKm, closeTo(0.9, 1e-9));
    });

    test('flush with nothing pending does not write again', () async {
      await writer.submit(_recording(distanceKm: 0.1));
      await writer.flush();
      await writer.flush();
      expect(store.writes, hasLength(1));
    });

    test('a failing write does not stop later writes', () async {
      store.failNext = true;
      await writer.submit(_recording(distanceKm: 0.1));
      now = now.add(const Duration(seconds: 3));
      await writer.submit(_recording(distanceKm: 0.4));
      expect(store.writes, hasLength(1));
      expect(store.writes.single.distanceKm, closeTo(0.4, 1e-9));
    });
  });
}

class _RecordingStore implements TripSnapshotStore {
  final writes = <TripSnapshot>[];
  bool failNext = false;
  TripSnapshot? _current;

  @override
  Future<TripSnapshot?> read() async => _current;

  @override
  Future<void> write(TripSnapshot snapshot) async {
    if (failNext) {
      failNext = false;
      throw const FileSystemException('disk full');
    }
    writes.add(snapshot);
    _current = snapshot;
  }

  @override
  Future<void> clear() async => _current = null;
}
