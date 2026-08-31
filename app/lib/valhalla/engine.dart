import 'models.dart';

abstract class RoutingEngine {
  Future<void> init(String tileDirPath);
  Future<RouteResult> route(RouteRequest request);
  Future<RouteResult> routeMulti(MultiPointRouteRequest request);
}

class RoutingException implements Exception {
  final String message;
  const RoutingException(this.message);
  @override
  String toString() => 'RoutingException: $message';
}
