import 'models.dart';

abstract class RoutingEngine {
  Future<void> init(String tileDirPath);
  Future<RouteResult> route(RouteRequest request);
  Future<RouteResult> routeMulti(MultiPointRouteRequest request);

  /// Runs a Valhalla `trace_attributes` request (map-matching, M4
  /// exploration) supplied as raw JSON and returns the raw JSON response —
  /// deliberately low-level, like [route]'s native counterpart, so callers
  /// (`exploration/matcher.dart`) build and parse the request/response shape
  /// themselves rather than this interface growing a typed trace model.
  Future<String> trace(String requestJson);
}

class RoutingException implements Exception {
  final String message;
  const RoutingException(this.message);
  @override
  String toString() => 'RoutingException: $message';
}
