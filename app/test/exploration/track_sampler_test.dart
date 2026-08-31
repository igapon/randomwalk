import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/exploration/track_sampler.dart';

void main() {
  group('distance thinning', () {
    test('the first point is always kept', () {
      final sampler = TrackSampler();
      expect(sampler.add(46.52, 6.63), isTrue);
      expect(sampler.points, [(46.52, 6.63)]);
    });

    test('a point closer than minStepM to the last kept point is dropped',
        () {
      final sampler = TrackSampler(minStepM: 25);
      sampler.add(46.52, 6.63);
      // ~1 m east at this latitude — well under the 25 m threshold.
      final kept = sampler.add(46.52, 6.630012);
      expect(kept, isFalse);
      expect(sampler.length, 1);
    });

    test('a point at least minStepM away is kept', () {
      final sampler = TrackSampler(minStepM: 25);
      sampler.add(46.52, 6.63);
      // ~40 m north.
      final kept = sampler.add(46.5204, 6.63);
      expect(kept, isTrue);
      expect(sampler.length, 2);
    });

    test('rejected points do not move the "last kept point" reference', () {
      final sampler = TrackSampler(minStepM: 25);
      sampler.add(46.52, 6.63);
      sampler.add(46.52, 6.630005); // rejected, ~0.4 m
      sampler.add(46.52, 6.63001); // rejected relative to the ORIGINAL point
      // still under 25 m cumulative from the first point.
      expect(sampler.length, 1);
    });
  });

  group('bounded size', () {
    test('never exceeds maxPoints even when fed far more points than that',
        () {
      final sampler = TrackSampler(minStepM: 1, maxPoints: 10);
      // Each step is ~11 m north — always accepted (> 1 m minStepM).
      var lat = 46.5;
      for (var i = 0; i < 100; i++) {
        lat += 0.0001;
        sampler.add(lat, 6.63);
      }
      expect(sampler.length, lessThanOrEqualTo(10));
    });

    test('thinning keeps the first point and preserves overall order', () {
      final sampler = TrackSampler(minStepM: 1, maxPoints: 4);
      var lat = 46.5;
      final fed = <(double, double)>[];
      for (var i = 0; i < 20; i++) {
        lat += 0.0001;
        sampler.add(lat, 6.63);
        fed.add((lat, 6.63));
      }
      expect(sampler.points.first, fed.first);
      // Strictly increasing latitude throughout confirms no reordering
      // happened during thinning.
      for (var i = 1; i < sampler.points.length; i++) {
        expect(sampler.points[i].$1, greaterThan(sampler.points[i - 1].$1));
      }
    });
  });

  group('seed()', () {
    test('adds a point without applying the distance filter', () {
      final sampler = TrackSampler(minStepM: 1000);
      sampler.seed(46.52, 6.63);
      sampler.seed(46.520001, 6.630001); // well under 1000 m
      expect(sampler.length, 2);
    });

    test('still respects maxPoints via thinning', () {
      final sampler = TrackSampler(minStepM: 1000, maxPoints: 4);
      for (var i = 0; i < 20; i++) {
        sampler.seed(46.5 + i * 0.0001, 6.63);
      }
      expect(sampler.length, lessThanOrEqualTo(4));
    });
  });
}
