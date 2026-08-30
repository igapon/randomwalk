import 'dart:async';
import 'dart:math' show Point;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'geocoding.dart';
import 'latest_only.dart';
import 'route_controller.dart';
import '../valhalla/engine.dart';
import '../valhalla/models.dart';

const kMapStyleUrl = 'https://tiles.openfreemap.org/styles/liberty';
const kMapAttribution = 'OpenFreeMap © OpenMapTiles, Data from OpenStreetMap';

const _kLocationDeniedMessage =
    'Localisation refusée — activez-la dans les réglages.';
const _kPositionUnavailableMessage =
    'Position indisponible — activez la localisation ou définissez un départ manuel.';

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});
  @override
  ConsumerState<MapScreen> createState() => MapScreenState();
}

class MapScreenState extends ConsumerState<MapScreen> {
  MapLibreMapController? controller;

  // Departure defaults to the live GPS position; [_departureOverride] is set
  // only after the user explicitly picks a custom departure (see
  // [_armSetDeparture]).
  LatLng? _departureOverride;
  Circle? _departureMarker;

  LatLng? _destination;
  Circle? _destinationMarker;

  Line? _routeLine;
  RoutingProfile _profile = RoutingProfile.walk;
  RouteResult? _result;
  bool _planning = false;
  ({int done, int total})? _downloadProgress;

