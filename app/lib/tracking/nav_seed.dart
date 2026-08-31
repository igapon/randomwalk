import '../valhalla/models.dart';

/// Everything the tracking isolate needs to navigate, handed over when the
/// service starts.
///
/// Separate from [TripSnapshot] on purpose: the snapshot is rewritten every
/// couple of seconds and read by the UI, while this is written once and read
/// once, by the service, and carries a whole serialized route. It is also
/// the part of the handover the *service* owns — the UI cannot recompute a
/// route for a walker who has since gone offline, so the route, where they
/// are going, how they are travelling and which tiles to route against all
/// have to cross the isolate boundary up front.
class NavSeed {
  /// The planned route, in full: shape *and* maneuvers, which is what makes
  /// a `RouteFollower` constructible on the far side.
  final RouteResult route;

  /// Where the trip is going, so a replan has a destination to route to.
  /// Taken from the user's picked destination when there is one, and from
  /// the route's own last point otherwise.
  final double destLat, destLon;
  final RoutingProfile profile;

  /// The offline tile directory a service-side replan routes against.
  ///
  /// Null when no dataset could be resolved — navigation still runs (the
  /// follower needs no engine), it simply cannot recalculate. The service
  /// never downloads tiles: there is no UI in it to show progress, and a
  /// walker who has gone off-route is exactly the walker least likely to
  /// have connectivity.
  final String? tileDirPath;

  const NavSeed({
    required this.route,
    required this.destLat,
    required this.destLon,
    required this.profile,
    required this.tileDirPath,
  });

  Map<String, dynamic> toJson() => {
        'route': route.toJson(),
        'destLat': destLat,
        'destLon': destLon,
        'profile': profile.name,
        if (tileDirPath != null) 'tileDirPath': tileDirPath,
      };

  factory NavSeed.fromJson(Map<String, dynamic> j) => NavSeed(
        route: RouteResult.fromJson(j['route'] as Map<String, dynamic>),
        destLat: (j['destLat'] as num).toDouble(),
        destLon: (j['destLon'] as num).toDouble(),
        profile: RoutingProfile.values.firstWhere((p) => p.name == j['profile'],
            orElse: () => RoutingProfile.walk),
        tileDirPath: j['tileDirPath'] as String?,
      );
}
