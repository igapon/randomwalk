import 'dart:async';
import 'dart:io';
import 'dart:math' show Point;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'geocoding.dart';
import 'initial_camera.dart';
import 'latest_only.dart';
import 'nav_camera_state.dart';
import 'route_controller.dart';
import '../theme/tokens.dart';
import '../theme/waymark_glyph.dart';
import '../trip/active_route_store.dart';
import '../trip/gated_ticker.dart';
import '../trip/trip_controller.dart';
import '../trip/trip_messages.dart';
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

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});
  @override
  ConsumerState<MapScreen> createState() => MapScreenState();
}

class MapScreenState extends ConsumerState<MapScreen> {
  MapLibreMapController? controller;
  bool _iconsRegistered = false;

  // Native handles for what is currently drawn. These are the only pieces
  // of map state that legitimately live in the widget: they belong to one
  // native map instance and die with it. What they *represent* — the
  // planned route, its endpoints, the profile — lives in TripController,
  // which is what makes it survive a tab switch or a cold start.
  Symbol? _departureMarker;
  Symbol? _destinationMarker;
  Line? _routeLineCasing;
  Line? _routeLine;

  /// The plan the overlays above were drawn from, so [_syncOverlays] can
  /// tell "already drawn" from "needs redrawing" without diffing geometry.
  ActiveRoute? _drawn;
  bool _syncing = false;

  bool _planning = false;
  ({int done, int total})? _downloadProgress;

  /// Resolved once at startup — see [_resolveInitialCamera] — before the
  /// map is built at all: last-known position when there is one, else
  /// Geneva. Null while that resolution is still in flight (device-QA
  /// addendum, point 1).
  LatLng? _initialCameraCenter;

  /// Mirrors `MapLibreMap.myLocationEnabled`. Starts false and flips true
  /// once location permission is known to be granted (see
  /// [_enableMyLocation]) — never unconditionally true at native map
  /// creation, which is what left the own-position dot invisible until an
  /// app switch (device-QA addendum, point 2): the location layer would be
  /// asked to turn on before permission existed and never told to retry.
  bool _myLocationEnabled = false;

  /// Set by `MapLibreMap.onCameraTrackingDismissed` whenever a user gesture
  /// pans/zooms the map away from following the walker during navigation —
  /// device-QA addendum, point 3. Cleared again by the "recentrer" button
  /// or by a fresh camera-follow session (see [_onCameraFollowChanged]).
  /// Read only through [shouldShowRecenterButton] so the visibility rule
  /// stays in one, unit-tested place.
  bool _trackingReleased = false;

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
  /// while — and only while — a trip is recording (gated in [build] on
  /// `trip.isRecording`; see [GatedTicker]). The tick also samples the
  /// hardware step counter, which is only readable from this isolate (see
  /// [TripController.tick]). Running it unconditionally while idle would
  /// rebuild this screen once a second for nothing.
  late final _statsTicker = GatedTicker(onTick: () {
    if (!mounted) return;
    ref.read(tripControllerProvider).tick();
    setState(() {});
  });

  @override
  void initState() {
    super.initState();
    ref.read(tripControllerProvider).onCameraFollowChanged =
        _onCameraFollowChanged;
    unawaited(_resolveInitialCamera());
    unawaited(_checkExistingLocationPermission());
  }

  @override
  void dispose() {
    _statsTicker.dispose();
    _searchDebounce?.cancel();
    _searchController.dispose();
    final trip = ref.read(tripControllerProvider);
    if (trip.onCameraFollowChanged == _onCameraFollowChanged) {
      trip.onCameraFollowChanged = null;
    }
    super.dispose();
  }

  /// Last-known position (no permission prompt) when there is one, else
  /// Geneva — see [resolveInitialCameraCenter]. Awaited before the map is
  /// ever built (see [build]): `initialCameraPosition` is only read once,
  /// at native platform-view creation, so there is no way to correct it
  /// after the fact short of moving the camera again.
  Future<void> _resolveInitialCamera() async {
    final center = await resolveInitialCameraCenter(() async {
      final pos = await Geolocator.getLastKnownPosition();
      return pos == null ? null : (pos.latitude, pos.longitude);
    });
    if (!mounted) return;
    setState(() => _initialCameraCenter = center);
  }

