import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// One geocoded address suggestion.
class GeocodeResult {
  final String label;
  final double lat;
  final double lon;
  const GeocodeResult({
    required this.label,
    required this.lat,
    required this.lon,
  });
}

/// Why a [GeocodingException] happened — task 2b, owner device-QA: the map
/// screen used to show the same "indisponible hors ligne" message for every
/// failure (a 403/429 from Photon's public instance, a malformed response, a
/// hung connection...), which read as flatly wrong whenever the device
/// actually was online. See `searchErrorMessage` (bottom of this file) for
/// the French message each kind maps to.
enum GeocodingFailureKind {
  /// No usable connection reached the server at all: a `SocketException`,
  /// any other network-level failure, or the request timing out (see
  /// [GeocodingConfig.searchTimeout]) — indistinguishable, from the
  /// walker's point of view, from "no network".
  offline,

  /// The server was reached but answered with a non-200 status — most
  /// commonly Photon's public instance rate-limiting (429) or rejecting
  /// (403) a request with no identifying `User-Agent` (see
  /// [GeocodingConfig.userAgent]), which is the most likely actual cause of
  /// the "hors ligne" report despite the device being online.
  server,

  /// A 200 response whose body did not parse as the expected JSON shape.
  invalid,
}

/// Thrown when a geocoding lookup could not be completed (offline, HTTP
/// error, malformed response, ...). Kept distinct from "zero results" so the
/// UI can show a dedicated offline/error message instead of an empty list.
class GeocodingException implements Exception {
  final String message;
  final GeocodingFailureKind kind;
  const GeocodingException(
    this.message, {
    this.kind = GeocodingFailureKind.server,
  });
  @override
  String toString() => 'GeocodingException: $message';
}

abstract class GeocodingService {
  /// Searches for addresses matching [query]. [nearLat]/[nearLon], when
  /// given, bias results towards that location (typically the user's
  /// current position).
  Future<List<GeocodeResult>> search(
    String query, {
    double? nearLat,
    double? nearLon,
  });
}

class GeocodingConfig {
  static const endpoint = 'https://photon.komoot.io/api/';

  /// Photon's public instance requires an identifying `User-Agent` and
  /// frequently 403s/429s Dart's own default one — task 2b, owner device-QA:
  /// this was the actual root cause of "indisponible hors ligne" showing up
  /// while the device was online.
  static const userAgent =
      'RandomWalk/1.0 (+https://github.com/igapon/randomwalk)';

  /// Total budget for one search call. Unbounded before task 2b: a hung
  /// connection left the search spinner running forever.
  static const searchTimeout = Duration(seconds: 8);
}

/// [GeocodingService] backed by the public Photon API (komoot.io). Kept
/// behind [GeocodingService] so a self-hosted instance can replace it later
/// without touching callers.
class PhotonGeocodingService implements GeocodingService {
  final http.Client client;

  /// [GeocodingConfig.searchTimeout] by default — overridable so a test can
  /// exercise the timeout path (a fake client whose response never
  /// completes) without actually waiting out the real 8 s budget. This file
  /// imports neither `maplibre_gl` nor anything that pulls in the
  /// virtual-clock test binding, so a plain `.timeout()` is safe here (see
  /// `initial_camera.dart`'s doc comment for the case where it is not).
  final Duration timeout;

  PhotonGeocodingService({
    required this.client,
    this.timeout = GeocodingConfig.searchTimeout,
  });

  @override
  Future<List<GeocodeResult>> search(
    String query, {
    double? nearLat,
    double? nearLon,
  }) async {
    final uri = Uri.parse(GeocodingConfig.endpoint).replace(
      queryParameters: {
        'q': query,
        'lang': 'fr',
        'limit': '6',
        if (nearLat != null) 'lat': '$nearLat',
        if (nearLon != null) 'lon': '$nearLon',
      },
    );
    http.Response resp;
    try {
      resp = await client
          .get(uri, headers: const {'User-Agent': GeocodingConfig.userAgent})
          .timeout(timeout);
    } catch (e) {
      // Covers SocketException, TimeoutException (from the .timeout() above)
      // and any other network-level failure (e.g. http.ClientException) —
      // none of these reached a server response, so they all read as
      // "offline" to the walker (brief item 1a).
      throw GeocodingException(
        'network error: $e',
        kind: GeocodingFailureKind.offline,
      );
    }
    if (resp.statusCode != 200) {
      throw GeocodingException(
        'HTTP ${resp.statusCode}',
        kind: GeocodingFailureKind.server,
      );
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      throw GeocodingException(
        'malformed response: $e',
        kind: GeocodingFailureKind.invalid,
      );
    }
    final features = body['features'] as List<dynamic>? ?? [];
    final results = <GeocodeResult>[];
    for (final f in features) {
      final r = _toResult(f as Map<String, dynamic>);
      if (r != null) results.add(r);
    }
    return results;
  }

  GeocodeResult? _toResult(Map<String, dynamic> feature) {
    final geometry = feature['geometry'] as Map<String, dynamic>?;
    final coords = geometry?['coordinates'] as List<dynamic>?;
    if (coords == null || coords.length < 2) return null;
    final lon = (coords[0] as num).toDouble();
    final lat = (coords[1] as num).toDouble();
    final props = feature['properties'] as Map<String, dynamic>? ?? {};
    return GeocodeResult(label: _composeLabel(props), lat: lat, lon: lon);
  }

  /// Composes a readable French-ish label, e.g.
  /// "Cathédrale de Lausanne, 1 Place de la Cathédrale, 1005 Lausanne, Suisse".
  String _composeLabel(Map<String, dynamic> p) {
    String? str(String key) {
      final v = p[key];
      return (v is String && v.isNotEmpty) ? v : null;
    }

    final name = str('name');
    final street = [
      str('housenumber'),
      str('street'),
    ].whereType<String>().join(' ');
    final city = [str('postcode'), str('city')].whereType<String>().join(' ');
    final country = str('country');
    final parts = <String>[
      if (name != null) name,
      if (street.isNotEmpty && street != name) street,
      if (city.isNotEmpty) city,
      if (country != null) country,
    ];
    return parts.isEmpty ? 'Adresse inconnue' : parts.join(', ');
  }
}

/// Maps a [GeocodingFailureKind] to the exact French message the search bar
/// shows (task 2b brief item 1c) — pulled out of `map_screen.dart`'s
/// `_runSearch` so the mapping is unit-testable without a widget test.
String searchErrorMessage(GeocodingFailureKind kind) => switch (kind) {
  GeocodingFailureKind.offline => 'Recherche indisponible hors ligne.',
  GeocodingFailureKind.server =>
    'Service de recherche momentanément indisponible. Réessaie dans un instant.',
  GeocodingFailureKind.invalid => 'Réponse inattendue du service de recherche.',
};