  /// One-shot: armed by the "Modifier le départ" action, consumed by the
  /// next long-press, which then sets the departure instead of the
  /// destination.
  bool _armSetDeparture = false;

  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  final _searchGeneration = LatestOnly();
  List<GeocodeResult> _searchResults = [];
  String? _searchError;
  bool _searching = false;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// Resolves the live GPS position, or `null` if it isn't available for
  /// any reason: permission denied, location services turned off system-
  /// wide (as opposed to just app permission), or the platform call itself
  /// failing/timing out. Callers treat `null` uniformly — see
  /// [_kLocationDeniedMessage] / [_kPositionUnavailableMessage].
  Future<LatLng?> _currentPositionOrNull() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }
    try {
      final pos = await Geolocator.getCurrentPosition();
      return LatLng(pos.latitude, pos.longitude);
    } on LocationServiceDisabledException {
      // Services can be switched off in the gap between the check above
      // and this call; treat it the same as the up-front check.
      return null;
    } on TimeoutException {
      return null;
    }
  }

  Future<void> _centerOnUser() async {
    final pos = await _currentPositionOrNull();
    if (pos == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text(_kLocationDeniedMessage)));
      }
      return;
    }
    await controller?.animateCamera(CameraUpdate.newLatLngZoom(pos, 15));
  }

  Future<void> _onMapLongClick(Point<double> point, LatLng coords) async {
    if (_armSetDeparture) {
      _armSetDeparture = false;
      await _setDeparture(coords);
      if (_destination != null) await _planRoute();
      return;
    }
    await _setDestination(coords);
    await _planRoute();
  }

  Future<void> _setDeparture(LatLng coords) async {
    final old = _departureMarker;
    final marker = await controller?.addCircle(CircleOptions(
        geometry: coords,
        circleRadius: 8,
        circleColor: '#0D9488',
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 2));
    if (old != null) await controller?.removeCircle(old);
    if (!mounted) return;
    setState(() {
      _departureOverride = coords;
      _departureMarker = marker;
    });
  }

  Future<void> _setDestination(LatLng coords) async {
    final old = _destinationMarker;
    final marker = await controller?.addCircle(CircleOptions(
        geometry: coords,
        circleRadius: 8,
        circleColor: '#DC2626',
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 2));
    if (old != null) await controller?.removeCircle(old);
    if (!mounted) return;
    setState(() {
      _destination = coords;
      _destinationMarker = marker;
    });
  }

  Future<void> _clearRoute() async {
    final line = _routeLine;
    final departureMarker = _departureMarker;
    final destinationMarker = _destinationMarker;
    if (line != null) await controller?.removeLine(line);
    if (departureMarker != null) await controller?.removeCircle(departureMarker);
    if (destinationMarker != null) await controller?.removeCircle(destinationMarker);
    if (!mounted) return;
    setState(() {
      _routeLine = null;
      _departureOverride = null;
      _departureMarker = null;
      _destination = null;
      _destinationMarker = null;
      _result = null;
      _armSetDeparture = false;
    });
  }

  void _armDepartureChange() {
    setState(() => _armSetDeparture = true);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Appui long sur la carte pour choisir le nouveau départ.')));
  }

  Future<void> _planRoute() async {
    final destination = _destination;
    if (destination == null) return;
    final departure = _departureOverride ?? await _currentPositionOrNull();
    if (!mounted) return;
    if (departure == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(_kPositionUnavailableMessage)));
      return;
    }
    setState(() {
      _planning = true;
      _downloadProgress = null;
      _result = null;
    });
    final sink = ref.read(progressSinkProvider);
    sink.onProgress = (done, total) {
      if (!mounted) return;
      setState(() => _downloadProgress = (done: done, total: total));
    };
    try {
      final planner = await ref.read(routePlannerProvider.future);
      final result = await planner.plan(RouteRequest(
          fromLat: departure.latitude,
          fromLon: departure.longitude,
          toLat: destination.latitude,
          toLon: destination.longitude,
          profile: _profile));
      final oldLine = _routeLine;
      final newLine = await controller?.addLine(LineOptions(
          geometry: [for (final (lat, lon) in result.shape) LatLng(lat, lon)],
          lineColor: '#0D9488',
          lineWidth: 5));
      if (oldLine != null) await controller?.removeLine(oldLine);
      if (!mounted) return;
      setState(() {
        _routeLine = newLine;
        _result = result;
      });
    } on RoutingException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Itinéraire impossible ici — zone non couverte ?')));
      }
    } finally {
      sink.onProgress = null;
      if (mounted) {
        setState(() {
          _planning = false;
          _downloadProgress = null;
        });
      }
    }
  }

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      // Bump the generation too: if a search for a previous query is still
      // in flight, its response must not repopulate results the user just
      // cleared.
      _searchGeneration.start();
      setState(() {
        _searchResults = [];
        _searchError = null;
        _searching = false;
      });
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 400), () => _runSearch(query));
  }

  Future<void> _runSearch(String query) async {
    // Tag this call with a generation token so that, if a newer search
    // starts before this one's HTTP response comes back, the stale result
    // is dropped instead of clobbering what the newer call already showed
    // (or is still loading).
    final gen = _searchGeneration.start();
    if (!mounted) return;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    final service = ref.read(geocodingServiceProvider);
    final near = _departureOverride;
    try {
      final results = await service.search(query,
          nearLat: near?.latitude, nearLon: near?.longitude);
      if (!mounted || !_searchGeneration.isCurrent(gen)) return;
      setState(() {
        _searchResults = results;
        _searching = false;
      });
    } on GeocodingException {
      if (!mounted || !_searchGeneration.isCurrent(gen)) return;
      setState(() {
        _searchResults = [];
        _searching = false;
        _searchError = 'Recherche indisponible hors ligne.';
      });
    }
  }

  Future<void> _selectSearchResult(GeocodeResult result) async {
    final coords = LatLng(result.lat, result.lon);
    _searchController.clear();
    // Invalidate any still-in-flight search for a previous keystroke so its
    // response can't repopulate the list after the user already picked one.
    _searchGeneration.start();
    setState(() {
      _searchResults = [];
      _searchError = null;
    });
    FocusScope.of(context).unfocus();
    await _setDestination(coords);
    await controller?.animateCamera(CameraUpdate.newLatLng(coords));
    await _planRoute();
  }

  String _formatResult(RouteResult r) {
    final km = r.distanceKm.toStringAsFixed(1).replaceAll('.', ',');
    final min = (r.duration.inSeconds / 60).round();
    return '$km km · ~$min min';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    return Scaffold(
      body: Stack(
        children: [
          MapLibreMap(
            styleString: kMapStyleUrl,
            initialCameraPosition:
                const CameraPosition(target: LatLng(46.52, 6.63), zoom: 11),
            myLocationEnabled: true,
            myLocationTrackingMode: MyLocationTrackingMode.none,
            attributionButtonPosition: AttributionButtonPosition.bottomLeft,
            onMapCreated: (c) => controller = c,
            onMapLongClick: _onMapLongClick,
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Column(
                  children: [
                    _SearchBar(
                      controller: _searchController,
                      onChanged: _onSearchChanged,
                    ),
                    if (_searching || _searchError != null || _searchResults.isNotEmpty)
                      _SearchResultsPanel(
                        searching: _searching,
                        error: _searchError,
                        results: _searchResults,
                        onSelect: _selectSearchResult,
                        maxHeight: MediaQuery.of(context).size.height * 0.5,
                      ),
                    const SizedBox(height: 12),
                    SegmentedButton<RoutingProfile>(
                      segments: const [
                        ButtonSegment(
                            value: RoutingProfile.walk,
                            label: Text('Marche'),
                            icon: Icon(Icons.directions_walk)),
                        ButtonSegment(
                            value: RoutingProfile.bike,
                            label: Text('Vélo'),
                            icon: Icon(Icons.directions_bike)),
                      ],
                      selected: {_profile},
                      onSelectionChanged: (s) {
                        setState(() => _profile = s.first);
                        if (_destination != null) _planRoute();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_planning)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Padding(
                padding: EdgeInsets.only(
                    left: 16, right: 16, bottom: bottomInset + 16),
                child: _ProgressBanner(progress: _downloadProgress),
              ),
            )
          else if (_result != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Padding(
                padding: EdgeInsets.only(
                    left: 16, right: 16, bottom: bottomInset + 16),
                child: _ResultBanner(
                  text: _formatResult(_result!),
                  onChangeDeparture: _armDepartureChange,
                  onClear: _clearRoute,
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _centerOnUser,
        child: const Icon(Icons.my_location),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(28),
        child: TextField(
          controller: controller,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: 'Rechercher une adresse…',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
            filled: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(28),
              borderSide: BorderSide.none,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      );
}

class _SearchResultsPanel extends StatelessWidget {
  const _SearchResultsPanel({
    required this.searching,
    required this.error,
    required this.results,
    required this.onSelect,
    required this.maxHeight,
  });
  final bool searching;
  final String? error;
  final List<GeocodeResult> results;
  final ValueChanged<GeocodeResult> onSelect;
  final double maxHeight;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 4),
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Material(
          elevation: 2,
          borderRadius: BorderRadius.circular(12),
          child: searching
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))),
                )
              : error != null
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(error!),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: results.length,
                      itemBuilder: (context, i) => ListTile(
                        leading: const Icon(Icons.place_outlined),
                        title: Text(results[i].label),
                        onTap: () => onSelect(results[i]),
                      ),
                    ),
        ),
      );
}

class _ProgressBanner extends StatelessWidget {
  const _ProgressBanner({required this.progress});
  final ({int done, int total})? progress;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    final label = (p != null && p.total > 0)
        ? 'Téléchargement des cartes… ${p.done}/${p.total}'
        : 'Téléchargement des cartes…';
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    );
  }
}

class _ResultBanner extends StatelessWidget {
  const _ResultBanner({
    required this.text,
    required this.onChangeDeparture,
    required this.onClear,
  });
  final String text;
  final VoidCallback onChangeDeparture;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Material(
        elevation: 3,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(text,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
              TextButton(
                onPressed: onChangeDeparture,
                child: const Text('Modifier le départ'),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: onClear,
                tooltip: 'Effacer l\'itinéraire',
              ),
            ],
          ),
        ),
      );
}
