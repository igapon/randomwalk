import 'dart:async';
import 'dart:io';
import 'dart:math' show Point;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'candidate_chips_bar.dart';
import 'geocoding.dart';
import 'initial_camera.dart';
import 'latest_only.dart';
import 'nav_camera_state.dart';
import 'plan_mode.dart';
import 'replan_line.dart';
import 'route_controller.dart';
import '../coverage/manifest.dart' show DatasetVersionMismatch;
import '../exploration/explore_planner.dart';
import '../game/game_state_provider.dart';
import '../game/grid.dart' show corridorCells;
import '../loop/loop_planner.dart';
import '../loop/speed_history.dart';
import '../nav/guidance_text.dart';
import '../nav/nav_fields.dart' show formatDistance;
import '../nav/polyline_math.dart' show metersBetween;
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

  /// The (normalised — empty reads as null) [TripSnapshot.navRouteShapeEnc]
  /// the route line currently drawn was last redrawn for. Null both before
  /// the map has ever synced a replanned shape, and again once
  /// [_maybeSyncReplannedRoute] has restored the base planned line — see
  /// [decideReplanLineSync].
  String? _lastDrawnRouteShapeEnc;

  bool _planning = false;
  ({int done, int total})? _downloadProgress;

  /// Set once the "Couverture incomplète" banner has been shown, so it
  /// surfaces at most once per planning session (task-8 brief point 2)
  /// instead of on every replan for the rest of the screen's lifetime.
  ///
  /// "Session" is reset-scoped, not screen-lifetime-scoped (task-7 item 8
  /// fix): [_clearCandidates] (✕ on the sheet) and the start of a
  /// fresh series (`_planRoute`/`_proposeCandidates`) both clear it, so a
  /// warning already shown for one planning attempt does not silently
  /// suppress the same warning for an unrelated later one.
  bool _coverageWarningShown = false;

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

  // ---- Task 6: plan mode (Itinéraire / Distance / Durée) --------------------

  final _planModeStore = PlanModeStore();
  final _speedHistory = SpeedHistoryStore();
  PlanMode _planMode = PlanMode.itinerary;
  double _loopTargetKm = defaultLoopTargetKm(RoutingProfile.walk);
  Duration _durationTarget = kDurationTargetDefault;

  /// The walker's own learned pace for the current profile — drives both the
  /// Durée conversion label and every candidate card's "durée estimée", and
  /// (task 8, owner micro-feature) the A→B result banner's duration, in
  /// place of Valhalla's generic per-profile estimate. Null until the first
  /// async load resolves — [_formatResult] falls back to the route's own
  /// estimate for that gap — and recomputed whenever the profile changes.
  double? _speedKmh;

  /// Whether the plan-target panel's slider is expanded, or collapsed to a
  /// single tappable line (task-8 brief point 2: « Distance · 5,0 km ▸ » /
  /// « Durée · 1 h 30 ▸ »). Starts collapsed; reset to collapsed on every
  /// mode switch and the instant « Proposer » is pressed, so the walker
  /// never has to manually re-collapse it before the next glance at the map.
  bool _planPanelExpanded = false;

  int _planSeed = initialSeed(DateTime.now());
  LoopPlanResult? _candidateResult;

  /// The [PlanKind] the currently shown [_candidateResult] was planned for —
  /// kept alongside it (rather than re-derived from the live [_planMode]
  /// state, which may have moved on) so [_startCandidate] promotes it with
  /// the destination it actually belongs to.
  PlanKind? _candidateKind;
  int _selectedCandidateIndex = 0;
  bool _candidatePlanning = false;
  final _candidateGeneration = LatestOnly();

  /// Native line handles for the up-to-3 drawn candidate polylines — see
  /// [_drawCandidateLines]. Separate from [_routeLine]/[_routeLineCasing]
  /// (the *planned* route line): candidates are a preview, never overlap
  /// with the standard route-drawing pipeline, and are torn down as soon as
  /// one is promoted (via « C'est parti ») or the sheet is dismissed.
  final List<Line> _candidateLines = [];

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
  late final _statsTicker = GatedTicker(
    onTick: () {
      if (!mounted) return;
      ref.read(tripControllerProvider).tick();
      setState(() {});
    },
  );

  @override
  void initState() {
    super.initState();
    ref.read(tripControllerProvider).onCameraFollowChanged =
        _onCameraFollowChanged;
    unawaited(_resolveInitialCamera());
    unawaited(_checkExistingLocationPermission());
    unawaited(_loadPlanMode());
    unawaited(_refreshSpeedKmh());
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
      follow ? MyLocationTrackingMode.tracking : MyLocationTrackingMode.none,
    );
    // A fresh camera-follow session — trip start or stop — starts unreleased:
    // carrying a stale release across trips would show the recentrer button
    // (or hide it) based on the previous trip's last gesture.
    if (_trackingReleased && mounted) setState(() => _trackingReleased = false);
  }

  /// `MapLibreMap.onCameraTrackingDismissed` — fired by maplibre-android's
  /// `LocationComponent` whenever the camera moves in a way it did not
  /// itself drive: a user gesture (pan/zoom), *and* — fix-round correction
  /// of this comment's earlier, narrower claim, confirmed by reading
  /// `MapLibreMapController.java`'s `onCameraTrackingDismissed` — an
  /// app-initiated `animateCamera`/`moveCamera` call too, since those bypass
  /// the location component's own tracking API just as a gesture does. That
  /// means `_centerOnUser`'s `animateCamera` also releases tracking during
  /// navigation; see its doc comment. Device-QA addendum, point 3:
  /// navigation itself is untouched by any of this — only whether the map
  /// keeps re-centring on the walker.
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
    // Same story as the route line above: these handles are dead too, and
    // must be dropped (not removed — there is nothing left to remove them
    // from) rather than leaked as stale references.
    _candidateLines.clear();
    // Forces [_maybeSyncReplannedRoute] to re-check on the next frame: the
    // base draw below redraws the *planned* route, which is stale if a
    // replan had already happened before this remount (a theme flip
    // mid-navigation, say).
    _lastDrawnRouteShapeEnc = null;
  }

  Future<void> _onStyleLoaded() async {
    await _registerWaymarkIcons();
    await _redrawAfterRemount();
    if (_candidateResult != null) await _drawCandidateLines();
  }

  /// Re-adds whatever route/markers/camera-follow the app state says are
  /// active, against this (possibly brand new) native map instance.
  ///
  /// Must not re-engage tracking over a release the walker's last gesture
  /// asked for (fix-round finding) — see
  /// [shouldReengageTrackingOnRemount]'s doc comment.
  Future<void> _redrawAfterRemount() async {
    await _syncOverlays();
    await _maybeSyncReplannedRoute();
    final trip = ref.read(tripControllerProvider);
    if (shouldReengageTrackingOnRemount(
      isRecording: trip.isRecording,
      isRouteBound: trip.isRouteBound,
      trackingReleased: _trackingReleased,
    )) {
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
      _departureMarker = await controller?.addSymbol(
        SymbolOptions(
          geometry: LatLng(departure.$1, departure.$2),
          iconImage: _kIconMarkerA,
          iconSize: 1.0,
          iconAnchor: 'center',
        ),
      );
    }
    final destination = plan.destination;
    if (destination != null) {
      _destinationMarker = await controller?.addSymbol(
        SymbolOptions(
          geometry: LatLng(destination.$1, destination.$2),
          iconImage: _kIconMarkerB,
          iconSize: 1.0,
          iconAnchor: 'center',
        ),
      );
    }
    final route = plan.route;
    if (route != null) {
      final geometry = [for (final (lat, lon) in route.shape) LatLng(lat, lon)];
      // Casing first (drawn below), then the yellow line on top.
      _routeLineCasing = await controller?.addLine(
        LineOptions(
          geometry: geometry,
          lineColor: AppColors.routeLineCasingHex,
          lineWidth: 7,
          lineOpacity: 1.0,
        ),
      );
      _routeLine = await controller?.addLine(
        LineOptions(
          geometry: geometry,
          lineColor: AppColors.routeLineHex,
          lineWidth: 4.5,
        ),
      );
    }
  }

  /// Redraws the route line from the service's replanned shape whenever
  /// [TripSnapshot.navRouteShapeEnc] changes from what is currently on
  /// screen — see [decideReplanLineSync] for the decision itself, kept
  /// pure and tested separately.
  ///
  /// The planned route drawn by [_drawOverlays] never changes on its own —
  /// it is [TripController.activeRoute], which nothing touches once a trip
  /// starts. A service-side replan happens entirely inside the tracking
  /// isolate and reaches this process only through the snapshot's
  /// [TripSnapshot.navRouteShapeEnc]; this is the one place that decodes it
  /// back into map geometry (review ruling: the new route replaces the old
  /// one on the map, not alongside it).
  Future<void> _maybeSyncReplannedRoute() async {
    if (controller == null) return;
    final trip = ref.read(tripControllerProvider);
    final raw = trip.snapshot?.navRouteShapeEnc;
    final enc = (raw == null || raw.isEmpty) ? null : raw;
    switch (decideReplanLineSync(
      isRouteBound: trip.isRouteBound,
      currentShapeEnc: enc,
      lastDrawnShapeEnc: _lastDrawnRouteShapeEnc,
    )) {
      case ReplanLineSync.none:
        return;
      case ReplanLineSync.redraw:
        final shape = decodePolyline6(enc!);
        if (shape.length < 2) return;
        await _redrawRouteLine(shape);
        _lastDrawnRouteShapeEnc = enc;
      case ReplanLineSync.restoreBase:
        // The replan this trip (or a previous one) had drawn is gone —
        // put the planned route's own line back rather than leaving the
        // dead replan on screen forever (final review item 4).
        final planned = trip.activeRoute?.route?.shape;
        if (planned != null && planned.length >= 2) {
          await _redrawRouteLine(planned);
        }
        _lastDrawnRouteShapeEnc = null;
    }
  }

  /// Draws the new casing/line pair before removing the old one, so the
  /// route never flashes empty between a replan and its redraw.
  Future<void> _redrawRouteLine(List<(double, double)> shape) async {
    final oldCasing = _routeLineCasing;
    final oldLine = _routeLine;
    final geometry = [for (final (lat, lon) in shape) LatLng(lat, lon)];
    _routeLineCasing = await controller?.addLine(
      LineOptions(
        geometry: geometry,
        lineColor: AppColors.routeLineCasingHex,
        lineWidth: 7,
        lineOpacity: 1.0,
      ),
    );
    _routeLine = await controller?.addLine(
      LineOptions(
        geometry: geometry,
        lineColor: AppColors.routeLineHex,
        lineWidth: 4.5,
      ),
    );
    if (oldCasing != null) await controller?.removeLine(oldCasing);
    if (oldLine != null) await controller?.removeLine(oldLine);
    if (!mounted) return;
    setState(() {});
  }

  /// Registers the waymark diamond icons on the current native map
  /// instance. `_iconsRegistered` is only set once the addImage calls have
  /// actually succeeded — if the style isn't ready yet or a call throws,
  /// it stays false so the next caller retries instead of silently leaving
  /// the map without its marker icons forever.
  Future<void> _registerWaymarkIcons() async {
    if (_iconsRegistered || controller == null) return;
    final contour = await waymarkDiamondPng(
      sizePx: _kWaymarkIconSizePx,
      color: AppColors.ink,
      filled: false,
      strokeWidth: 4,
    );
    final filled = await waymarkDiamondPng(
      sizePx: _kWaymarkIconSizePx,
      color: AppColors.ink,
    );
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

  /// The plain "my location" FAB. Note this releases camera-follow the same
  /// way a pan/zoom gesture does if it fires mid-navigation:
  /// `animateCamera` moves the camera outside the location component's own
  /// tracking API, so maplibre-android treats it as a dismissal just like a
  /// gesture (see `_onCameraTrackingDismissed`'s doc comment) — intended,
  /// not a bug: the walker asked to jump the view somewhere, so the
  /// "recentrer" button appearing afterwards to re-engage tracking is the
  /// correct outcome, not a stray side effect.
  Future<void> _centerOnUser() async {
    final pos = await _currentPositionOrNull();
    if (pos == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text(kLocationDeniedMessage)));
      }
      return;
    }
    await controller?.animateCamera(CameraUpdate.newLatLngZoom(pos, 15));
  }

  /// Départ/destination long-press — mode-aware since task 6:
  ///   * an armed départ (see [_armDepartureChange]) always sets the
  ///     departure, in every mode — "départ manuel armé, mécanique
  ///     existante" is exactly this, reused as-is for Distance/Durée.
  ///   * [PlanMode.itinerary] keeps its original behaviour: sets the
  ///     destination and immediately plans the standard A→B route.
  ///   * [PlanMode.loop] and [PlanMode.duration] both just record the
  ///     destination — task-8 brief point 3: a pin dropped in either mode is
  ///     honoured by the next « Proposer » as a fixed-target A→B request
  ///     instead of a closed loop (see [buildLoopRequest]) — without
  ///     auto-planning, since the actual plan only happens on « Proposer ».
  ///     A loop is simply what either mode plans when there is no pin.
  Future<void> _onMapLongClick(Point<double> point, LatLng coords) async {
    final trip = ref.read(tripControllerProvider);
    if (_armSetDeparture) {
      setState(() => _armSetDeparture = false);
      await trip.saveActiveRoute(
        _plan(trip).copyWith(departure: (coords.latitude, coords.longitude)),
      );
      if (_planMode == PlanMode.itinerary &&
          trip.activeRoute?.destination != null) {
        await _planRoute();
      }
      return;
    }
    await trip.saveActiveRoute(
      _plan(trip).copyWith(
        destination: (coords.latitude, coords.longitude),
        clearRoute: true,
      ),
    );
    if (_planMode == PlanMode.itinerary) {
      await _planRoute();
    } else {
      _clearCandidates();
    }
  }

  Future<void> _clearRoute() async {
    setState(() => _armSetDeparture = false);
    await ref.read(tripControllerProvider).clearActiveRoute();
    _clearCandidates();
  }

  void _armDepartureChange() {
    setState(() => _armSetDeparture = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Appui long sur la carte pour choisir le nouveau départ.',
        ),
      ),
    );
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
        const SnackBar(content: Text(kPositionUnavailableMessage)),
      );
      return;
    }
    // Item 8: a fresh planning series earns a fresh chance to warn about
    // incomplete coverage, same reasoning as `_clearCandidates`' reset.
    _coverageWarningShown = false;
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
      final result = await planner.plan(
        RouteRequest(
          fromLat: departure.latitude,
          fromLon: departure.longitude,
          toLat: destination.$1,
          toLon: destination.$2,
          profile: plan.profile,
        ),
      );
      // Re-read the plan: the user may have moved a pin while the engine
      // was working, and the freshly computed route belongs to whatever
      // the plan says *now*, not to the snapshot taken above.
      // `isLoop: false` explicitly, not just by omission: this is the A→B
      // planner, and the plan being written into may still carry the flag
      // from a loop candidate promoted earlier in the session.
      await trip.saveActiveRoute(
        _plan(trip).copyWith(route: result, isLoop: false),
      );
      if (planner.lastVersionMismatch) _showUpdateRequired();
      if (planner.lastCoverageFailed > 0 && !_coverageWarningShown) {
        _coverageWarningShown = true;
        _showCoverageIncomplete();
      }
      // RoutingException: no path found in an otherwise-covered area.
      // SocketException/HttpException/ClientException: the coverage fetch
      // failed offline with no warm cache (see CoverageRepository) — from
      // the player's perspective that's the same outcome as an uncovered
      // area, so it reads with the same message rather than crashing.
    } on DatasetVersionMismatch {
      // No cached manifest to fall back on at all (see CoverageRepository)
      // — coverage could not be established this run, but the message is
      // specific: an app update is what fixes it, not retrying.
      _showUpdateRequired();
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Itinéraire impossible ici — zone non couverte ?'),
      ),
    );
  }

  /// The tile server published a dataset for a Valhalla engine version this
  /// app build does not ship (`DatasetVersionMismatch`) — task-8 brief
  /// point 1. Shown every time it recurs, not just once per session: unlike
  /// the coverage-incomplete banner below, this is not "some areas may be
  /// missing" background noise — it means the app itself needs updating
  /// before *any* new coverage can be fetched.
  void _showUpdateRequired() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Mise à jour de l\'app requise pour les nouvelles cartes',
        ),
      ),
    );
  }

  /// `CoverageResult.failed > 0` for this plan — some of the tiles this
  /// route needed could not be downloaded, so parts of the covered area may
  /// be missing. Task-8 brief point 2.
  void _showCoverageIncomplete() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Couverture incomplète — certaines zones peuvent manquer',
        ),
      ),
    );
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
    _searchDebounce = Timer(
      const Duration(milliseconds: 400),
      () => _runSearch(query),
    );
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
      final results = await service.search(
        query,
        nearLat: near?.$1,
        nearLon: near?.$2,
      );
      if (!mounted || !_searchGeneration.isCurrent(gen)) return;
      setState(() {
        _searchResults = results;
        _searching = false;
      });
    } on GeocodingException catch (e) {
      if (!mounted || !_searchGeneration.isCurrent(gen)) return;
      setState(() {
        _searchResults = [];
        _searching = false;
        // Task 2b: honest, cause-specific message instead of always
        // claiming "hors ligne" — see `searchErrorMessage`.
        _searchError = searchErrorMessage(e.kind);
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
    await trip.saveActiveRoute(
      _plan(
        trip,
      ).copyWith(destination: (result.lat, result.lon), clearRoute: true),
    );
    await controller?.animateCamera(
      CameraUpdate.newLatLng(LatLng(result.lat, result.lon)),
    );
    // Mode-aware in the same way [_onMapLongClick] is: itinerary plans
    // immediately; Distance and Durée both just record the pin for the next
    // « Proposer » to honour as a fixed-target A→B request (task-8 point 3).
    if (_planMode == PlanMode.itinerary) {
      await _planRoute();
    } else {
      _clearCandidates();
    }
  }

  /// Owner micro-feature (task 8): the walker's own learned pace, same
  /// [_speedKmh] the candidate cards already read — see
  /// [formatRouteResultLabel]'s doc comment for the fallback while it is
  /// still loading.
  String _formatResult(RouteResult r) => formatRouteResultLabel(r, _speedKmh);

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
        SnackBar(content: Text(startFailureMessage(trip.lastStartFailure))),
      );
    }
  }

  /// One-tap start with no planned route: a minimal bottom sheet to pick
  /// (and remember) Marche/Vélo, then starts immediately.
  Future<void> _startFreeTrip() async {
    final profile = await showModalBottomSheet<RoutingProfile>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadii.card),
        ),
      ),
      builder: (_) => const _ProfileSheet(),
    );
    if (profile == null || !mounted) return;
    final trip = ref.read(tripControllerProvider);
    if (await trip.startTrip(profile: profile)) {
      _enableMyLocation();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(startFailureMessage(trip.lastStartFailure))),
      );
    }
  }

  Future<void> _stopTrip() async {
    await ref.read(tripControllerProvider).stopTrip();
  }

  Future<void> _onProfileChanged(RoutingProfile profile) async {
    final trip = ref.read(tripControllerProvider);
    await trip.setProfile(profile);
    if (_planMode == PlanMode.itinerary) {
      if (trip.activeRoute?.destination != null) await _planRoute();
    } else {
      _clearCandidates(); // a walker's loop is not a cyclist's loop.
    }
    unawaited(_refreshSpeedKmh());
  }

  // ---- Task 6: plan mode (Itinéraire / Distance / Durée) --------------------

  Future<void> _loadPlanMode() async {
    final mode = await _planModeStore.load();
    if (!mounted) return;
    setState(() => _planMode = mode);
  }

  /// Refreshes [_speedKmh] for the current profile — called at startup and
  /// on every profile change, so the Durée conversion label and each
  /// candidate card's estimated duration always reflect the walker's own
  /// learned pace rather than a stale one from a previous profile.
  Future<void> _refreshSpeedKmh() async {
    final profile = ref.read(tripControllerProvider).profile;
    final speed = await _speedHistory.speedKmh(profile);
    if (!mounted) return;
    setState(() => _speedKmh = speed);
  }

  Future<void> _onPlanModeChanged(PlanMode mode) async {
    if (mode == _planMode) return;
    final trip = ref.read(tripControllerProvider);
    final wasItinerary = _planMode == PlanMode.itinerary;
    // Drop an un-routed destination pin on any mode change: it belongs to
    // the panel it was set in, and switching panels leaves it invisible and
    // unclearable in whichever mode is now showing — in either direction
    // (final review item 7 made this symmetric). See
    // [shouldClearDestinationOnModeSwitch].
    final dropDestination = shouldClearDestinationOnModeSwitch(
      from: _planMode,
      to: mode,
      hasRoute: trip.route != null,
    );
    setState(() {
      _planMode = mode;
      _armSetDeparture = false;
      // Task 8: every mode switch starts the plan-target panel collapsed —
      // an expanded slider carried over from the mode just left makes no
      // sense in the one just entered.
      _planPanelExpanded = false;
      if (wasItinerary && mode != PlanMode.itinerary) {
        // Entering Distance/Durée fresh from Itinéraire: seed the slider
        // from the profile default rather than carrying over a value from a
        // previous Distance/Durée session that may no longer make sense.
        _loopTargetKm = defaultLoopTargetKm(trip.profile);
      }
    });
    if (dropDestination && trip.activeRoute?.destination != null) {
      await trip.saveActiveRoute(_plan(trip).copyWith(clearDestination: true));
    }
    _clearCandidates();
    // Review carry-over item 12: an open address search belongs to whatever
    // panel was showing when it was typed (the Itinéraire search field, or
    // the Durée destination search) — switching mode swaps that panel out
    // from under it, so its stale results/spinner/error must not linger
    // and block the panel/Proposer button that is now visible from being
    // immediately usable. Debounced searches in flight are cancelled the
    // same way `_onSearchChanged`'s own clear path does.
    _searchDebounce?.cancel();
    _searchGeneration.start();
    if (mounted) {
      setState(() {
        _searchResults = [];
        _searchError = null;
        _searching = false;
      });
    }
    await _planModeStore.save(mode);
  }

  /// ✕ on the Durée destination chip — drops the pinned destination (and any
  /// route computed for it), so « Proposer » goes back to loop semantics.
  /// Also drops any candidates already shown for the old A→B target, since
  /// they no longer match what « Proposer » would build next.
  Future<void> _clearPlanDestination() async {
    final trip = ref.read(tripControllerProvider);
    final plan = _plan(trip);
    if (plan.destination == null) return;
    await trip.saveActiveRoute(
      plan.copyWith(clearDestination: true, clearRoute: true),
    );
    _clearCandidates();
  }

  /// Task-8 brief point 2: tap on the collapsed « Distance · 5,0 km ▸ » /
  /// « Durée · 1 h 30 ▸ » line expands the slider.
  void _onTogglePlanPanelExpanded() {
    setState(() => _planPanelExpanded = !_planPanelExpanded);
  }

  void _onLoopTargetChanged(double km) {
    setState(() => _loopTargetKm = clampLoopTargetKm(km));
  }

  void _onDurationTargetChanged(Duration duration) {
    setState(() => _durationTarget = clampDurationTarget(duration));
  }

  /// « Proposer » — builds the request for the current mode (see
  /// [buildLoopRequest]) and runs it through [loopPlannerProvider], the
  /// coverage->init->routeMulti orchestration mirroring [_planRoute]'s own
  /// pipeline for the standard A→B planner.
  Future<void> _proposeCandidates() async {
    // Fix-round-1: a synchronous re-entry guard against a double-tap landing
    // before the button's own disabled state has had a chance to rebuild —
    // `_candidatePlanning` used to only flip true *after* the GPS wait
    // below, leaving a window where two taps could each start their own
    // full request series. Setting it here, before the first `await`, closes
    // that window (setState's callback runs synchronously).
    if (_candidatePlanning) return;
    final gen = _candidateGeneration.start();
    // Item 8: same reset as `_planRoute` — a fresh « Proposer » series earns
    // a fresh chance to warn about incomplete coverage.
    _coverageWarningShown = false;
    setState(() {
      _candidatePlanning = true;
      _downloadProgress = null;
      // Task-8 brief point 2: the plan-target panel collapses the instant
      // « Proposer » is pressed, not only once results land — and the
      // fullscreen selection UI (task-8 point 1) is about to replace the top
      // overlay entirely anyway once candidates arrive.
      _planPanelExpanded = false;
    });

    final trip = ref.read(tripControllerProvider);
    final plan = _plan(trip);
    final pinned = plan.departure;
    final departure = pinned != null
        ? LatLng(pinned.$1, pinned.$2)
        : await _currentPositionOrNull();
    if (!mounted || !_candidateGeneration.isCurrent(gen)) return;
    if (departure == null) {
      setState(() => _candidatePlanning = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(kPositionUnavailableMessage)),
      );
      return;
    }
    // Fix-round-1, point 3: Distance mode + a far pin. A slider left below
    // the direct start→destination distance builds a request with no detour
    // budget (see [loopTargetFloorForDestination]'s doc comment) — the
    // planner then hands back only the direct route, badged a wild,
    // deterministic gap that "Autres propositions" cannot improve on. Seed
    // the slider up to the direct distance before the request is built, or
    // — when even the slider's own maximum cannot reach it — refuse to plan
    // at all rather than repeat the same degenerate result.
    final pinnedDestination = plan.destination;
    if (_planMode == PlanMode.loop && pinnedDestination != null) {
      final directKm =
          metersBetween(
            departure.latitude,
            departure.longitude,
            pinnedDestination.$1,
            pinnedDestination.$2,
          ) /
          1000;
      final floor = loopTargetFloorForDestination(
        directKm: directKm,
        currentTargetKm: _loopTargetKm,
      );
      if (floor == null) {
        setState(() => _candidatePlanning = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(kDestinationTooFarMessage)),
        );
        return;
      }
      if (floor != _loopTargetKm) setState(() => _loopTargetKm = floor);
    }
    final speedKmh = _speedKmh ?? await _speedHistory.speedKmh(trip.profile);
    if (!mounted || !_candidateGeneration.isCurrent(gen)) return;
    setState(() => _speedKmh = speedKmh);

    // Final review item 6: the first « Proposer » in a fresh area downloads
    // tiles exactly like « Planifier » does, and without this the spinner sat
    // there with no progress for the whole download — see [_planRoute], whose
    // sink wiring this mirrors (including clearing it in `finally`, so a
    // later plan's progress can never be routed into a dead closure).
    final sink = ref.read(progressSinkProvider);
    sink.onProgress = (done, total) {
      if (!mounted || !_candidateGeneration.isCurrent(gen)) return;
      setState(() => _downloadProgress = (done: done, total: total));
    };

    // Task 7 (Explorer): compute the unrevealed-ground bias before the plan
    // itself is built. Best-effort, like every other game-side read — "le
    // jeu ne bloque jamais l'outil" (Global Constraints): a failure reading
    // the journal falls back to an empty revealed set (gameStateProvider
    // already degrades to a fresh GameState on its own errors; the extra
    // try/catch here is belt-and-braces against this call site specifically
    // never being allowed to fail a Proposer request). An empty revealed set
    // is exactly the virgin-state input `exploreBearings`/the bonus closure
    // already handle: no bias to apply, so Explorer behaves like Distance.
    List<double>? preferredBearingsDeg;
    double Function(RouteResult)? explorationBonus;
    if (_planMode == PlanMode.explore) {
      var revealedCellKeys = const <String>{};
      try {
        revealedCellKeys = (await ref.read(
          gameStateProvider.future,
        )).revealedCellKeys;
      } catch (_) {
        // Falls through with the empty set above.
      }
      if (!mounted || !_candidateGeneration.isCurrent(gen)) return;
      preferredBearingsDeg = exploreBearings(
        start: (departure.latitude, departure.longitude),
        targetKm: _loopTargetKm,
        revealedCellKeys: revealedCellKeys,
        count: LoopPlanner.candidateCount,
        seed: _planSeed,
      );
      explorationBonus = (route) {
        final cells = corridorCells(route.shape);
        if (cells.isEmpty) return 0.0;
        final unrevealed = cells
            .where((c) => !revealedCellKeys.contains(c.key))
            .length;
        return unrevealed / cells.length;
      };
    }

    try {
      // Final review item 7: built *inside* the try. [LoopRequest]'s
      // constructor throws `ArgumentError` on an invalid target, and outside
      // the try that throw escapes past the `finally` below — leaving
      // `_candidatePlanning` true and wedging the spinner (with its ✕ the
      // only way out) for the rest of the screen's life.
      final request = buildLoopRequest(
        mode: _planMode,
        loopTargetKm: _loopTargetKm,
        durationTarget: _durationTarget,
        speedKmh: speedKmh,
        profile: trip.profile,
        start: (departure.latitude, departure.longitude),
        destination: plan.destination,
        seed: _planSeed,
        preferredBearingsDeg: preferredBearingsDeg,
        explorationBonus: explorationBonus,
      );
      if (request == null) {
        // PlanMode.itinerary never reaches here (Proposer isn't shown), but
        // stays defensive rather than leaving the spinner stuck on — the
        // `finally` below drops it.
        return;
      }
      final orchestrator = await ref.read(loopPlannerProvider.future);
      final result = await orchestrator.plan(request);
      if (!mounted || !_candidateGeneration.isCurrent(gen)) {
        return; // cancelled (✕) or superseded while awaiting.
      }
      if (orchestrator.lastVersionMismatch) _showUpdateRequired();
      if (orchestrator.lastCoverageFailed > 0 && !_coverageWarningShown) {
        _coverageWarningShown = true;
        _showCoverageIncomplete();
      }
      if (result.candidates.isEmpty) {
        setState(() {
          _candidateResult = null;
          _candidateKind = null;
        });
        await _removeCandidateLines();
        _showNoLoopCandidates();
        return;
      }
      setState(() {
        _candidateResult = result;
        _candidateKind = request.kind;
        _selectedCandidateIndex = 0;
      });
      await _drawCandidateLines();
    } on DatasetVersionMismatch {
      _showUpdateRequired();
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
      if (mounted && _candidateGeneration.isCurrent(gen)) {
        setState(() {
          _candidatePlanning = false;
          _downloadProgress = null;
        });
      }
    }
  }

  /// ✕ on the spinner: invalidates the in-flight [_proposeCandidates] call
  /// (its result, once it lands, is simply dropped — see the generation
  /// check above) and drops the spinner immediately rather than waiting for
  /// a router call budget that can legitimately take a while.
  void _cancelCandidatePlanning() {
    _candidateGeneration.start();
    setState(() {
      _candidatePlanning = false;
      _downloadProgress = null;
    });
  }

  /// « Autres propositions »: same request, next seed.
  Future<void> _otherProposals() async {
    setState(() => _planSeed = nextSeed(_planSeed));
    await _proposeCandidates();
  }

  void _selectCandidate(int index) {
    final result = _candidateResult;
    if (result == null) return;
    setState(
      () => _selectedCandidateIndex = clampSelection(
        index,
        result.candidates.length,
      ),
    );
    unawaited(_drawCandidateLines());
  }

  /// ✕ on the sheet: drops the candidates and their preview lines, leaving
  /// whatever was planned before untouched.
  void _clearCandidates() {
    // Item 8: the coverage-incomplete warning's scope is one planning
    // session, not the whole screen lifetime — ✕ ends that session, so the
    // next « Proposer »/« Planifier » that hits incomplete coverage again
    // must be free to warn again rather than staying silenced by a flag an
    // unrelated, already-dismissed session set.
    _coverageWarningShown = false;
    if (_candidateResult == null && !_candidatePlanning) return;
    _candidateGeneration.start();
    setState(() {
      _candidateResult = null;
      _candidateKind = null;
      _candidatePlanning = false;
      _downloadProgress = null;
    });
    unawaited(_removeCandidateLines());
  }

  /// « C'est parti »: the selected candidate becomes the standard planned
  /// route — same [ActiveRoute]/[TripController.saveActiveRoute] path a
  /// plain A→B plan result takes today, so the result banner, the
  /// « Démarrer » pill and M2's navigation are all untouched by where the
  /// route actually came from.
  Future<void> _startCandidate() async {
    final result = _candidateResult;
    if (result == null || result.candidates.isEmpty) return;
    final index = clampSelection(
      _selectedCandidateIndex,
      result.candidates.length,
    );
    final candidate = result.candidates[index];
    final trip = ref.read(tripControllerProvider);
    final plan = _plan(trip);
    // A loop has no destination — start and end are the same point, already
    // implied by the route's own closed shape — so only a fixed-duration
    // A->B candidate keeps the pin the user set.
    final destination = _candidateKind == PlanKind.toDestination
        ? plan.destination
        : null;

    await _removeCandidateLines();
    await trip.saveActiveRoute(
      ActiveRoute(
        route: candidate.route,
        departure: plan.departure,
        destination: destination,
        profile: trip.profile,
        // Final review item 1: the one place loop-ness is *known*. From here it
        // rides the persisted plan into `NavSeed` and stops the tracking
        // service from replanning a loop back to its own start point (see
        // [ActiveRoute.isLoop]).
        isLoop: _candidateKind == PlanKind.loop,
      ),
    );
    setState(() {
      _candidateResult = null;
      _candidateKind = null;
    });
  }

  /// Draws every candidate's polyline: the selected one in the standard
  /// waymark yellow-on-ink casing (matching [_drawOverlays]'s planned-route
  /// styling exactly), the others in hydro at 40% opacity — brief's own
  /// "selected vs. others" spec for the candidates sheet.
  Future<void> _drawCandidateLines() async {
    await _removeCandidateLines();
    final result = _candidateResult;
    if (result == null || controller == null) return;
    final selected = clampSelection(
      _selectedCandidateIndex,
      result.candidates.length,
    );
    for (var i = 0; i < result.candidates.length; i++) {
      final geometry = [
        for (final (lat, lon) in result.candidates[i].route.shape)
          LatLng(lat, lon),
      ];
      if (i == selected) {
        _candidateLines.add(
          await controller!.addLine(
            LineOptions(
              geometry: geometry,
              lineColor: AppColors.routeLineCasingHex,
              lineWidth: 7,
              lineOpacity: 1.0,
            ),
          ),
        );
        _candidateLines.add(
          await controller!.addLine(
            LineOptions(
              geometry: geometry,
              lineColor: AppColors.routeLineHex,
              lineWidth: 4.5,
            ),
          ),
        );
      } else {
        _candidateLines.add(
          await controller!.addLine(
            LineOptions(
              geometry: geometry,
              lineColor: AppColors.hydroHex,
              lineWidth: 3,
              lineOpacity: 0.4,
            ),
          ),
        );
      }
    }
  }

  Future<void> _removeCandidateLines() async {
    for (final line in _candidateLines) {
      await controller?.removeLine(line);
    }
    _candidateLines.clear();
  }

  void _showNoLoopCandidates() {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text(kNoLoopCandidatesMessage)));
  }

  /// Everything that redraws map geometry from app state, run together in
  /// one post-frame callback — see [build]'s single scheduling site below.
  Future<void> _syncMapForFrame() async {
    await _syncOverlays();
    await _maybeSyncReplannedRoute();
  }

  /// « 2,4 km · ~32 min » for the bottom banner, or null when there is
  /// nothing to show yet (not route-bound, or the estimator has not seen
  /// enough movement for an ETA's underlying distance either). Kept out of
  /// [build] itself so the banner-building `if`/`else if` chain below reads
  /// as which *card* to show, not as nav-field bookkeeping.
  String? _navRemainingLabel(TripController trip) {
    if (!trip.isRouteBound) return null;
    final remainingKm = trip.snapshot?.navRemainingKm;
    if (remainingKm == null) return null;
    final etaSeconds = trip.snapshot?.navEtaSeconds;
    return formatRemaining(
      remainingKm,
      etaSeconds == null ? null : Duration(seconds: etaSeconds),
    );
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
    final snapshot = trip.snapshot;
    final rawShapeEnc = snapshot?.navRouteShapeEnc;
    final currentShapeEnc = (rawShapeEnc == null || rawShapeEnc.isEmpty)
        ? null
        : rawShapeEnc;
    // The plan can change from anywhere (a restore at startup, the session
    // tab, a search result); a replan happens inside the service. Either
    // redraws after the frame that noticed. Keyed on the shape itself, not
    // `navReplanCount` — see [decideReplanLineSync]'s doc comment on why a
    // counter that resets to 0 for every fresh trip cannot tell "nothing
    // changed" from "a previous trip's replanned line is still drawn".
    final needsOverlaySync = !identical(trip.activeRoute, _drawn) && !_syncing;
    final needsReplanSync =
        decideReplanLineSync(
          isRouteBound: trip.isRouteBound,
          currentShapeEnc: currentShapeEnc,
          lastDrawnShapeEnc: _lastDrawnRouteShapeEnc,
        ) !=
        ReplanLineSync.none;
    if (needsOverlaySync || needsReplanSync) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_syncMapForFrame()),
      );
    }
    final brightness = Theme.of(context).brightness;
    final styleUrl = brightness == Brightness.dark
        ? kMapStyleUrlDark
        : kMapStyleUrlLight;
    final result = trip.route;

    final candidateResult = _candidateResult;

    // Fix-round-1, point 1: `MapScreen` stays mounted behind the tab
    // `IndexedStack`, so a recording can start from the Session tab while
    // stale loop/duration candidates (and their preview polylines) are still
    // sitting here. A recording always wins — `showChips` is the single flag
    // both `bottomBanner` and `topOverlay` below key off, so the two can
    // never disagree about whether the fullscreen selection UI is showing.
    // The candidates themselves (and their polylines) are dropped via the
    // same `_clearCandidates` the ✕ uses, once per frame this is true.
    final showChips = shouldShowCandidateChips(
      hasCandidates: candidateResult != null,
      isRecording: trip.isRecording,
    );
    if (shouldClearCandidatesForRecording(
      isRecording: trip.isRecording,
      hasCandidates: candidateResult != null,
    )) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _clearCandidates());
    }
    // Fix-round-2: the other half of the same window — a `_proposeCandidates`
    // request still in flight (no `candidateResult` yet, so the check above
    // does not see it) when a recording starts must be cancelled too, or it
    // can land afterwards and resurrect the stale-candidates bug one frame
    // late. Bumping the generation via `_cancelCandidatePlanning` is exactly
    // what the spinner's own ✕ already does.
    if (shouldCancelCandidatePlanningForRecording(
      isRecording: trip.isRecording,
      candidatePlanning: _candidatePlanning,
    )) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _cancelCandidatePlanning(),
      );
    }

    Widget? bottomBanner;
    if (_planning) {
      bottomBanner = _ProgressBanner(progress: _downloadProgress);
    } else if (trip.isRecording) {
      bottomBanner = StatsBanner(
        distanceKm: trip.distanceKm,
        elapsed: _formatDuration(trip.elapsed),
        remaining: _navRemainingLabel(trip),
        arrived: trip.isRouteBound && (snapshot?.navArrived ?? false),
        onStop: _stopTrip,
      );
    } else if (_candidatePlanning) {
      bottomBanner = _CandidateProgressBanner(
        onCancel: _cancelCandidatePlanning,
        progress: _downloadProgress,
      );
    } else if (showChips && candidateResult != null) {
      // Task 8: fullscreen selection — the compact chip row replaces the old
      // full-size candidate cards, and (below) the top overlay steps aside
      // entirely for as long as this branch is showing.
      bottomBanner = CandidateChipsBar(
        result: candidateResult,
        selectedIndex: _selectedCandidateIndex,
        // Set by _proposeCandidates just before this result ever exists;
        // the literal fallback is an unreachable last resort, never a real
        // per-profile default (avoids a hard dependency on
        // SpeedHistoryStore's own private defaults from this widget).
        speedKmh: _speedKmh ?? 4.5,
        kind: _candidateKind,
        onSelect: _selectCandidate,
        onStart: _startCandidate,
        onOtherProposals: _otherProposals,
        onClose: _clearCandidates,
      );
    } else if (result != null) {
      bottomBanner = _ResultBanner(
        text: _formatResult(result),
        onChangeDeparture: _armDepartureChange,
        onClear: _clearRoute,
        onStart: _startRouteTrip,
      );
    } else {
      // Final review item 3: the « Démarrer » pill (a free session — no
      // route, no target) is shown in *every* plan mode, not only Itinéraire.
      // The owner's one-tap rule is about the app, not about which planning
      // panel happens to be selected: a walker who opened Distance, thought
      // better of it and just wants to start walking must not have to switch
      // tabs back to find the button. Distance/Durée's own controls (slider,
      // « Proposer ») live in the top overlay, so there is no conflict — and
      // the moment a plan or candidates exist, the branches above take over.
      bottomBanner = _StartPill(onStart: _startFreeTrip);
    }

    // The top-of-screen overlay during a route-bound trip: the plain
    // search/profile UI has no business floating over a walker mid-turn, so
    // it is replaced outright — review ruling: arrived wins over off-route.
    Widget topOverlay;
    if (trip.isRouteBound && snapshot != null) {
      if (snapshot.navArrived) {
        topOverlay = const NavArrivedCard();
      } else if (snapshot.navOffRoute || snapshot.navReplanning) {
        // Final review item 1: a loop is never recalculated, so the card must
        // not show a spinner and promise « Recalcul… » — it asks the walker
        // to rejoin the line instead. Read off the persisted plan rather than
        // the snapshot: loop-ness belongs to the route, and the snapshot
        // deliberately carries only what the service computes per fix.
        topOverlay = _NavRecalculatingCard(
          isLoop: trip.activeRoute?.isLoop ?? false,
        );
      } else if (snapshot.navInstruction != null &&
          snapshot.navInstruction!.isNotEmpty) {
        topOverlay = _NavInstructionCard(
          instruction: snapshot.navInstruction!,
          distanceM: snapshot.navDistanceToManeuverM,
        );
      } else {
        topOverlay = const SizedBox.shrink();
      }
    } else if (!shouldShowPlanningTopOverlay(hasCandidates: showChips)) {
      // Task 8, brief point 1 — the owner's own words: « pendant la
      // sélection… cache les menus… pour mieux voir la carte ». The instant
      // there are candidates to choose from, the mode selector, search bar,
      // profile picker and plan-target panel all disappear so the map is
      // fullscreen behind the compact chip row (built into `bottomBanner`
      // above); the ✕ on that row (`_clearCandidates`) is what brings this
      // branch back.
      topOverlay = const SizedBox.shrink();
    } else {
      // Fix-round-1: search results and the plan-target panel (slider +
      // Proposer) are never shown together. Both can be tall (results up to
      // 50% of the screen height; the panel has its own slider + button),
      // and stacking them atop the mode selector, search bar and profile
      // picker could push Proposer off-screen with no scroll affordance.
      // Search results only appear while the user is actively typing/has
      // just searched — exactly the moment picking a destination, not
      // proposing, is the point — so the lighter fix is mutual exclusion
      // rather than a ConstrainedBox+ScrollView: the panel simply steps
      // aside until the search box is dismissed or a result is picked
      // (which already clears `_searchResults`).
      final showSearchResults =
          _searching || _searchError != null || _searchResults.isNotEmpty;
      topOverlay = Column(
        children: [
          PlanModeSegmentedButton(
            selected: _planMode,
            onChanged: trip.isRecording ? null : _onPlanModeChanged,
          ),
          const SizedBox(height: 8),
          _SearchBar(
            controller: _searchController,
            onChanged: _onSearchChanged,
          ),
          if (showSearchResults)
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
                icon: Icon(Icons.directions_walk),
              ),
              ButtonSegment(
                value: RoutingProfile.bike,
                label: Text('Vélo'),
                icon: Icon(Icons.directions_bike),
              ),
            ],
            selected: {trip.profile},
            onSelectionChanged: trip.isRecording
                ? null
                : (s) => _onProfileChanged(s.first),
          ),
          if (_planMode != PlanMode.itinerary && !showSearchResults) ...[
            const SizedBox(height: 12),
            _PlanTargetPanel(
              mode: _planMode,
              loopTargetKm: _loopTargetKm,
              durationTarget: _durationTarget,
              speedKmh: _speedKmh,
              planning: _candidatePlanning,
              enabled: !trip.isRecording,
              destination: _plan(trip).destination,
              expanded: _planPanelExpanded,
              onToggleExpanded: _onTogglePlanPanelExpanded,
              onLoopTargetChanged: _onLoopTargetChanged,
              onDurationTargetChanged: _onDurationTargetChanged,
              onPropose: _proposeCandidates,
              onClearDestination: _clearPlanDestination,
            ),
          ],
        ],
      );
    }

    final showRecenter = shouldShowRecenterButton(
      isNavigating: trip.isRouteBound,
      trackingReleased: _trackingReleased,
    );

    return PopScope(
      // Fix-round-1, point 2: Android's system back gesture/button during
      // fullscreen candidate selection used to fall through to the OS
      // (backgrounding the app instead of leaving selection) since nothing
      // on this screen intercepted it. Blocking `canPop` whenever there is
      // something to back out of first — candidates on screen, or a
      // « Proposer » request still in flight — makes back == leave
      // selection == the same ✕ the chip row/spinner already offer, and
      // only a real "no candidates, nothing planning" state actually pops
      // the route (or exits the app).
      //
      // Fix-round-2: driven through [shouldInterceptBackForCandidates]
      // rather than these two flags raw — a recording that starts while
      // either is still true must free `canPop` in this very same frame,
      // not one frame later once the post-frame cancel/clear effects above
      // have actually run, or back reads as silently swallowed by a plan
      // the walker can no longer see behind the recording pill.
      canPop: !shouldInterceptBackForCandidates(
        hasCandidates: candidateResult != null,
        candidatePlanning: _candidatePlanning,
        isRecording: trip.isRecording,
      ),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_candidatePlanning) {
          _cancelCandidatePlanning();
        } else {
          _clearCandidates();
        }
      },
      child: Scaffold(
        body: Stack(
          children: [
            MapLibreMap(
              key: ValueKey(styleUrl),
              styleString: styleUrl,
              initialCameraPosition: CameraPosition(
                target: initialCenter,
                zoom: 13,
              ),
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
                  child: topOverlay,
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
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  bottom: bottomInset + 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // A row of its own above the bottom banner (not
                    // overlapping it, e.g. the full-width "Démarrer" pill) —
                    // see task-8 brief point 7.
                    const MapAttribution(),
                    const SizedBox(height: 6),
                    bottomBanner,
                  ],
                ),
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
              if (showRecenter) ...[
                RecenterButton(onPressed: _recenterOnTrack),
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
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
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
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : error != null
          ? Padding(padding: const EdgeInsets.all(16), child: Text(error!))
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
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }
}

/// « Proposer » in flight, for Distance/Durée (task 6) — a spinner with a
/// cancel ✕, distinct from [_ProgressBanner]: this one is cancellable
/// (LoopPlanner's router-call budget can legitimately take a few seconds),
/// where the standard A→B tile-download progress banner is not.
///
/// Final review item 6: it also reports tile-download progress while
/// [progress] is non-null. A « Proposer » in a fresh area downloads the same
/// tiles « Planifier » does, and a bare spinner through a multi-megabyte
/// download reads as a hung app — so the label switches to
/// [_ProgressBanner]'s own wording for exactly as long as the download runs,
/// then reverts to the search text.
class _CandidateProgressBanner extends StatelessWidget {
  const _CandidateProgressBanner({required this.onCancel, this.progress});
  final VoidCallback onCancel;
  final ({int done, int total})? progress;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    final label = (p != null && p.total > 0)
        ? 'Téléchargement des cartes… ${p.done}/${p.total}'
        : 'Recherche de boucles…';
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Annuler',
              onPressed: onCancel,
            ),
          ],
        ),
      ),
    );
  }
}

