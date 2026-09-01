import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/exploration/track_sampler.dart';

void main() {
  group('distance thinning', () {
    test('the first point is always kept', () {
      final sampler = TrackSampler();
      expect(sampler.add(46.52, 6.63).kept, isTrue);
      expect(sampler.points, [(46.52, 6.63)]);
    });

    test('a point closer than minStepM to the last kept point is dropped', () {
      final sampler = TrackSampler(minStepM: 25);
      sampler.add(46.52, 6.63);
      // ~1 m east at this latitude — well under the 25 m threshold.
      final result = sampler.add(46.52, 6.630012);
      expect(result.kept, isFalse);
      expect(result.thinned, isFalse);
      expect(sampler.length, 1);
    });

    test('a point at least minStepM away is kept', () {
      final sampler = TrackSampler(minStepM: 25);
      sampler.add(46.52, 6.63);
      // ~40 m north.
      final result = sampler.add(46.5204, 6.63);
      expect(result.kept, isTrue);
      expect(result.thinned, isFalse);
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
    test('never exceeds maxPoints even when fed far more points than that', () {
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

    test('"thinned" is true on exactly the calls that halve the buffer, '
        'false on every other kept call', () {
      final sampler = TrackSampler(minStepM: 1, maxPoints: 4);
      var lat = 46.5;
      final thinnedFlags = <bool>[];
      for (var i = 0; i < 10; i++) {
        lat += 0.0001;
        thinnedFlags.add(sampler.add(lat, 6.63).thinned);
      }
      // Fills to 4 (points 1-4: never thinned), then hits the cap on point 5
      // (thinned: halves 4 -> 2, then adds -> 3), fills to 4 again by point
      // 6, hits the cap again on point 7, etc. -> thinned on points 5, 7, 9.
      expect(thinnedFlags, [
        false, false, false, false, // 1-4: room to spare
        true, // 5: cap hit, thin then add
        false, // 6: room again (3 -> 4)
        true, // 7: cap hit again
        false, // 8: room again
        true, // 9: cap hit again
        false, // 10: room again (3 -> 4)
      ]);
    });

    test('a rejected (too-close) point never reports thinned, even right at '
        'the cap', () {
      final sampler = TrackSampler(minStepM: 1000, maxPoints: 2);
      sampler.add(46.5, 6.63);
      sampler.add(46.51, 6.63); // far enough, kept, at cap now
      final result = sampler.add(46.510001, 6.63); // rejected: too close
      expect(result.kept, isFalse);
      expect(result.thinned, isFalse);
      expect(sampler.length, 2);
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
