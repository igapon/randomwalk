import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:randomwalk/map/geocoding.dart';

void main() {
  Map<String, dynamic> featureCollection(List<Map<String, dynamic>> features) =>
      {'type': 'FeatureCollection', 'features': features};

  Map<String, dynamic> feature({
    required double lon,
    required double lat,
    Map<String, dynamic>? properties,
  }) => {
    'type': 'Feature',
    'geometry': {
      'type': 'Point',
      'coordinates': [lon, lat],
    },
    'properties': properties ?? {},
  };

  test('parses features into GeocodeResult with correct lat/lon order '
      '(GeoJSON stores [lon, lat]) and a readable French label', () async {
    final client = MockClient(
      (req) async => http.Response(
        jsonEncode(
          featureCollection([
            feature(
              lon: 6.6323,
              lat: 46.5197,
              properties: {
                'name': 'Cathédrale de Lausanne',
                'street': 'Place de la Cathédrale',
                'housenumber': '1',
                'postcode': '1005',
                'city': 'Lausanne',
                'country': 'Suisse',
              },
            ),
          ]),
        ),
        200,
      ),
    );
    final service = PhotonGeocodingService(client: client);
    final results = await service.search('cathédrale');
    expect(results, hasLength(1));
    expect(results.first.lat, 46.5197);
    expect(results.first.lon, 6.6323);
    expect(
      results.first.label,
      'Cathédrale de Lausanne, 1 Place de la Cathédrale, '
      '1005 Lausanne, Suisse',
    );
  });

  test(
    'skips a feature with no usable coordinates instead of throwing',
    () async {
      final client = MockClient(
        (req) async => http.Response(
          jsonEncode(
            featureCollection([
              {'type': 'Feature', 'properties': {}, 'geometry': null},
            ]),
          ),
          200,
        ),
      );
      final service = PhotonGeocodingService(client: client);
      final results = await service.search('x');
      expect(results, isEmpty);
    },
  );

  test(
    'includes lat/lon bias query params only when nearLat/nearLon given',
    () async {
      Uri? withBias;
      Uri? withoutBias;
      final client = MockClient((req) async {
        if (req.url.queryParameters.containsKey('lat')) {
          withBias = req.url;
        } else {
          withoutBias = req.url;
        }
        return http.Response(jsonEncode(featureCollection([])), 200);
      });
      final service = PhotonGeocodingService(client: client);
      await service.search('paix', nearLat: 46.52, nearLon: 6.63);
      await service.search('paix');
      expect(withBias!.queryParameters['lat'], '46.52');
      expect(withBias!.queryParameters['lon'], '6.63');
      expect(withoutBias!.queryParameters.containsKey('lat'), isFalse);
      expect(withoutBias!.queryParameters.containsKey('lon'), isFalse);
    },
  );

  test(
    'non-200 HTTP response is surfaced as GeocodingException, not a crash',
    () async {
      final client = MockClient((req) async => http.Response('boom', 500));
      final service = PhotonGeocodingService(client: client);
      expect(service.search('x'), throwsA(isA<GeocodingException>()));
    },
  );

  test('network failure (offline) is surfaced as GeocodingException', () async {
    final client = MockClient(
      (req) async => throw const SocketException('offline'),
    );
    final service = PhotonGeocodingService(client: client);
    expect(service.search('x'), throwsA(isA<GeocodingException>()));
  });

  group('task 2b — failure classification', () {
    test('a SocketException is classified offline', () async {
      final client = MockClient(
        (req) async => throw const SocketException('offline'),
      );
      final service = PhotonGeocodingService(client: client);
      await expectLater(
        service.search('x'),
        throwsA(
          isA<GeocodingException>().having(
            (e) => e.kind,
            'kind',
            GeocodingFailureKind.offline,
          ),
        ),
      );
    });

    test('a hung connection times out and is classified offline', () async {
      final client = MockClient((req) => Completer<http.Response>().future);
      final service = PhotonGeocodingService(
        client: client,
        timeout: const Duration(milliseconds: 10),
      );
      await expectLater(
        service.search('x'),
        throwsA(
          isA<GeocodingException>().having(
            (e) => e.kind,
            'kind',
            GeocodingFailureKind.offline,
          ),
        ),
      );
    });

    test(
      '429 is classified server, with the status code in the message',
      () async {
        final client = MockClient(
          (req) async => http.Response('rate limited', 429),
        );
        final service = PhotonGeocodingService(client: client);
        await expectLater(
          service.search('x'),
          throwsA(
            isA<GeocodingException>()
                .having((e) => e.kind, 'kind', GeocodingFailureKind.server)
                .having((e) => e.message, 'message', contains('429')),
          ),
        );
      },
    );

    test('invalid JSON is classified invalid', () async {
      final client = MockClient(
        (req) async => http.Response('not json at all {{{', 200),
      );
      final service = PhotonGeocodingService(client: client);
      await expectLater(
        service.search('x'),
        throwsA(
          isA<GeocodingException>().having(
            (e) => e.kind,
            'kind',
            GeocodingFailureKind.invalid,
          ),
        ),
      );
    });

    test('search() sends the RandomWalk User-Agent header', () async {
      String? seenUserAgent;
      final client = MockClient((req) async {
        seenUserAgent = req.headers['User-Agent'];
        return http.Response(jsonEncode(featureCollection([])), 200);
      });
      final service = PhotonGeocodingService(client: client);
      await service.search('x');
      expect(seenUserAgent, GeocodingConfig.userAgent);
    });
  });

  group('task 2b — searchErrorMessage', () {
    test('maps each kind to the expected French message', () {
      expect(
        searchErrorMessage(GeocodingFailureKind.offline),
        'Recherche indisponible hors ligne.',
      );
      expect(
        searchErrorMessage(GeocodingFailureKind.server),
        'Service de recherche momentanément indisponible. Réessaie dans un instant.',
      );
      expect(
        searchErrorMessage(GeocodingFailureKind.invalid),
        'Réponse inattendue du service de recherche.',
      );
    });
  });
}