/// The plan-mode selector — « Itinéraire » / « Distance » / « Durée » /
/// « Explorer » (task 7 adds Explorer). Promoted out of `build()`'s inline
/// `SegmentedButton` (and made public, matching every other sub-widget this
/// file promotes for isolated testing — see map_screen_widgets_test.dart)
/// specifically to wrap it in horizontal scrolling.
///
/// **Why scrolling, not icons/shorter labels**: `SegmentedButton` lays its
/// segments out like a `Row` with no overflow handling of its own — it does
/// not wrap, shrink its labels, or scroll by itself. Three French labels
/// already ran close to the edge on a narrow phone; the fourth (« Explorer »)
/// pushes a plain `SegmentedButton` here past a 360dp-wide screen's
/// available width, which without this wrapper is a real
/// `RenderFlex overflowed` exception, not just a visual squeeze (see
/// map_screen_widgets_test.dart's narrow-phone group for the pinned
/// regression). Icons-only or abbreviated labels were the other option the
/// task-7 brief allowed, but the four mode names are exactly the
/// walker-facing strings the task 6/7 briefs specify, and shortening or
/// iconizing them would cost every walker on every device some clarity to
/// fix a problem only the narrowest phones actually have. A horizontally
/// scrolling row costs nothing on a phone wide enough to show all four
/// already (nothing to scroll to), and costs a one-finger swipe on the ones
/// that need it.
class PlanModeSegmentedButton extends StatelessWidget {
  const PlanModeSegmentedButton({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final PlanMode selected;

  /// `null` disables the selector entirely (e.g. `trip.isRecording`) — same
  /// convention as the Marche/Vélo `SegmentedButton` right below this one.
  final ValueChanged<PlanMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SegmentedButton<PlanMode>(
        segments: const [
          ButtonSegment(value: PlanMode.itinerary, label: Text('Itinéraire')),
          ButtonSegment(value: PlanMode.loop, label: Text('Distance')),
          ButtonSegment(value: PlanMode.duration, label: Text('Durée')),
          ButtonSegment(value: PlanMode.explore, label: Text('Explorer')),
        ],
        selected: {selected},
        onSelectionChanged: onChanged == null
            ? null
            : (s) => onChanged!(s.first),
      ),
    );
  }
}

