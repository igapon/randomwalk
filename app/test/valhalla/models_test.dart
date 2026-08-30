import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/valhalla/models.dart';

void main() {
  test('decodePolyline6 round-trips a known point pair', () {
    // encodage polyline précision 6 de [(46.52, 6.63), (46.521, 6.631)]
    final pts = decodePolyline6(encodePolyline6ForTest([
      (46.52, 6.63),
      (46.521, 6.631),
    ]));
    expect(pts.length, 2);
    expect(pts[0].$1, closeTo(46.52, 1e-6));
    expect(pts[1].$2, closeTo(6.631, 1e-6));
  });

  test('RouteResult parses a valhalla trip json', () {
    final j = jsonDecode('''
    {"trip":{"summary":{"length":1.234,"time":900},
      "legs":[{"shape":"${encodePolyline6ForTest([(46.52, 6.63), (46.53, 6.64)])}",
        "maneuvers":[{"instruction":"Marchez vers le nord.","length":1.234,"begin_shape_index":0}]}]}}
    ''') as Map<String, dynamic>;
    final r = RouteResult.fromValhallaJson(j);
    expect(r.distanceKm, closeTo(1.234, 1e-9));
    expect(r.duration, const Duration(seconds: 900));
    expect(r.shape.first.$1, closeTo(46.52, 1e-6));
    expect(r.maneuvers.single.instruction, contains('nord'));
  });
}
