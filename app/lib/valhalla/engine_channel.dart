import 'dart:convert';
import 'package:flutter/services.dart';
import 'engine.dart';
import 'models.dart';

class ChannelRoutingEngine implements RoutingEngine {
  static const _channel = MethodChannel('randomwalk/valhalla');

  @override
  Future<void> init(String tileDirPath) async {
    final template = await rootBundle.loadString('assets/valhalla_config.json');
    final config = jsonDecode(template) as Map<String, dynamic>;
    (config['mjolnir'] as Map<String, dynamic>)['tile_dir'] = tileDirPath;
    (config['mjolnir'] as Map<String, dynamic>).remove('tile_extract');
    try {
      await _channel.invokeMethod<String>('init', {'configJson': jsonEncode(config)});
    } on PlatformException catch (e) {
      throw RoutingException(e.message ?? 'init failed');
    } on MissingPluginException {
      // No native implementation registered for the channel (e.g. running
      // on a platform/test harness without it) — same user-facing outcome
      // as any other engine failure, not an uncaught crash.
      throw RoutingException('init failed: no native engine registered');
    }
  }

  @override
  Future<RouteResult> route(RouteRequest request) async {
    try {
      final resp = await _channel
          .invokeMethod<String>('route', {'request': request.toValhallaJson()});
      if (resp == null) {
        throw RoutingException('empty engine reply');
      }
      return RouteResult.fromValhallaJson(
          jsonDecode(resp) as Map<String, dynamic>);
    } on PlatformException catch (e) {
      throw RoutingException(e.message ?? 'route failed');
    } on MissingPluginException {
      throw RoutingException('route failed: no native engine registered');
    }
  }

  @override
  Future<RouteResult> routeMulti(MultiPointRouteRequest request) async {
    try {
      final resp = await _channel
          .invokeMethod<String>('route', {'request': request.toValhallaJson()});
      if (resp == null) {
        throw RoutingException('empty engine reply');
      }
      return RouteResult.fromValhallaJson(
          jsonDecode(resp) as Map<String, dynamic>);
    } on PlatformException catch (e) {
      throw RoutingException(e.message ?? 'route failed');
    } on MissingPluginException {
      throw RoutingException('route failed: no native engine registered');
    }
  }
}
