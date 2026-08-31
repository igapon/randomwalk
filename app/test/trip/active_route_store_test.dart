import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/trip/active_route_store.dart';
import 'package:randomwalk/valhalla/models.dart';

RouteResult _route() => const RouteResult(
      shape: [(46.52, 6.63), (46.53, 6.64), (46.54, 6.65)],
      distanceKm: 2.4,
      duration: Duration(minutes: 32),
      maneuvers: [
        Maneuver(instruction: 'Prenez à gauche', lengthKm: 0.4, beginShapeIndex: 0),
        Maneuver(instruction: 'Continuez tout droit', lengthKm: 2.0, beginShapeIndex: 1),
      ],
    );

ActiveRoute _activeRoute() => ActiveRoute(
      route: _route(),
      destination: const (46.54, 6.65),
      departure: const (46.52, 6.63),
      profile: RoutingProfile.bike,
    );

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('randomwalk_route_store');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  FileActiveRouteStore store() =>
      FileActiveRouteStore(File('${dir.path}/active_route.json'));

  group('ActiveRoute.copyWith — clearDestination (fix-round-1)', () {
    test('drops the destination, leaving everything else untouched', () {
      final route = _activeRoute();
      final cleared = route.copyWith(clearDestination: true);

      expect(cleared.destination, isNull);
      expect(cleared.departure, route.departure);
      expect(cleared.route, route.route);
      expect(cleared.profile, route.profile);
    });

    test('clearDestination wins even if a replacement destination is also '
        'passed', () {
      final route = _activeRoute();
      final cleared = route.copyWith(
          destination: const (0, 0), clearDestination: true);

      expect(cleared.destination, isNull);
    });

    test('clearDestination and clearDeparture compose', () {
      final route = _activeRoute();
      final cleared =
          route.copyWith(clearDestination: true, clearDeparture: true);

      expect(cleared.destination, isNull);
      expect(cleared.departure, isNull);
      expect(cleared.route, route.route);
    });

    test('defaults to false — an ordinary copyWith call keeps the '
        'destination', () {
      final route = _activeRoute();
      final copy = route.copyWith(profile: RoutingProfile.walk);

      expect(copy.destination, route.destination);
    });
  });

  test('load returns null when nothing was ever persisted', () async {
    expect(await store().load(), isNull);
  });

  test('save then load round-trips the whole planning state', () async {
    await store().save(_activeRoute());

    // A *fresh* store instance, as after a cold start.
    final restored = await store().load();

    expect(restored, isNotNull);
    expect(restored!.destination, const (46.54, 6.65));
    expect(restored.departure, const (46.52, 6.63));
    expect(restored.profile, RoutingProfile.bike);
    expect(restored.route!.distanceKm, closeTo(2.4, 1e-9));
    expect(restored.route!.duration, const Duration(minutes: 32));
    expect(restored.route!.shape, hasLength(3));
    expect(restored.route!.shape.first.$1, closeTo(46.52, 1e-9));
    expect(restored.route!.shape.last.$2, closeTo(6.65, 1e-9));
    expect(restored.route!.maneuvers, hasLength(2));
    expect(restored.route!.maneuvers.first.instruction, 'Prenez à gauche');
    expect(restored.route!.maneuvers.last.beginShapeIndex, 1);
  });

  test('departure is optional (live GPS departure is not pinned)', () async {
    await store().save(ActiveRoute(
        route: _route(),
        destination: const (46.54, 6.65),
        profile: RoutingProfile.walk));

    final restored = await store().load();
    expect(restored!.departure, isNull);
    expect(restored.profile, RoutingProfile.walk);
  });

  test('clear removes the persisted route', () async {
    final s = store();
    await s.save(_activeRoute());
    await s.clear();
    expect(await s.load(), isNull);
  });

  test('clear on a never-saved route is a no-op', () async {
    await store().clear();
    expect(await store().load(), isNull);
  });

  test('a corrupt file loads as null instead of throwing', () async {
    final file = File('${dir.path}/active_route.json');
    await file.writeAsString('{not json at all');
    expect(await store().load(), isNull);
  });

  test('a document with nothing planned in it loads as null', () async {
    final file = File('${dir.path}/active_route.json');
    await file.writeAsString(jsonEncode({'profile': 'walk'}));
    expect(await store().load(), isNull);
  });

  test('a departure picked before any destination is persisted on its own',
      () async {
    // The map lets the user pin a custom departure first; losing it on a tab
    // switch is the same bug as losing the route, just smaller.
    await store().save(const ActiveRoute(
        departure: (46.52, 6.63), profile: RoutingProfile.walk));

    final restored = await store().load();
    expect(restored!.departure, const (46.52, 6.63));
    expect(restored.route, isNull);
    expect(restored.destination, isNull);
  });

  test('saving an empty plan removes the document', () async {
    final s = store();
    await s.save(_activeRoute());
    await s.save(const ActiveRoute(profile: RoutingProfile.walk));
    expect(await s.load(), isNull);
  });

  test('save creates the parent directory when it does not exist yet', () async {
    final nested = FileActiveRouteStore(
        File('${dir.path}/deep/deeper/active_route.json'));
    await nested.save(_activeRoute());
    expect(await nested.load(), isNotNull);
  });

  test('save leaves no temp file behind (atomic replace)', () async {
    await store().save(_activeRoute());
    final leftovers = dir
        .listSync()
        .map((e) => e.path.split(Platform.pathSeparator).last)
        .toList();
    expect(leftovers, ['active_route.json']);
  });

  test('overwriting a saved route replaces it entirely', () async {
    final s = store();
    await s.save(_activeRoute());
    await s.save(ActiveRoute(
        route: _route(),
        destination: const (47.0, 7.0),
        profile: RoutingProfile.walk));

    final restored = await s.load();
    expect(restored!.destination, const (47.0, 7.0));
    expect(restored.departure, isNull);
    expect(restored.profile, RoutingProfile.walk);
  });
}