/// Distance/Durée's mode-specific controls (task 6, redesigned by task 8
/// point 2 — the owner's own words: « l'écran est très cramped »): a
/// destination chip (shared by both modes — brief point 3), and either a
/// single collapsed line (« Distance · 5,0 km ▸ » / « Durée · 1 h 30 ▸ »,
/// tap to expand) or the full slider + « Proposer », so the map stays
/// visible behind more of the screen than the old always-expanded panel
/// left it. Lives in the top overlay, below the Marche/Vélo picker; that
/// whole overlay disappears once there are candidates to choose from (task
/// 8 point 1), so this panel's own expand state does not need to account
/// for that case.
class _PlanTargetPanel extends StatelessWidget {
  const _PlanTargetPanel({
    required this.mode,
    required this.loopTargetKm,
    required this.durationTarget,
    required this.speedKmh,
    required this.planning,
    required this.enabled,
    required this.destination,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onLoopTargetChanged,
    required this.onDurationTargetChanged,
    required this.onPropose,
    required this.onClearDestination,
  });

  final PlanMode mode;
  final double loopTargetKm;
  final Duration durationTarget;
  final double? speedKmh;
  final bool planning;

  /// False while `trip.isRecording` — a free (non-route-bound) recording
  /// trip still shows this top overlay, so the slider/Proposer/destination
  /// chip need the same "can't touch this mid-trip" guard the Marche/Vélo
  /// picker already has (fix-round-1, point 5).
  final bool enabled;

