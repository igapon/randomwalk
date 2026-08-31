import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/map/replan_line.dart';

void main() {
  group('decideReplanLineSync', () {
    test('not route-bound is always none, regardless of what is drawn', () {
      expect(
        decideReplanLineSync(
          isRouteBound: false,
          currentShapeEnc: 'abc',
          lastDrawnShapeEnc: null,
        ),
        ReplanLineSync.none,
      );
      expect(
        decideReplanLineSync(
          isRouteBound: false,
          currentShapeEnc: null,
          lastDrawnShapeEnc: 'abc',
        ),
        ReplanLineSync.none,
      );
    });

    test('the same shape already drawn is none', () {
      expect(
        decideReplanLineSync(
          isRouteBound: true,
          currentShapeEnc: 'abc',
          lastDrawnShapeEnc: 'abc',
        ),
        ReplanLineSync.none,
      );
    });

    test('neither replanned nor previously drawn is none', () {
      expect(
        decideReplanLineSync(
          isRouteBound: true,
          currentShapeEnc: null,
          lastDrawnShapeEnc: null,
        ),
        ReplanLineSync.none,
      );
    });

    test('a new replanned shape is redraw', () {
      expect(
        decideReplanLineSync(
          isRouteBound: true,
          currentShapeEnc: 'new-shape',
          lastDrawnShapeEnc: null,
        ),
        ReplanLineSync.redraw,
      );
    });

    test('a different replanned shape than what is drawn is redraw', () {
      expect(
        decideReplanLineSync(
          isRouteBound: true,
          currentShapeEnc: 'shape-b',
          lastDrawnShapeEnc: 'shape-a',
        ),
        ReplanLineSync.redraw,
      );
    });

    test(
        'the regression this exists for: a fresh/resumed trip with no '
        'replan of its own, but a previous replanned line still drawn, is '
        'restoreBase — not silently none', () {
      expect(
        decideReplanLineSync(
          isRouteBound: true,
          currentShapeEnc: null,
          lastDrawnShapeEnc: 'dead-trip-shape',
        ),
        ReplanLineSync.restoreBase,
      );
    });
  });
}
