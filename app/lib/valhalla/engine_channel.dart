import 'dart:convert';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/services.dart';
import 'engine.dart';
import 'models.dart';

/// Every top-level `assets/valhalla_config.json` module that carries its own
/// `logging` block — patched by [quietenLoggingForRelease] rather than
/// listed once in the asset itself, since debug/release want different
/// verbosity from the exact same template (see that function's doc
/// comment).
const _kLoggedModules = ['mjolnir', 'loki', 'thor', 'odin', 'meili'];

/// Item 7: `assets/valhalla_config.json` ships every module's `logging.type`
/// set to `"std_out"` — useful during development (surfaces native routing
/// errors in `adb logcat`) but unwanted noise, and pure overhead, once a
/// build actually ships. Rather than maintain two near-identical config
/// assets, the one template is patched at [ChannelRoutingEngine.init] time:
/// release silences every module's logging (`type: ""`, which Valhalla's
/// `midgard::logging::Configure` treats as "no sink configured" — neither
/// `std_out` nor `std_err` matches), debug leaves the template's own
/// `std_out` alone. The `integration` CI job runs under `flutter test`,
/// where `kReleaseMode` is always false — it constructs the real native
/// engine from this patched config and so verifies the *pipeline* (a
/// well-formed config reaches `Valhalla`'s constructor end to end), but
/// never actually exercises the `release: true` branch; that branch is
/// covered only by [quietenLoggingForRelease]'s own direct unit test.
///
/// Kept as a standalone, synchronous, side-effect-free function (rather than
/// inlined into [ChannelRoutingEngine.init]) specifically so it is testable
/// without needing to fake `kReleaseMode` itself, which is a compile-time
/// constant this process cannot flip at test time.
void quietenLoggingForRelease(
  Map<String, dynamic> config, {
  required bool release,
}) {
  if (!release) return;
  for (final module in _kLoggedModules) {
    final section = config[module] as Map<String, dynamic>?;
    final logging = section?['logging'] as Map<String, dynamic>?;
    if (logging == null) continue;
    logging['type'] = '';
  }
}

class ChannelRoutingEngine implements RoutingEngine {
  static const _channel = MethodChannel('randomwalk/valhalla');

  @override
  Future<void> init(String tileDirPath) async {
    final template = await rootBundle.loadString('assets/valhalla_config.json');
    final config = jsonDecode(template) as Map<String, dynamic>;
    (config['mjolnir'] as Map<String, dynamic>)['tile_dir'] = tileDirPath;
    (config['mjolnir'] as Map<String, dynamic>).remove('tile_extract');
    // `mjolnir.max_cache_size` (268 MiB in the template) — like every other
    // per-module cache size in this config — is a budget *per actor*, not a
    // single pool shared app-wide: each `ValhallaChannel`/native `Valhalla`
    // instance gets its own (see ValhallaChannel.kt's doc comment — one per
    // attached Flutter engine, so up to two concurrently: the UI engine and,
    // during active navigation, the background tracking engine). Bumping it
    // without accounting for that doubles worst-case memory, not just this
    // one engine's.
    quietenLoggingForRelease(config, release: kReleaseMode);
    try {
      await _channel.invokeMethod<String>('init', {
        'configJson': jsonEncode(config),
      });
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
      final resp = await _channel.invokeMethod<String>('route', {
        'request': request.toValhallaJson(),
      });
      if (resp == null) {
        throw RoutingException('empty engine reply');
      }
      return RouteResult.fromValhallaJson(
        jsonDecode(resp) as Map<String, dynamic>,
      );
    } on PlatformException catch (e) {
      throw RoutingException(e.message ?? 'route failed');
    } on MissingPluginException {
      throw RoutingException('route failed: no native engine registered');
    }
  }

  @override
  Future<RouteResult> routeMulti(MultiPointRouteRequest request) async {
    try {
      final resp = await _channel.invokeMethod<String>('route', {
        'request': request.toValhallaJson(),
      });
      if (resp == null) {
        throw RoutingException('empty engine reply');
      }
      return RouteResult.fromValhallaJson(
        jsonDecode(resp) as Map<String, dynamic>,
      );
    } on PlatformException catch (e) {
      throw RoutingException(e.message ?? 'route failed');
    } on MissingPluginException {
      throw RoutingException('route failed: no native engine registered');
    }
  }

  @override
  Future<String> trace(String requestJson) async {
    try {
      final resp = await _channel.invokeMethod<String>('trace', {
        'request': requestJson,
      });
      if (resp == null) {
        throw RoutingException('empty engine reply');
      }
      return resp;
    } on PlatformException catch (e) {
      throw RoutingException(e.message ?? 'trace failed');
    } on MissingPluginException {
      throw RoutingException('trace failed: no native engine registered');
    }
  }
}
