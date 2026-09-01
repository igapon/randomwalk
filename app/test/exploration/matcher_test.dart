import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/exploration/matcher.dart';
import 'package:randomwalk/valhalla/engine.dart';
import 'package:randomwalk/valhalla/models.dart';

class FakeTraceEngine implements RoutingEngine {
  String? lastRequestJson;
  String? reply;
  Object? failure;

  @override
  Future<void> init(String tileDirPath) async {}

  @override
  Future<RouteResult> route(RouteRequest request) => throw UnimplementedError();

  @override
  Future<RouteResult> routeMulti(MultiPointRouteRequest request) =>
      throw UnimplementedError();

  @override
  Future<String> trace(String requestJson) async {
    lastRequestJson = requestJson;
    final f = failure;
    if (f != null) throw f;
    return reply!;
  }
}

void main() {
  late FakeTraceEngine engine;

  setUp(() {
    engine = FakeTraceEngine();
  });

  const shape = [(46.52, 6.63), (46.521, 6.631), (46.522, 6.632)];

  group('request shape', () {
    test(
      'sends pedestrian costing, map_snap and a way_id/length filter',
      () async {
        engine.reply = jsonEncode({'edges': <dynamic>[]});
        await matchTrace(engine, shape);

        final sent =
            jsonDecode(engine.lastRequestJson!) as Map<String, dynamic>;
        expect(sent['costing'], 'pedestrian');
        expect(sent['shape_match'], 'map_snap');
        expect(sent['filters'], {
          'attributes': ['edge.way_id', 'edge.length'],
          'action': 'include',
        });
        expect(sent['shape'], [
          {'lat': 46.52, 'lon': 6.63},
          {'lat': 46.521, 'lon': 6.631},
          {'lat': 46.522, 'lon': 6.632},
        ]);
      },
    );

    test('a shape shorter than 2 points never reaches the engine', () async {
      final result = await matchTrace(engine, const [(46.52, 6.63)]);
      expect(result, isNull);
      expect(engine.lastRequestJson, isNull);
    });

    test('an empty shape never reaches the engine', () async {
      final result = await matchTrace(engine, const []);
      expect(result, isNull);
      expect(engine.lastRequestJson, isNull);
    });
  });

  group('response parsing', () {
    test('extracts way ids (as strings) and sums matched length', () async {
      engine.reply = jsonEncode({
        'edges': [
          {'way_id': 41174896, 'length': 0.033},
          {'way_id': 41174897, 'length': 0.212},
          {'way_id': 41174896, 'length': 0.05},
        ],
      });

      final result = await matchTrace(engine, shape);

      expect(result, isNotNull);
      expect(result!.wayIds, ['41174896', '41174897', '41174896']);
      expect(result.matchedKm, closeTo(0.295, 1e-9));
    });

    test('an edge with no way_id contributes length but no id', () async {
      engine.reply = jsonEncode({
        'edges': [
          {'length': 0.1},
          {'way_id': 5, 'length': 0.2},
        ],
      });

      final result = await matchTrace(engine, shape);

      expect(result!.wayIds, ['5']);
      expect(result.matchedKm, closeTo(0.3, 1e-9));
    });

    test('a response with no edges at all returns null', () async {
      engine.reply = jsonEncode({'shape': 'abc'});
      final result = await matchTrace(engine, shape);
      expect(result, isNull);
    });

    test('an empty edges array yields an empty, non-null result', () async {
      engine.reply = jsonEncode({'edges': <dynamic>[]});
      final result = await matchTrace(engine, shape);
      expect(result, isNotNull);
      expect(result!.wayIds, isEmpty);
      expect(result.matchedKm, 0.0);
    });
  });

  group('failure handling', () {
    test(
      'a RoutingException from the engine yields null, never throws',
      () async {
        engine.failure = const RoutingException('no route');
        final result = await matchTrace(engine, shape);
        expect(result, isNull);
      },
    );

    test('malformed JSON from the engine yields null, never throws', () async {
      engine.reply = 'not json at all {{{';
      final result = await matchTrace(engine, shape);
      expect(result, isNull);
    });

    test(
      'a JSON array instead of an object yields null, never throws',
      () async {
        engine.reply = jsonEncode([1, 2, 3]);
        final result = await matchTrace(engine, shape);
        expect(result, isNull);
      },
    );
  });
}