  /// The pinned destination, if any — shown, in *either* mode (task-8 point
  /// 3), as a clearable chip so a destination set earlier is never silently
  /// in effect.
  final (double, double)? destination;

  /// Whether the slider is expanded, or collapsed to the single tappable
  /// line — see [MapScreenState._planPanelExpanded].
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final ValueChanged<double> onLoopTargetChanged;
  final ValueChanged<Duration> onDurationTargetChanged;
  final VoidCallback onPropose;
  final VoidCallback onClearDestination;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pinnedDestination = destination;

    final Widget body;
    if (!expanded) {
      body = InkWell(
        onTap: enabled ? onToggleExpanded : null,
        borderRadius: BorderRadius.circular(AppRadii.card),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  planPanelCollapsedLabel(
                    mode: mode,
                    loopTargetKm: loopTargetKm,
                    durationTarget: durationTarget,
                  ),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      );
    } else if (mode == PlanMode.loop || mode == PlanMode.explore) {
      // Task 7: Explorer shares Distance's slider/floor rules verbatim (see
      // buildLoopRequest's doc comment) — only the label prefix tells the
      // two apart here.
      final label = mode == PlanMode.explore ? 'Explorer' : 'Distance';
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label : '
            '${loopTargetKm.toStringAsFixed(1).replaceAll('.', ',')} km',
            style: theme.textTheme.bodyMedium,
          ),
          Slider(
            min: kLoopTargetMinKm,
            max: kLoopTargetMaxKm,
            divisions:
                ((kLoopTargetMaxKm - kLoopTargetMinKm) / kLoopTargetStepKm)
                    .round(),
            value: loopTargetKm,
            onChanged: enabled ? onLoopTargetChanged : null,
          ),
          const SizedBox(height: 4),
          ElevatedButton(
            onPressed: (enabled && !planning) ? onPropose : null,
            child: const Text('Proposer'),
          ),
        ],
      );
    } else {
      final hours = durationTarget.inHours;
      final minutes = durationTarget.inMinutes % 60;
      final durationLabel = hours > 0
          ? '${hours}h ${minutes.toString().padLeft(2, '0')}'
          : '${minutes}min';
      final speed = speedKmh;
      final conversionLabel = speed == null
          ? null
          : formatConversionLabel(durationToTargetKm(durationTarget, speed));
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Durée : $durationLabel', style: theme.textTheme.bodyMedium),
          Slider(
            min: kDurationTargetMin.inMinutes.toDouble(),
            max: kDurationTargetMax.inMinutes.toDouble(),
            divisions:
                (kDurationTargetMax.inMinutes - kDurationTargetMin.inMinutes) ~/
                kDurationTargetStep.inMinutes,
            value: durationTarget.inMinutes.toDouble(),
            onChanged: enabled
                ? (minutes) => onDurationTargetChanged(
                    Duration(minutes: minutes.round()),
                  )
                : null,
          ),
          if (conversionLabel != null)
            Text(conversionLabel, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          ElevatedButton(
            onPressed: (enabled && !planning) ? onPropose : null,
            child: const Text('Proposer'),
          ),
        ],
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (shouldShowPlanDestinationChip(
              mode: mode,
              hasDestination: pinnedDestination != null,
            )) ...[
              Row(
                children: [
                  const Icon(Icons.flag, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Destination : ${formatDestinationLabel(pinnedDestination!)}',
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    iconSize: 18,
                    tooltip: 'Effacer la destination',
                    onPressed: enabled ? onClearDestination : null,
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
            body,
          ],
        ),
      ),
    );
  }
}

