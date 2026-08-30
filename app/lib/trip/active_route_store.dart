import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../valhalla/models.dart';

/// The planning state the map screen used to keep in its own `State`:
/// the computed [route], the [destination] the user picked, the optional
/// [departure] override (null means "wherever the live GPS says I am"), and
/// the routing [profile] it was computed for.
///
/// Lifted out of the widget so it survives a tab switch, a brightness flip
/// (which remounts the whole `MapLibreMap`), and — via [ActiveRouteStore] —
/// the process being killed while the app sits in the background.
class ActiveRoute {
  /// Null while the user has picked points but no route has been computed
  /// yet (or the computation failed).
  final RouteResult? route;
  final (double, double)? destination;
  final (double, double)? departure;
  final RoutingProfile profile;

  const ActiveRoute({
    this.route,
    this.destination,
    this.departure,
    required this.profile,
  });

  /// Nothing has been planned. Persisting this is the same as persisting
  /// nothing, and [ActiveRouteStore.load] never returns one.
  bool get isEmpty =>
      route == null && destination == null && departure == null;

  ActiveRoute copyWith({
    RouteResult? route,
    bool clearRoute = false,
    (double, double)? destination,
    (double, double)? departure,
    bool clearDeparture = false,
    RoutingProfile? profile,
  }) =>
      ActiveRoute(
        route: clearRoute ? null : (route ?? this.route),
        destination: destination ?? this.destination,
        departure: clearDeparture ? null : (departure ?? this.departure),
        profile: profile ?? this.profile,
      );

  Map<String, dynamic> toJson() => {
        if (route != null) 'route': route!.toJson(),
        if (destination != null)
          'destination': [destination!.$1, destination!.$2],
        if (departure != null) 'departure': [departure!.$1, departure!.$2],
        'profile': profile.name,
      };

  factory ActiveRoute.fromJson(Map<String, dynamic> j) {
    (double, double)? pair(Object? raw) {
      if (raw == null) return null;
      final list = raw as List<dynamic>;
      return ((list[0] as num).toDouble(), (list[1] as num).toDouble());
    }

    final route = j['route'];
    return ActiveRoute(
      route: route == null
          ? null
          : RouteResult.fromJson(route as Map<String, dynamic>),
      destination: pair(j['destination']),
      departure: pair(j['departure']),
      profile: RoutingProfile.values.firstWhere(
        (p) => p.name == j['profile'],
        orElse: () => RoutingProfile.walk,
      ),
    );
  }
}

/// Persistence seam for [ActiveRoute]. An interface (rather than a bare
/// class with a `File` in it) so `TripController` can be unit-tested without
/// touching the filesystem, and so a future backend — a database, or the
/// foreground service's own store — can be swapped in without touching the
/// controller.
abstract class ActiveRouteStore {
  Future<ActiveRoute?> load();
  Future<void> save(ActiveRoute route);
  Future<void> clear();
}

/// A JSON document in the app support directory.
///
/// Writes go through a `.tmp` sibling + rename so a process death mid-write
/// leaves the previous good document in place rather than a truncated one:
/// the file is read exactly once, at cold start, and a half-written document
/// there would silently lose the user's planned route.
class FileActiveRouteStore implements ActiveRouteStore {
  final File file;

  /// Serializes writes: the map screen saves on every planning change, and
  /// two overlapping `save`s racing on the same temp path would interleave.
  Future<void> _pending = Future.value();

  FileActiveRouteStore(this.file);

  @override
  Future<ActiveRoute?> load() async {
    try {
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final route =
          ActiveRoute.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      return route.isEmpty ? null : route;
      // A document we cannot read is indistinguishable, from the user's
      // point of view, from having planned nothing — and it must never take
      // the app down at startup, which is the only place `load` is called.
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> save(ActiveRoute route) {
    if (route.isEmpty) return clear();
    return _serialize(() async {
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(jsonEncode(route.toJson()), flush: true);
        await tmp.rename(file.path);
      });
  }

  @override
  Future<void> clear() => _serialize(() async {
        if (await file.exists()) await file.delete();
      });

  Future<void> _serialize(Future<void> Function() op) {
    final next = _pending.then((_) => op());
    // Swallow failures for the *chain*'s sake only — the returned future
    // still surfaces them to this caller.
    _pending = next.catchError((_) {});
    return next;
  }
}
