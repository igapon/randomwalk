import 'dart:async';
import 'dart:math' show Point;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'geocoding.dart';
import 'latest_only.dart';
import 'route_controller.dart';
import '../theme/tokens.dart';
import '../theme/waymark_glyph.dart';
import '../trip/trip_controller.dart';
import '../valhalla/engine.dart';
import '../valhalla/models.dart';

const kMapStyleUrlLight = 'https://tiles.openfreemap.org/styles/liberty';
// OpenFreeMap's dark style — see task-12 brief: the map follows the app's
// brightness instead of always rendering the light "liberty" style.
const kMapStyleUrlDark = 'https://tiles.openfreemap.org/styles/dark';
const kMapAttribution = 'OpenFreeMap © OpenMapTiles, Data from OpenStreetMap';

/// Image ids registered once via [MapLibreMapController.addImage] — see
/// [_registerWaymarkIcons]. "A" (departure) is the contour variant, "B"
/// (destination) the filled one, matching the brief's "losange de
/// balisage" signature.
const _kIconMarkerA = 'waymark-marker-a';
const _kIconMarkerB = 'waymark-marker-b';
const _kWaymarkIconSizePx = 44.0;

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
  bool _iconsRegistered = false;

  // Departure defaults to the live GPS position; [_departureOverride] is set
  // only after the user explicitly picks a custom departure (see
  // [_armSetDeparture]).
  LatLng? _departureOverride;
  Symbol? _departureMarker;

  LatLng? _destination;
  Symbol? _destinationMarker;

  // Route line: a wide ink "casing" underneath a narrower yellow line on
  // top (two addLine calls — casing added first so it sits below).
  Line? _routeLineCasing;
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

  /// Refreshes the live stats banner (distance/duration) once a second
  /// while a trip is recording. TripController only notifies listeners on
  /// start/stop (see trip_controller.dart), not per GPS fix, so this is
  /// the same lightweight polling pattern session_screen.dart already used.
  Timer? _statsTicker;

  @override
  void initState() {
    super.initState();
    ref.read(tripControllerProvider).onCameraFollowChanged =
        _onCameraFollowChanged;
    _statsTicker =
        Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _statsTicker?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    final trip = ref.read(tripControllerProvider);
    if (trip.onCameraFollowChanged == _onCameraFollowChanged) {
      trip.onCameraFollowChanged = null;
    }
    super.dispose();
  }

  void _onCameraFollowChanged(bool follow) {
    controller?.updateMyLocationTrackingMode(
        follow ? MyLocationTrackingMode.tracking : MyLocationTrackingMode.none);
  }

  Future<void> _registerWaymarkIcons() async {
    if (_iconsRegistered || controller == null) return;
    _iconsRegistered = true;
    final contour = await waymarkDiamondPng(
        sizePx: _kWaymarkIconSizePx, color: AppColors.ink, filled: false, strokeWidth: 4);
    final filled = await waymarkDiamondPng(
        sizePx: _kWaymarkIconSizePx, color: AppColors.ink);
    await controller?.addImage(_kIconMarkerA, contour);
    await controller?.addImage(_kIconMarkerB, filled);
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
    await _registerWaymarkIcons();
    final old = _departureMarker;
    final marker = await controller?.addSymbol(SymbolOptions(
        geometry: coords,
        iconImage: _kIconMarkerA,
        iconSize: 1.0,
        iconAnchor: 'center'));
    if (old != null) await controller?.removeSymbol(old);
    if (!mounted) return;
    setState(() {
      _departureOverride = coords;
      _departureMarker = marker;
    });
  }

  Future<void> _setDestination(LatLng coords) async {
    await _registerWaymarkIcons();
    final old = _destinationMarker;
    final marker = await controller?.addSymbol(SymbolOptions(
        geometry: coords,
        iconImage: _kIconMarkerB,
        iconSize: 1.0,
        iconAnchor: 'center'));
    if (old != null) await controller?.removeSymbol(old);
    if (!mounted) return;
    setState(() {
      _destination = coords;
      _destinationMarker = marker;
    });
  }

  Future<void> _clearRoute() async {
    final casing = _routeLineCasing;
    final line = _routeLine;
    final departureMarker = _departureMarker;
    final destinationMarker = _destinationMarker;
    if (line != null) await controller?.removeLine(line);
    if (casing != null) await controller?.removeLine(casing);
    if (departureMarker != null) await controller?.removeSymbol(departureMarker);
    if (destinationMarker != null) await controller?.removeSymbol(destinationMarker);
    if (!mounted) return;
    setState(() {
      _routeLineCasing = null;
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
      final geometry = [for (final (lat, lon) in result.shape) LatLng(lat, lon)];
      // Casing first (drawn below), then the yellow line on top.
      final oldCasing = _routeLineCasing;
      final newCasing = await controller?.addLine(LineOptions(
          geometry: geometry,
          lineColor: '#1C2B25',
          lineWidth: 7,
          lineOpacity: 1.0));
      if (oldCasing != null) await controller?.removeLine(oldCasing);
      final oldLine = _routeLine;
      final newLine = await controller?.addLine(LineOptions(
          geometry: geometry, lineColor: '#F5B800', lineWidth: 4.5));
      if (oldLine != null) await controller?.removeLine(oldLine);
      if (!mounted) return;
      setState(() {
        _routeLineCasing = newCasing;
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

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    return hours > 0
        ? '${hours}h ${minutes.toString().padLeft(2, '0')}m'
        : '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }

  /// Starts a trip bound to the currently planned route: camera-follow is
  /// switched on by TripController via [_onCameraFollowChanged].
  Future<void> _startRouteTrip() async {
    final result = _result;
    if (result == null) return;
    final started = await ref.read(tripControllerProvider).startTrip(route: result);
    if (!started && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text(_kPositionUnavailableMessage)));
    }
  }

  /// One-tap start with no planned route: a minimal bottom sheet to pick
  /// (and remember) Marche/Vélo, then starts immediately.
  Future<void> _startFreeTrip() async {
    final profile = await showModalBottomSheet<RoutingProfile>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.card))),
      builder: (_) => const _ProfileSheet(),
    );
    if (profile == null || !mounted) return;
    final started =
        await ref.read(tripControllerProvider).startTrip(profile: profile);
    if (!started && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text(_kPositionUnavailableMessage)));
    }
  }

  Future<void> _stopTrip() async {
    await ref.read(tripControllerProvider).stopTrip();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    final trip = ref.watch(tripControllerProvider);
    final brightness = Theme.of(context).brightness;
    final styleUrl =
        brightness == Brightness.dark ? kMapStyleUrlDark : kMapStyleUrlLight;

    Widget? bottomBanner;
    if (_planning) {
      bottomBanner = _ProgressBanner(progress: _downloadProgress);
    } else if (trip.isRecording) {
      bottomBanner = _StatsBanner(
        distanceKm: trip.sessionController.recorder?.distanceKm ?? 0,
        elapsed: _formatDuration(trip.sessionController.elapsed),
        onStop: _stopTrip,
      );
    } else if (_result != null) {
      bottomBanner = _ResultBanner(
        text: _formatResult(_result!),
        onChangeDeparture: _armDepartureChange,
        onClear: _clearRoute,
        onStart: _startRouteTrip,
      );
    } else {
      bottomBanner = _StartPill(onStart: _startFreeTrip);
    }

    return Scaffold(
      body: Stack(
        children: [
          MapLibreMap(
            key: ValueKey(styleUrl),
            styleString: styleUrl,
            initialCameraPosition:
                const CameraPosition(target: LatLng(46.52, 6.63), zoom: 11),
            myLocationEnabled: true,
            myLocationTrackingMode: MyLocationTrackingMode.none,
            attributionButtonPosition: AttributionButtonPosition.bottomLeft,
            onMapCreated: (c) {
              // A brightness flip remounts this widget under a new
              // ValueKey(styleUrl) (MapLibre has no live style-swap in this
              // version) — the native map instance is fresh, so its symbol
              // icons need registering again too.
              controller = c;
              _iconsRegistered = false;
            },
            // addImage/addSymbol must wait for the style to finish loading
            // (see maplibre_map.dart's onStyleLoadedCallback doc).
            onStyleLoadedCallback: _registerWaymarkIcons,
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
                      onSelectionChanged: trip.isRecording
                          ? null
                          : (s) {
                              setState(() => _profile = s.first);
                              if (_destination != null) _planRoute();
                            },
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Anchored above the system nav insets (project rule), gesture
          // and 3-button navigation alike.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Padding(
              padding: EdgeInsets.only(left: 16, right: 16, bottom: bottomInset + 16),
              child: bottomBanner,
            ),
          ),
        ],
      ),
      floatingActionButton: Padding(
        // Lifted clear of the bottom banner/pill.
        padding: const EdgeInsets.only(bottom: 88),
        child: FloatingActionButton(
          onPressed: _centerOnUser,
          child: const Icon(Icons.my_location),
        ),
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
        borderRadius: BorderRadius.circular(AppRadii.stadium),
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
              borderRadius: BorderRadius.circular(AppRadii.stadium),
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
          borderRadius: BorderRadius.circular(AppRadii.card),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
          ],
        ),
      ),
    );
  }
}

