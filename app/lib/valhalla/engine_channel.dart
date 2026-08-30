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
    }
  }

  @override
  Future<RouteResult> route(RouteRequest request) async {
    try {
      final resp = await _channel
          .invokeMethod<String>('route', {'request': request.toValhallaJson()});
      return RouteResult.fromValhallaJson(
          jsonDecode(resp!) as Map<String, dynamic>);
    } on PlatformException catch (e) {
      throw RoutingException(e.message ?? 'route failed');
    }
  }
}
