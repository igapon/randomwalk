import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/valhalla/engine.dart';
import 'package:randomwalk/valhalla/engine_channel.dart';
import 'package:randomwalk/valhalla/models.dart';

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
