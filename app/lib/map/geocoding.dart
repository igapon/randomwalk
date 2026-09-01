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

/// Thrown when a geocoding lookup could not be completed (offline, HTTP
/// error, malformed response, ...). Kept distinct from "zero results" so the
/// UI can show a dedicated offline/error message instead of an empty list.
class GeocodingException implements Exception {
  final String message;
  const GeocodingException(this.message);
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
}

/// [GeocodingService] backed by the public Photon API (komoot.io). Kept
/// behind [GeocodingService] so a self-hosted instance can replace it later
/// without touching callers.
class PhotonGeocodingService implements GeocodingService {
  final http.Client client;
  PhotonGeocodingService({required this.client});

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
      resp = await client.get(uri);
    } catch (e) {
      throw GeocodingException('network error: $e');
    }
    if (resp.statusCode != 200) {
      throw GeocodingException('HTTP ${resp.statusCode}');
    }
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      throw GeocodingException('malformed response: $e');
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