/// The top-of-screen card during a route-bound trip's normal turn-by-turn
/// state: instruction (Schibsted Grotesk 18) beside the distance to it
/// (Bricolage Grotesque 28, the "gros chiffre" a walker reads at a glance).
/// Neither text style exists in the app's [TextTheme] at these exact sizes
/// (the brief's sizes are binding), so both are built directly off
/// [AppFonts] rather than approximated from the nearest theme style.
///
/// Wrapped in a [Semantics] label built from [formatManeuver] — the one
/// place that combined sentence (« Dans 120 m, tournez à gauche ») is
/// actually used: a screen reader announces one sentence, sighted users read
/// the same information split across the two type sizes the brief asks for.
class _NavInstructionCard extends StatelessWidget {
  const _NavInstructionCard({required this.instruction, this.distanceM});
  final String instruction;
  final double? distanceM;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final distance = distanceM;
    return Semantics(
      label: distance == null
          ? instruction
          : formatManeuver(instruction, distance),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  instruction,
                  style: TextStyle(
                    fontFamily: AppFonts.body,
                    fontWeight: FontWeight.w600,
                    fontVariations: const [FontVariation('wght', 600)],
                    fontSize: 18,
                    color: onSurface,
                  ),
                ),
              ),
              if (distance != null) ...[
                const SizedBox(width: 12),
                Text(
                  formatDistance(distance),
                  style: TextStyle(
                    fontFamily: AppFonts.display,
                    fontWeight: FontWeight.w700,
                    fontVariations: const [FontVariation('wght', 700)],
                    fontSize: 28,
                    color: onSurface,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The walker has left the planned route and the service is recalculating —
/// review ruling: shown whenever `navOffRoute` is set and `navArrived` is
/// not (arrived always wins). Orange rather than the ink/paper the rest of
/// the app uses: this is the one state that needs to read as a warning at a
/// glance, not as more trip chrome.
/// Final review item 1: with [isLoop] it says [kNavRejoinLoopLabel] and drops
/// the spinner. A loop is deliberately never recalculated (see
/// `NavigationRuntime.isLoop`), so a spinner over « Recalcul… » would animate
/// away indefinitely for something that is never going to happen.
class _NavRecalculatingCard extends StatelessWidget {
  const _NavRecalculatingCard({this.isLoop = false});

  final bool isLoop;

  @override
  Widget build(BuildContext context) => Card(
    color: AppColors.recalcOrange,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          if (isLoop)
            const Icon(Icons.u_turn_left, size: 18, color: AppColors.ink)
          else
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.ink,
              ),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isLoop ? kNavRejoinLoopLabel : kNavRecalculatingLabel,
              style: const TextStyle(
                fontFamily: AppFonts.body,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The walker has reached the destination — review ruling: this wins over
/// `navOffRoute` (standing at the destination needs no invitation to get
/// back on a route that is, itself, now moot). The bottom banner's Terminer
/// button is put forward separately (see [StatsBanner]'s `arrived`) —
/// this card is purely the "you're here" announcement.
///
/// Public (not `_`-prefixed) so it is reachable from a widget test —
/// fix-round finding: [AppColors.ink] is byte-identical to the dark
/// [ColorScheme.surface] this card sits on (both `#1C2B25`), which made the
/// glyph disappear entirely in dark mode. Every color here is theme-resolved
/// ([ColorScheme.onSurface]) rather than a raw [AppColors] constant, and
/// `test/map/map_screen_widgets_test.dart` pumps this card in both
/// brightnesses to keep it that way.
class NavArrivedCard extends StatelessWidget {
  const NavArrivedCard({super.key});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            WaymarkDiamond(size: 20, color: onSurface),
            const SizedBox(width: 12),
            Text(
              kNavArrivedLabel,
              style: TextStyle(
                fontFamily: AppFonts.display,
                fontWeight: FontWeight.w700,
                fontVariations: const [FontVariation('wght', 700)],
                fontSize: 24,
                color: onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "recentrer" FAB — device-QA addendum point 3 — shown only while
/// [shouldShowRecenterButton] says a navigating trip's camera has been
/// released by a user gesture.
///
/// Public (not `_`-prefixed), and its glyph color theme-resolved
/// ([ColorScheme.onPrimaryContainer], matching the default Material 3
/// [FloatingActionButton] background of [ColorScheme.primaryContainer] —
/// this app never overrides `floatingActionButtonTheme`) rather than a raw
/// [AppColors.ink] constant — fix-round finding: in dark mode, ink-on-
/// `primaryContainer` (`yellowPaleDark`) reads at roughly 1.5:1, the same
/// family of contrast bug [NavArrivedCard] had. `onPrimaryContainer` is
/// exactly what the sibling "my location" FAB's plain [Icon] already gets
/// for free from the FAB's own [IconTheme] — this widget just has to ask
/// for it explicitly, since [WaymarkDiamond] takes a color parameter rather
/// than reading the ambient icon theme.
class RecenterButton extends StatelessWidget {
  const RecenterButton({super.key, required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FloatingActionButton(
    heroTag: 'recenter',
    onPressed: onPressed,
    tooltip: 'Recentrer',
    child: WaymarkDiamond(
      size: 16,
      color: Theme.of(context).colorScheme.onPrimaryContainer,
    ),
  );
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
                Expanded(child: Text(text, style: theme.textTheme.titleMedium)),
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

/// Small, semi-transparent data-source credit — required by both
/// OpenFreeMap's and OpenStreetMap's usage terms. Sits in its own row above
/// the bottom banner (see the `Column` in [MapScreenState.build]) rather
/// than literally overlapping it, so it never collides with the full-width
/// "Démarrer" pill. The fuller "OpenStreetMap © contributors (ODbL) ·
/// OpenFreeMap · Valhalla" explanation lives in Settings → "À propos des
/// données" (see `AboutDataTile`), reachable independently of the map.
/// Public (not `_`-prefixed) so it can be pumped in isolation — see
/// `map_screen_widgets_test.dart`.
class MapAttribution extends StatelessWidget {
  const MapAttribution({super.key});

  @override
  Widget build(BuildContext context) => Text(
    kMapAttribution,
    style: Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
    ),
  );
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
///
/// [remaining] enriches the banner with what is left of a route-bound trip
/// (« 2,4 km · ~32 min », `guidance_text.formatRemaining`) — null for a free
/// trip, or before the estimator has anything to report. [arrived] puts
/// Terminer forward as the primary (yellow) action instead of the plain
/// ink/paper one recording otherwise uses, per the brief's « bouton
/// Terminer mis en avant » at arrival.
///
/// Public (not `_`-prefixed) so it is reachable from a widget test —
/// fix-round finding: on a 360-411 dp phone, three `headlineSmall` stats
/// side by side plus Terminer overflowed the Row (`RenderFlex` overflow)
/// once `remaining` shipped. Distance/duration now share a
/// `Flexible`+`FittedBox` pair that scales down rather than overflows under
/// width pressure; `remaining` — the widest of the three, and the one most
/// likely to run long (a two-digit ETA) — moved to its own line below
/// instead of competing with the other two for the same row.
/// `test/map/map_screen_widgets_test.dart` pumps this at a 360 dp width
/// with long values to keep it that way.
class StatsBanner extends StatelessWidget {
  const StatsBanner({
    super.key,
    required this.distanceKm,
    required this.elapsed,
    this.remaining,
    this.arrived = false,
    required this.onStop,
  });
  final double distanceKm;
  final String elapsed;
  final String? remaining;
  final bool arrived;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remainingLabel = remaining;
    Widget shrinkable(String value) => Flexible(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: _Stat(value: value, theme: theme),
      ),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      shrinkable('${distanceKm.toStringAsFixed(2)} km'),
                      const SizedBox(width: 20),
                      shrinkable(elapsed),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: arrived
                      ? null // the theme's default primary (yellow) button.
                      : ElevatedButton.styleFrom(
                          backgroundColor: theme.colorScheme.onSurface,
                          foregroundColor: theme.colorScheme.surface,
                        ),
                  onPressed: onStop,
                  child: const Text('Terminer'),
                ),
              ],
            ),
            if (remainingLabel != null) ...[
              const SizedBox(height: 4),
              _Stat(value: remainingLabel, theme: theme),
            ],
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
          Text(
            'Démarrer un trajet',
            style: Theme.of(context).textTheme.titleMedium,
          ),
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
