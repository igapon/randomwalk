import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/nav/polyline_math.dart';

void main() {
  // Segment ~nord-sud de 111 m à Lausanne, puis virage est.
  final shape = <(double, double)>[
    (46.5200, 6.6300),
    (46.5210, 6.6300), // ~111 m
    (46.5210, 6.6315), // ~115 m vers l'est
  ];
  final g = RouteGeometry(shape);

  test('cumulative distances are monotonic and total is coherent', () {
    expect(g.cumulativeKm.first, 0);
    expect(g.cumulativeKm.length, shape.length);
    expect(g.totalKm, closeTo(0.226, 0.01));
  });

  test('point beside the first segment projects onto it', () {
    // 46.5205,6.6302 : à mi-hauteur du segment 0, ~15 m à l'est
    final p = projectOntoRoute(g, 46.5205, 6.6302);
    expect(p.segmentIndex, 0);
    expect(p.t, closeTo(0.5, 0.05));
    expect(p.crossTrackM, closeTo(15, 3));
    expect(p.alongKm, closeTo(0.0555, 0.005));
  });

  test('point past the end clamps to the last vertex', () {
    final p = projectOntoRoute(g, 46.5210, 6.6320);
    expect(p.segmentIndex, 1);
    expect(p.t, 1.0);
    expect(p.alongKm, closeTo(g.totalKm, 1e-9));
  });

  test('searchFrom biases forward on overlapping return paths', () {
    // Boucle aller-retour sur le même tronçon : projeté près du départ,
    // mais searchFrom force la seconde passe.
    final loop = RouteGeometry([
      (46.5200, 6.6300),
      (46.5210, 6.6300),
      (46.5200, 6.6300),
    ]);
    final back = projectOntoRoute(loop, 46.52045, 6.63005, searchFrom: 1);
    expect(back.segmentIndex, 1);
  });
}