  /// A passive, no-prompt read of whatever permission state already exists
  /// (e.g. granted in a previous session) so the location dot can appear
  /// the moment the map opens, without waiting for the user to trigger a
  /// permission flow from this screen first.
  Future<void> _checkExistingLocationPermission() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse) {
        _enableMyLocation();
      }
    } catch (_) {
      // Nothing to enable yet; a later successful position/permission flow
      // (see [_enableMyLocation]'s call sites) will catch up.
    }
  }

  /// Flips `MapLibreMap.myLocationEnabled` on. A no-op past the first call —
  /// device-QA addendum, point 2: this is deliberately the *only* thing that
  /// turns the layer on, called once permission is actually known to be
  /// granted (a successful position, or a completed start-trip permission
  /// flow), so the native location component is never asked to enable
  /// itself before it has anything to show.
  void _enableMyLocation() {
    if (_myLocationEnabled || !mounted) return;
    setState(() => _myLocationEnabled = true);
  }

  void _onCameraFollowChanged(bool follow) {
    controller?.updateMyLocationTrackingMode(
        follow ? MyLocationTrackingMode.tracking : MyLocationTrackingMode.none);
    // A fresh camera-follow session — trip start or stop — starts unreleased:
    // carrying a stale release across trips would show the recentrer button
    // (or hide it) based on the previous trip's last gesture.
    if (_trackingReleased && mounted) setState(() => _trackingReleased = false);
  }

  /// `MapLibreMap.onCameraTrackingDismissed` — fired by any user gesture
  /// (pan/zoom) that takes the camera out of `MyLocationTrackingMode`.
  /// Device-QA addendum, point 3: navigation itself is untouched by this —
  /// only whether the map keeps re-centring on the walker.
  void _onCameraTrackingDismissed() {
    if (!mounted) return;
    setState(() => _trackingReleased = true);
  }

  /// The "recentrer" button: re-engages camera-follow without touching the
  /// trip itself.
  void _recenterOnTrack() {
    controller?.updateMyLocationTrackingMode(MyLocationTrackingMode.tracking);
    setState(() => _trackingReleased = false);
  }

  /// The planning state to edit: whatever is stored, or an empty plan
  /// carrying the current profile.
  ActiveRoute _plan(TripController trip) =>
      trip.activeRoute ?? ActiveRoute(profile: trip.profile);

  /// Fires once per native map instance: resets stale handles, then — once
  /// the new style has loaded (required before addImage/addSymbol/addLine)
  /// — redraws whatever the app state says should be on the map.
  void _onMapCreated(MapLibreMapController c) {
    controller = c;
    _iconsRegistered = false;
    // A brightness flip remounts MapLibreMap under a new ValueKey(styleUrl)
    // (no live style-swap API in this maplibre_gl version): the previous
    // native map instance — and everything drawn on it — is gone, so these
    // Symbol/Line handles now point at a disposed controller. Null them
    // out immediately so a later removeSymbol/removeLine can't target a
    // foreign controller; _syncOverlays redraws against the fresh one.
    _routeLineCasing = null;
    _routeLine = null;
    _departureMarker = null;
    _destinationMarker = null;
    _drawn = null;
  }

  Future<void> _onStyleLoaded() async {
    await _registerWaymarkIcons();
    await _redrawAfterRemount();
  }

  /// Re-adds whatever route/markers/camera-follow the app state says are
  /// active, against this (possibly brand new) native map instance.
  Future<void> _redrawAfterRemount() async {
    await _syncOverlays();
    final trip = ref.read(tripControllerProvider);
    if (trip.isRecording && trip.isRouteBound) {
      controller?.updateMyLocationTrackingMode(MyLocationTrackingMode.tracking);
    }
  }

  /// Reconciles the map's overlays with [TripController.activeRoute].
  ///
  /// One place draws, so there is one place to get right: planning a route,
  /// switching tabs back, flipping the theme and restoring at cold start
  /// all end here rather than each adding symbols their own way.
  Future<void> _syncOverlays() async {
    if (_syncing || controller == null) return;
    final target = ref.read(tripControllerProvider).activeRoute;
    if (identical(target, _drawn)) return;
    _syncing = true;
    try {
      await _registerWaymarkIcons();
      await _removeOverlays();
      if (target != null) await _drawOverlays(target);
      _drawn = target;
    } finally {
      _syncing = false;
    }
    if (!mounted) return;
    setState(() {});
    // The plan can change while we are awaiting the platform channel; one
    // more pass settles it (and is a no-op in the common case).
    if (!identical(ref.read(tripControllerProvider).activeRoute, _drawn)) {
      unawaited(_syncOverlays());
    }
  }

  Future<void> _removeOverlays() async {
    final symbols = [_departureMarker, _destinationMarker].nonNulls.toList();
    final lines = [_routeLine, _routeLineCasing].nonNulls.toList();
    _departureMarker = null;
    _destinationMarker = null;
    _routeLine = null;
    _routeLineCasing = null;
    for (final s in symbols) {
      await controller?.removeSymbol(s);
    }
    for (final l in lines) {
      await controller?.removeLine(l);
    }
  }

  Future<void> _drawOverlays(ActiveRoute plan) async {
    final departure = plan.departure;
    if (departure != null) {
      _departureMarker = await controller?.addSymbol(SymbolOptions(
          geometry: LatLng(departure.$1, departure.$2),
          iconImage: _kIconMarkerA,
          iconSize: 1.0,
          iconAnchor: 'center'));
    }
    final destination = plan.destination;
    if (destination != null) {
      _destinationMarker = await controller?.addSymbol(SymbolOptions(
          geometry: LatLng(destination.$1, destination.$2),
          iconImage: _kIconMarkerB,
          iconSize: 1.0,
          iconAnchor: 'center'));
    }
    final route = plan.route;
    if (route != null) {
      final geometry = [for (final (lat, lon) in route.shape) LatLng(lat, lon)];
      // Casing first (drawn below), then the yellow line on top.
      _routeLineCasing = await controller?.addLine(LineOptions(
          geometry: geometry,
          lineColor: AppColors.routeLineCasingHex,
          lineWidth: 7,
          lineOpacity: 1.0));
      _routeLine = await controller?.addLine(LineOptions(
          geometry: geometry,
          lineColor: AppColors.routeLineHex,
          lineWidth: 4.5));
    }
  }

  /// Registers the waymark diamond icons on the current native map
  /// instance. `_iconsRegistered` is only set once the addImage calls have
  /// actually succeeded — if the style isn't ready yet or a call throws,
  /// it stays false so the next caller retries instead of silently leaving
  /// the map without its marker icons forever.
  Future<void> _registerWaymarkIcons() async {
    if (_iconsRegistered || controller == null) return;
    final contour = await waymarkDiamondPng(
        sizePx: _kWaymarkIconSizePx, color: AppColors.ink, filled: false, strokeWidth: 4);
    final filled = await waymarkDiamondPng(
        sizePx: _kWaymarkIconSizePx, color: AppColors.ink);
    await controller?.addImage(_kIconMarkerA, contour);
    await controller?.addImage(_kIconMarkerB, filled);
    _iconsRegistered = true;
  }

  /// Resolves the live GPS position, or `null` if it isn't available for
  /// any reason: permission denied, location services turned off system-
  /// wide (as opposed to just app permission), or the platform call itself
  /// failing/timing out. Callers treat `null` uniformly — see
  /// [kLocationDeniedMessage] / [kPositionUnavailableMessage].
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
      // A position was just obtained, so permission is granted — safe to
      // turn the own-position dot on now (device-QA addendum, point 2).
      _enableMyLocation();
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
            .showSnackBar(const SnackBar(content: Text(kLocationDeniedMessage)));
      }
      return;
    }
    await controller?.animateCamera(CameraUpdate.newLatLngZoom(pos, 15));
  }

  Future<void> _onMapLongClick(Point<double> point, LatLng coords) async {
    final trip = ref.read(tripControllerProvider);
    if (_armSetDeparture) {
      setState(() => _armSetDeparture = false);
      await trip.saveActiveRoute(
          _plan(trip).copyWith(departure: (coords.latitude, coords.longitude)));
      if (trip.activeRoute?.destination != null) await _planRoute();
      return;
    }
    await trip.saveActiveRoute(_plan(trip).copyWith(
        destination: (coords.latitude, coords.longitude), clearRoute: true));
    await _planRoute();
  }

  Future<void> _clearRoute() async {
    setState(() => _armSetDeparture = false);
    await ref.read(tripControllerProvider).clearActiveRoute();
  }

  void _armDepartureChange() {
    setState(() => _armSetDeparture = true);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Appui long sur la carte pour choisir le nouveau départ.')));
  }

  Future<void> _planRoute() async {
    final trip = ref.read(tripControllerProvider);
    final plan = _plan(trip);
    final destination = plan.destination;
    if (destination == null) return;
    final pinned = plan.departure;
    final departure = pinned != null
        ? LatLng(pinned.$1, pinned.$2)
        : await _currentPositionOrNull();
    if (!mounted) return;
    if (departure == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(kPositionUnavailableMessage)));
      return;
    }
    setState(() {
      _planning = true;
      _downloadProgress = null;
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
          toLat: destination.$1,
          toLon: destination.$2,
          profile: plan.profile));
      // Re-read the plan: the user may have moved a pin while the engine
      // was working, and the freshly computed route belongs to whatever
      // the plan says *now*, not to the snapshot taken above.
      await trip.saveActiveRoute(_plan(trip).copyWith(route: result));
      // RoutingException: no path found in an otherwise-covered area.
      // SocketException/HttpException/ClientException: the coverage fetch
      // failed offline with no warm cache (see CoverageRepository) — from
      // the player's perspective that's the same outcome as an uncovered
      // area, so it reads with the same message rather than crashing.
    } on RoutingException {
      _showRouteUnavailable();
    } on SocketException {
      _showRouteUnavailable();
    } on HttpException {
      _showRouteUnavailable();
    } on http.ClientException {
      _showRouteUnavailable();
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

  void _showRouteUnavailable() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Itinéraire impossible ici — zone non couverte ?')));
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
    final near = ref.read(tripControllerProvider).activeRoute?.departure;
    try {
      final results =
          await service.search(query, nearLat: near?.$1, nearLon: near?.$2);
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
    final trip = ref.read(tripControllerProvider);
    _searchController.clear();
    // Invalidate any still-in-flight search for a previous keystroke so its
    // response can't repopulate the list after the user already picked one.
    _searchGeneration.start();
    setState(() {
      _searchResults = [];
      _searchError = null;
    });
    FocusScope.of(context).unfocus();
    await trip.saveActiveRoute(_plan(trip)
        .copyWith(destination: (result.lat, result.lon), clearRoute: true));
    await controller?.animateCamera(
        CameraUpdate.newLatLng(LatLng(result.lat, result.lon)));
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
    final trip = ref.read(tripControllerProvider);
    final route = trip.route;
    if (route == null) return;
    if (await trip.startTrip(route: route)) {
      // The permission flow inside startTrip just ran, successfully — the
      // fresh-install path (device-QA addendum, point 2) starts here just
      // as often as it does from `_currentPositionOrNull`.
      _enableMyLocation();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(startFailureMessage(trip.lastStartFailure))));
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
    final trip = ref.read(tripControllerProvider);
    if (await trip.startTrip(profile: profile)) {
      _enableMyLocation();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(startFailureMessage(trip.lastStartFailure))));
    }
  }

  Future<void> _stopTrip() async {
    await ref.read(tripControllerProvider).stopTrip();
  }

  Future<void> _onProfileChanged(RoutingProfile profile) async {
    final trip = ref.read(tripControllerProvider);
    await trip.setProfile(profile);
    if (trip.activeRoute?.destination != null) await _planRoute();
  }

  @override
  Widget build(BuildContext context) {
    final initialCenter = _initialCameraCenter;
    if (initialCenter == null) {
      // Resolving the initial camera (last-known position, else Geneva —
      // see [_resolveInitialCamera]) is normally sub-frame fast; this only
      // ever shows for the handful of milliseconds that takes.
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    final trip = ref.watch(tripControllerProvider);
    _statsTicker.sync(trip.isRecording);
    // The plan can change from anywhere (a restore at startup, the session
    // tab, a search result); redraw after the frame that noticed.
    if (!identical(trip.activeRoute, _drawn) && !_syncing) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => unawaited(_syncOverlays()));
    }
    final brightness = Theme.of(context).brightness;
    final styleUrl =
        brightness == Brightness.dark ? kMapStyleUrlDark : kMapStyleUrlLight;
    final result = trip.route;

    Widget? bottomBanner;
    if (_planning) {
      bottomBanner = _ProgressBanner(progress: _downloadProgress);
    } else if (trip.isRecording) {
      bottomBanner = _StatsBanner(
        distanceKm: trip.distanceKm,
        elapsed: _formatDuration(trip.elapsed),
        onStop: _stopTrip,
      );
    } else if (result != null) {
      bottomBanner = _ResultBanner(
        text: _formatResult(result),
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
                CameraPosition(target: initialCenter, zoom: 13),
            myLocationEnabled: _myLocationEnabled,
            myLocationTrackingMode: MyLocationTrackingMode.none,
            attributionButtonPosition: AttributionButtonPosition.bottomLeft,
            onMapCreated: _onMapCreated,
            // addImage/addSymbol must wait for the style to finish loading
            // (see maplibre_map.dart's onStyleLoadedCallback doc).
            onStyleLoadedCallback: _onStyleLoaded,
            onMapLongClick: _onMapLongClick,
            // Device-QA addendum, point 3: any user gesture releases the
            // camera from following the walker during navigation.
            onCameraTrackingDismissed: _onCameraTrackingDismissed,
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
                      selected: {trip.profile},
                      onSelectionChanged: trip.isRecording
                          ? null
                          : (s) => _onProfileChanged(s.first),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (shouldShowRecenterButton(
                isNavigating: trip.isRouteBound,
                trackingReleased: _trackingReleased)) ...[
              FloatingActionButton(
                heroTag: 'recenter',
                onPressed: _recenterOnTrack,
                tooltip: 'Recentrer',
                child: const WaymarkDiamond(size: 16, color: AppColors.ink),
              ),
              const SizedBox(height: 12),
            ],
            FloatingActionButton(
              heroTag: 'myLocation',
              onPressed: _centerOnUser,
              child: const Icon(Icons.my_location),
            ),
          ],
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
                  icon: const WaymarkDiamond(size: 12, color: AppColors.ink),
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
          icon: const WaymarkDiamond(size: 14, color: AppColors.ink),
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
