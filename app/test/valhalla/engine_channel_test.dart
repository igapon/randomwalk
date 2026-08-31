import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/valhalla/engine.dart';
import 'package:randomwalk/valhalla/engine_channel.dart';
import 'package:randomwalk/valhalla/models.dart';

/// `flutter test` runs with the package root (`app/`) as the working
/// directory, so the asset is reachable directly off disk — no need for the
/// `rootBundle`/`AssetManifest` machinery `ChannelRoutingEngine.init` uses
/// at runtime, which is already covered by the `configJson` sent to the
/// mocked channel in the `init()` group above.
const rawTemplatePath = 'assets/valhalla_config.json';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('randomwalk/valhalla');
  const request = RouteRequest(
      fromLat: 46.52, fromLon: 6.63, toLat: 46.53, toLon: 6.64,
      profile: RoutingProfile.walk);

  void setHandler(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('route()', () {
    test('a null native reply raises RoutingException("empty engine reply")',
        () async {
      setHandler((call) async => null);
      final engine = ChannelRoutingEngine();
      await expectLater(
          engine.route(request),
          throwsA(isA<RoutingException>().having(
              (e) => e.message, 'message', 'empty engine reply')));
    });

    test('a PlatformException is wrapped as RoutingException', () async {
      setHandler((call) async =>
          throw PlatformException(code: 'VALHALLA', message: 'no route'));
      final engine = ChannelRoutingEngine();
      await expectLater(
          engine.route(request),
          throwsA(isA<RoutingException>()
              .having((e) => e.message, 'message', 'no route')));
    });

    test('MissingPluginException (no native engine registered) is wrapped as '
        'RoutingException instead of crashing', () async {
      // No handler registered at all -> MissingPluginException.
      final engine = ChannelRoutingEngine();
      await expectLater(engine.route(request), throwsA(isA<RoutingException>()));
    });
  });

  group('trace()', () {
    test('a null native reply raises RoutingException("empty engine reply")',
        () async {
      setHandler((call) async => null);
      final engine = ChannelRoutingEngine();
      await expectLater(
          engine.trace('{"shape":[]}'),
          throwsA(isA<RoutingException>().having(
              (e) => e.message, 'message', 'empty engine reply')));
    });

    test('a PlatformException is wrapped as RoutingException', () async {
      setHandler((call) async =>
          throw PlatformException(code: 'VALHALLA', message: 'no match'));
      final engine = ChannelRoutingEngine();
      await expectLater(
          engine.trace('{"shape":[]}'),
          throwsA(isA<RoutingException>()
              .having((e) => e.message, 'message', 'no match')));
    });

    test('MissingPluginException (no native engine registered) is wrapped as '
        'RoutingException instead of crashing', () async {
      // No handler registered at all -> MissingPluginException.
      final engine = ChannelRoutingEngine();
      await expectLater(
          engine.trace('{"shape":[]}'), throwsA(isA<RoutingException>()));
    });

    test('the raw request is forwarded to the "trace" method verbatim and '
        'the raw reply is returned unparsed', () async {
      String? method;
      Object? sentRequest;
      setHandler((call) async {
        method = call.method;
        sentRequest = call.arguments['request'];
        return '{"edges":[{"way_id":1,"length":0.1}]}';
      });
      final engine = ChannelRoutingEngine();
      final result = await engine.trace('{"shape":[{"lat":1,"lon":2}]}');
      expect(method, 'trace');
      expect(sentRequest, '{"shape":[{"lat":1,"lon":2}]}');
      expect(result, '{"edges":[{"way_id":1,"length":0.1}]}');
    });
  });

  group('init()', () {
    test('MissingPluginException on init is wrapped as RoutingException',
        () async {
      // No handler registered at all -> MissingPluginException.
      final engine = ChannelRoutingEngine();
      await expectLater(
          engine.init('/tiles/V1'), throwsA(isA<RoutingException>()));
    });

    test('a PlatformException on init is wrapped as RoutingException',
        () async {
      setHandler((call) async =>
          throw PlatformException(code: 'VALHALLA', message: 'bad config'));
      final engine = ChannelRoutingEngine();
      await expectLater(
          engine.init('/tiles/V1'),
          throwsA(isA<RoutingException>()
              .having((e) => e.message, 'message', 'bad config')));
    });

    test(
        'the config sent to the native side keeps std_out logging outside '
        'release (item 7) — flutter test never runs kReleaseMode==true',
        () async {
      String? sentConfigJson;
      setHandler((call) async {
        sentConfigJson = call.arguments['configJson'] as String;
        return 'ok';
      });
      final engine = ChannelRoutingEngine();
      await engine.init('/tiles/V1');

      final sent = jsonDecode(sentConfigJson!) as Map<String, dynamic>;
      expect((sent['mjolnir'] as Map)['logging']['type'], 'std_out');
      expect((sent['loki'] as Map)['logging']['type'], 'std_out');
    });
  });

  group('quietenLoggingForRelease (item 7)', () {
    Map<String, dynamic> template() =>
        jsonDecode(File(rawTemplatePath).readAsStringSync())
            as Map<String, dynamic>;

    test('a non-release config is left untouched', () {
      final config = template();
      quietenLoggingForRelease(config, release: false);
      expect((config['mjolnir'] as Map)['logging']['type'], 'std_out');
      expect((config['loki'] as Map)['logging']['type'], 'std_out');
      expect((config['thor'] as Map)['logging']['type'], 'std_out');
      expect((config['odin'] as Map)['logging']['type'], 'std_out');
      expect((config['meili'] as Map)['logging']['type'], 'std_out');
    });

    test('a release config silences every module\'s logging', () {
      final config = template();
      quietenLoggingForRelease(config, release: true);
      for (final module in ['mjolnir', 'loki', 'thor', 'odin', 'meili']) {
        expect((config[module] as Map)['logging']['type'], '',
            reason: '$module.logging.type');
      }
    });

    test('a module with no logging block is left alone rather than crashing',
        () {
      final config = <String, dynamic>{'mjolnir': <String, dynamic>{}};
      expect(() => quietenLoggingForRelease(config, release: true),
          returnsNormally);
    });
  });

  group('routeMulti()', () {
    test('a null native reply raises RoutingException("empty engine reply")',
        () async {
      setHandler((call) async => null);
      final multiRequest = MultiPointRouteRequest(
        locations: const [(46.52, 6.63), (46.53, 6.64), (46.54, 6.65)],
        profile: RoutingProfile.walk,
      );
      final engine = ChannelRoutingEngine();
      await expectLater(
          engine.routeMulti(multiRequest),
          throwsA(isA<RoutingException>().having(
              (e) => e.message, 'message', 'empty engine reply')));
    });

    test('a PlatformException is wrapped as RoutingException', () async {
      setHandler((call) async =>
          throw PlatformException(code: 'VALHALLA', message: 'no route'));
      final multiRequest = MultiPointRouteRequest(
        locations: const [(46.52, 6.63), (46.53, 6.64), (46.54, 6.65)],
        profile: RoutingProfile.walk,
      );
      final engine = ChannelRoutingEngine();
      await expectLater(
          engine.routeMulti(multiRequest),
          throwsA(isA<RoutingException>()
              .having((e) => e.message, 'message', 'no route')));
    });

    test('MissingPluginException (no native engine registered) is wrapped as '
        'RoutingException instead of crashing', () async {
      // No handler registered at all -> MissingPluginException.
      final multiRequest = MultiPointRouteRequest(
        locations: const [(46.52, 6.63), (46.53, 6.64), (46.54, 6.65)],
        profile: RoutingProfile.walk,
      );
      final engine = ChannelRoutingEngine();
      await expectLater(
          engine.routeMulti(multiRequest), throwsA(isA<RoutingException>()));
    });
  });
}