/// Route result card (T9): the primary action is the yellow "Démarrer
/// l'itinéraire" pill (right), "✕" (clear) is secondary.
class _ResultBanner extends StatelessWidget {
  const _ResultBanner({
    required this.text,
    required this.onChangeDeparture,
    required this.onClear,
    required this.onStart,
  });
  final String text;
  final VoidCallback onChangeDeparture;
  final VoidCallback onClear;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(text, style: theme.textTheme.titleMedium),
                ),
                TextButton(
                  onPressed: onChangeDeparture,
                  child: const Text('Modifier le départ'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: onClear,
                  tooltip: 'Effacer l\'itinéraire',
                ),
                const SizedBox(width: 4),
                ElevatedButton.icon(
                  onPressed: onStart,
                  icon: const WaymarkDiamond(size: 12, color: Color(0xFF1C2B25)),
                  label: const Text('Démarrer l\'itinéraire'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Idle, no route planned: the plain one-tap "Démarrer" pill.
class _StartPill extends StatelessWidget {
  const _StartPill({required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: onStart,
          icon: const WaymarkDiamond(size: 14, color: Color(0xFF1C2B25)),
          label: const Text('Démarrer'),
        ),
      );
}

/// Recording: pill becomes "Terminer" (ink, paper text) alongside compact
/// live stats (distance / duration, Bricolage Grotesque numerals).
class _StatsBanner extends StatelessWidget {
  const _StatsBanner({
    required this.distanceKm,
    required this.elapsed,
    required this.onStop,
  });
  final double distanceKm;
  final String elapsed;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  _Stat(value: '${distanceKm.toStringAsFixed(2)} km', theme: theme),
                  const SizedBox(width: 20),
                  _Stat(value: elapsed, theme: theme),
                ],
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.onSurface,
                foregroundColor: theme.colorScheme.surface,
              ),
              onPressed: onStop,
              child: const Text('Terminer'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.theme});
  final String value;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) =>
      Text(value, style: theme.textTheme.headlineSmall);
}

/// Minimal profile picker for a route-less ("free") trip start — tapping
/// either option starts immediately (one-tap), no further confirmation.
class _ProfileSheet extends StatelessWidget {
  const _ProfileSheet();

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Démarrer un trajet', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () =>
                          Navigator.of(context).pop(RoutingProfile.walk),
                      icon: const Icon(Icons.directions_walk),
                      label: const Text('Marche'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () =>
                          Navigator.of(context).pop(RoutingProfile.bike),
                      icon: const Icon(Icons.directions_bike),
                      label: const Text('Vélo'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}
