import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/valhalla/models.dart';

void main() {
  test('decodePolyline6 round-trips a known point pair', () {
    // encodage polyline précision 6 de [(46.52, 6.63), (46.521, 6.631)]
    final pts = decodePolyline6(encodePolyline6([
      (46.52, 6.63),
      (46.521, 6.631),
    ]));
    expect(pts.length, 2);
    expect(pts[0].$1, closeTo(46.52, 1e-6));
    expect(pts[1].$2, closeTo(6.631, 1e-6));
  });

  test('decodePolyline6 matches an independently computed golden vector', () {
    // Points are Google's own canonical polyline-algorithm example
    // (https://developers.google.com/maps/documentation/utilities/polylinealgorithm),
    // normally shown encoded at precision 5 as "_p~iF~ps|U_ulLnnqC_mqNvxq`@".
    // Valhalla encodes shapes at precision 6, so the string below was produced by
    // a standalone Node.js re-implementation of the algorithm (not by this file's
    // encodePolyline6 — a round trip through the same encoder can't catch a
    // symmetric sign/shift bug). That Node script was cross-checked by re-encoding
    // these exact points at precision 5, which reproduced Google's canonical
    // string above byte for byte, before it was used to compute the precision-6
    // string here.
    const encoded = '_izlhA~rlgdF_{geC~ywl@_kwzCn`{nI';
    final pts = decodePolyline6(encoded);
    expect(pts.length, 3);
    expect(pts[0].$1, closeTo(38.5, 1e-6));
    expect(pts[0].$2, closeTo(-120.2, 1e-6));
    expect(pts[1].$1, closeTo(40.7, 1e-6));
    expect(pts[1].$2, closeTo(-120.95, 1e-6));
    expect(pts[2].$1, closeTo(43.252, 1e-6));
    expect(pts[2].$2, closeTo(-126.453, 1e-6));
  });

  test('decodePolyline6 handles negative deltas (independent golden vector)',
      () {
    // Same standalone Node.js encoder as above (not encodePolyline6),
    // for a point pair that forces a negative delta on both lat and lon —
    // the case a same-sign round trip would never exercise.
    const encoded = '_c`|@_c`|@~fayB~tpzA';
    final pts = decodePolyline6(encoded);
    expect(pts.length, 2);
    expect(pts[0].$1, closeTo(1.0, 1e-6));
    expect(pts[0].$2, closeTo(1.0, 1e-6));
    expect(pts[1].$1, closeTo(-1.0, 1e-6));
    expect(pts[1].$2, closeTo(-0.5, 1e-6));
  });

  test('RouteResult parses a valhalla trip json', () {
    final j = jsonDecode('''
    {"trip":{"summary":{"length":1.234,"time":900},
      "legs":[{"shape":"${encodePolyline6([(46.52, 6.63), (46.53, 6.64)])}",
        "maneuvers":[{"instruction":"Marchez vers le nord.","length":1.234,"begin_shape_index":0}]}]}}
    ''') as Map<String, dynamic>;
    final r = RouteResult.fromValhallaJson(j);
    expect(r.distanceKm, closeTo(1.234, 1e-9));
    expect(r.duration, const Duration(seconds: 900));
    expect(r.shape.first.$1, closeTo(46.52, 1e-6));
    expect(r.maneuvers.single.instruction, contains('nord'));
  });

  test('RouteResult round-trips through its own JSON', () {
    // The form the foreground service is seeded with (see `NavSeed`) and the
    // one `ActiveRouteStore` persists: everything `RouteFollower` needs must
    // survive it, maneuvers and shape precision included.
    final original = RouteResult(
      shape: const [(46.52, 6.63), (46.521, 6.631), (46.5225, 6.6335)],
      distanceKm: 1.234,
      duration: const Duration(seconds: 900),
      maneuvers: const [
        Maneuver(
            instruction: 'Marchez vers le nord.',
            lengthKm: 0.8,
            beginShapeIndex: 0),
        Maneuver(
            instruction: 'Vous êtes arrivé.',
            lengthKm: 0.434,
            beginShapeIndex: 2),
      ],
    );

    final restored =
        RouteResult.fromJson(jsonDecode(jsonEncode(original.toJson())));

    expect(restored.distanceKm, closeTo(1.234, 1e-9));
    expect(restored.duration, const Duration(seconds: 900));
    expect(restored.shape, hasLength(3));
    for (var i = 0; i < original.shape.length; i++) {
      expect(restored.shape[i].$1, closeTo(original.shape[i].$1, 1e-6));
      expect(restored.shape[i].$2, closeTo(original.shape[i].$2, 1e-6));
    }
    expect(restored.maneuvers, hasLength(2));
    expect(restored.maneuvers.last.instruction, 'Vous êtes arrivé.');
    expect(restored.maneuvers.last.lengthKm, closeTo(0.434, 1e-9));
    expect(restored.maneuvers.last.beginShapeIndex, 2);
  });

  group('RouteRequest.toValhallaJson', () {
    const request = RouteRequest(
        fromLat: 46.52,
        fromLon: 6.63,
        toLat: 46.53,
        toLon: 6.64,
        profile: RoutingProfile.walk);

    test('walk profile costs pedestrian', () {
      final j = jsonDecode(request.toValhallaJson()) as Map<String, dynamic>;
      expect(j['costing'], 'pedestrian');
    });

    test('bike profile costs bicycle', () {
      final bikeRequest = const RouteRequest(
          fromLat: 46.52,
          fromLon: 6.63,
          toLat: 46.53,
          toLon: 6.64,
          profile: RoutingProfile.bike);
      final j =
          jsonDecode(bikeRequest.toValhallaJson()) as Map<String, dynamic>;
      expect(j['costing'], 'bicycle');
    });

    test('directions_options set units kilometers and language fr-FR', () {
      final j = jsonDecode(request.toValhallaJson()) as Map<String, dynamic>;
      final options = j['directions_options'] as Map<String, dynamic>;
      expect(options['units'], 'kilometers');
      expect(options['language'], 'fr-FR');
    });

    test('locations are ordered from/to with type break', () {
      final j = jsonDecode(request.toValhallaJson()) as Map<String, dynamic>;
      final locations = j['locations'] as List<dynamic>;
      expect(locations, hasLength(2));
      final from = locations[0] as Map<String, dynamic>;
      final to = locations[1] as Map<String, dynamic>;
      expect(from['lat'], 46.52);
      expect(from['lon'], 6.63);
      expect(from['type'], 'break');
      expect(to['lat'], 46.53);
      expect(to['lon'], 6.64);
      expect(to['type'], 'break');
    });
  });

  group('MultiPointRouteRequest.toValhallaJson', () {
    test('4-location request with bicycle costing and correct types', () {
      final request = MultiPointRouteRequest(
        locations: const [
          (46.52, 6.63),
          (46.525, 6.635),
          (46.53, 6.64),
          (46.535, 6.645),
        ],
        profile: RoutingProfile.bike,
      );

      final j = jsonDecode(request.toValhallaJson()) as Map<String, dynamic>;

      // Check costing
      expect(j['costing'], 'bicycle');

      // Check directions_options
      final options = j['directions_options'] as Map<String, dynamic>;
      expect(options['units'], 'kilometers');
      expect(options['language'], 'fr-FR');

      // Check locations: first and last are 'break', middle are 'through'
      final locations = j['locations'] as List<dynamic>;
      expect(locations, hasLength(4));

      final loc0 = locations[0] as Map<String, dynamic>;
      expect(loc0['lat'], 46.52);
      expect(loc0['lon'], 6.63);
      expect(loc0['type'], 'break');

      final loc1 = locations[1] as Map<String, dynamic>;
      expect(loc1['lat'], 46.525);
      expect(loc1['lon'], 6.635);
      expect(loc1['type'], 'through');

      final loc2 = locations[2] as Map<String, dynamic>;
      expect(loc2['lat'], 46.53);
      expect(loc2['lon'], 6.64);
      expect(loc2['type'], 'through');

      final loc3 = locations[3] as Map<String, dynamic>;
      expect(loc3['lat'], 46.535);
      expect(loc3['lon'], 6.645);
      expect(loc3['type'], 'break');
    });

    test('requires at least 2 locations', () {
      expect(
        () => MultiPointRouteRequest(
          locations: const [(46.52, 6.63)],
          profile: RoutingProfile.walk,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('RouteResult.fromValhallaJson with single leg and multiple waypoints', () {
    test('parses single-leg response with multiple through-waypoint maneuvers '
        'and correct global shape indices', () {
      // Realistic: MultiPointRouteRequest produces a single leg because
      // Valhalla splits legs only at break/break_through boundaries.
      // The shape traverses through several waypoints, and maneuvers occur
      // at different positions within that single leg.
      final legShape = encodePolyline6([
        (46.52, 6.63),
        (46.521, 6.631),
        (46.522, 6.632),
        (46.53, 6.64),
        (46.535, 6.645),
      ]);

      final j = jsonDecode('''
      {"trip":{"summary":{"length":2.5,"time":900},
        "legs":[
          {"shape":"$legShape",
            "maneuvers":[
              {"instruction":"Partez nord-est.","length":1.0,"begin_shape_index":0},
              {"instruction":"Continuez tout droit.","length":0.8,"begin_shape_index":2},
              {"instruction":"Vous êtes arrivé.","length":0.7,"begin_shape_index":4}
            ]}
        ]}}
      ''') as Map<String, dynamic>;

      final r = RouteResult.fromValhallaJson(j);

      // Verify totals
      expect(r.distanceKm, closeTo(2.5, 1e-9));
      expect(r.duration, const Duration(seconds: 900));

      // Verify shape from single leg (5 points)
      expect(r.shape, hasLength(5));
      expect(r.shape.first.$1, closeTo(46.52, 1e-6));
      expect(r.shape.last.$1, closeTo(46.535, 1e-6));

      // Verify maneuvers with globally consistent indices (no leg offset added)
      expect(r.maneuvers, hasLength(3));

      expect(r.maneuvers[0].instruction, 'Partez nord-est.');
      expect(r.maneuvers[0].beginShapeIndex, 0);

      expect(r.maneuvers[1].instruction, 'Continuez tout droit.');
      expect(r.maneuvers[1].beginShapeIndex, 2);

      expect(r.maneuvers[2].instruction, 'Vous êtes arrivé.');
      expect(r.maneuvers[2].beginShapeIndex, 4);
    });
  });

  group('RouteResult.fromValhallaJson with multi-break responses', () {
    test('parses multi-break responses (not produced by MultiPointRouteRequest) '
        'with correct global shape indices across legs', () {
      // This tests the general multi-leg parsing machinery.
      // MultiPointRouteRequest does not produce multi-leg responses because
      // Valhalla only splits legs at explicit break boundaries.
      final leg1Shape = encodePolyline6([(46.52, 6.63), (46.521, 6.631)]);
      final leg2Shape = encodePolyline6([(46.521, 6.631), (46.53, 6.64)]);
      final leg3Shape = encodePolyline6([(46.53, 6.64), (46.535, 6.645)]);

      final j = jsonDecode('''
      {"trip":{"summary":{"length":3.0,"time":2700},
        "legs":[
          {"shape":"$leg1Shape",
            "maneuvers":[{"instruction":"Allez nord.","length":1.0,"begin_shape_index":0}]},
          {"shape":"$leg2Shape",
            "maneuvers":[{"instruction":"Tournez gauche.","length":1.0,"begin_shape_index":0}]},
          {"shape":"$leg3Shape",
            "maneuvers":[{"instruction":"Vous arrivez.","length":1.0,"begin_shape_index":0}]}
        ]}}
      ''') as Map<String, dynamic>;

      final r = RouteResult.fromValhallaJson(j);

      // Verify total distance and duration
      expect(r.distanceKm, closeTo(3.0, 1e-9));
      expect(r.duration, const Duration(seconds: 2700));

      // Verify combined shape (3 legs = 6 points total due to overlaps)
      expect(r.shape, hasLength(6));

      // Verify maneuvers: 3 total, with correct global beginShapeIndex offsets
      expect(r.maneuvers, hasLength(3));

      // First maneuver from leg 1 should start at shape index 0
      expect(r.maneuvers[0].instruction, 'Allez nord.');
      expect(r.maneuvers[0].beginShapeIndex, 0);

      // Second maneuver from leg 2 should start at shape index 2 (after leg 1's 2 points)
      expect(r.maneuvers[1].instruction, 'Tournez gauche.');
      expect(r.maneuvers[1].beginShapeIndex, 2);

      // Third maneuver from leg 3 should start at shape index 4 (after legs 1-2's 4 points)
      expect(r.maneuvers[2].instruction, 'Vous arrivez.');
      expect(r.maneuvers[2].beginShapeIndex, 4);
    });
  });
}
