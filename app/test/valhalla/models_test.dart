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
}
