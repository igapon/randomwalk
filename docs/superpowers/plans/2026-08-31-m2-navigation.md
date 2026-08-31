# M2 Navigation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transformer le trajet enregistré de M1 en vraie navigation turn-by-turn qui fonctionne écran éteint : instruction courante et distance à la manœuvre dans la notification, alertes vibrées, TTS français optionnel, recalcul automatique hors-ligne en cas d'écart, ETA, économie batterie — le tout validé par un harnais de rejeu de traces GPX.

**Architecture:** Un `RouteFollower` pur Dart (projection sur la polyline, manœuvres, écart, arrivée) tourne DANS l'isolate du foreground service existant (`TripTaskHandler`), alimenté par les fixes GPS qu'il reçoit déjà ; ses résultats voyagent vers l'UI par le `TripSnapshot` persisté/pollé existant (champs nav ajoutés, rétro-compatibles). Le recalcul hors-ligne exige que le moteur Valhalla soit joignable depuis l'isolate du service : les MethodChannels custom (`ValhallaChannel`, `DeviceChannel`) sont convertis en vrais `FlutterPlugin` enregistrés sur tous les engines. Les tests unitaires pilotent le follower par rejeu de traces GPX committées.

**Tech Stack:** Dart pur pour le follower/géométrie ; flutter_foreground_task (notification updates, isolate) ; flutter_local_notifications (alertes manœuvre, son+vibration) ; flutter_tts (fr) ; package xml (parsing GPX de test) ; Kotlin (FlutterPlugin refactor).

## Global Constraints

- Base : master au tag `v0.1.0-m1` (repo igapon/randomwalk, branche de travail `m2-navigation`).
- Valhalla épinglé 3.6.2 des deux côtés — inchangé. AAR `io.github.rallista:valhalla-mobile:0.6.3`.
- Écrans/overlays : insets Android bas obligatoires (SafeArea/viewPadding), gestuel ET 3 boutons. UI en français ; code/commentaires/commits en anglais (Conventional Commits).
- Thème « balisage » : tokens de `app/lib/theme/tokens.dart` uniquement (jamais de blanc sur jaune ; Bricolage pour les gros chiffres via les styles existants).
- TDD : tout comportement non trivial naît d'un test qui échoue. Le follower et le recalcul sont validés par REJEU GPX (fixtures committées) — pas seulement par des points synthétiques isolés.
- Environnement : builds Gradle locaux IMPOSSIBLES sur ce poste ; `flutter analyze`/`flutter test` locaux ; vérification build/émulateur = CI GitHub (4 jobs, `gh run watch`, re-run acceptable sur échec transitoire du job integration).
- Interfaces M1 à consommer telles quelles (ne pas casser) : `RouteResult {shape List<(double,double)>, distanceKm, duration, maneuvers List<Maneuver{instruction, lengthKm, beginShapeIndex}>}` ; `TripSnapshot` (JSON persisté, champs optionnels rétro-compatibles — modèle : `gpsSilent`) ; `TripTaskHandler` dans `app/lib/tracking/tracking_service.dart` ; `TripController` (adopt/poll/restore) ; `ChannelRoutingEngine {init(tileDirPath), route(RouteRequest)}` ; `CoverageRepository.ensureCoverage` (fallback manifeste en cache = chemin offline).
- Navigation = trajets « route-bound » uniquement (Démarrer sur un itinéraire planifié) ; les sessions libres gardent le comportement M1.
- Seuils spec : écart >30 m pendant >10 s → recalcul ; arrivée = <25 m du point final ; alerte manœuvre à 80 m (marche) / 200 m (vélo).

## Structure des fichiers

```
app/lib/nav/polyline_math.dart      géométrie pure (projection, cumuls) — aucune dépendance Flutter
app/lib/nav/route_follower.dart     RouteFollower + NavUpdate
app/lib/nav/eta.dart                estimateur de vitesse EMA + ETA
app/lib/nav/guidance_text.dart      formatage FR des textes notification/carte
app/lib/nav/tts.dart                façade TTS (injectable, no-op par défaut)
app/test/nav/…                      tests unitaires + harnais GPX
app/test/nav/fixtures/*.gpx         traces committées (nominale, jitter, écart, tunnel)
app/test/support/gpx.dart           parseur GPX de test (package xml)
app/android/…/RandomwalkPlugin.kt   FlutterPlugin englobant Valhalla+Device channels
app/lib/tracking/tracking_service.dart   (modif) follower + replan + alertes + GPS adaptatif
app/lib/tracking/trip_snapshot.dart      (modif) champs nav optionnels
app/lib/map/map_screen.dart / session_screen.dart  (modif) carte de navigation, ETA
app/lib/settings/settings_screen.dart    (modif) toggle TTS + volume guidage
```

---

### Task 1: Géométrie de suivi (`polyline_math.dart`, TDD pur Dart)

**Files:**
- Create: `app/lib/nav/polyline_math.dart`
- Test: `app/test/nav/polyline_math_test.dart`

**Interfaces:**
- Produces (consommé par Task 2) :
  - `class RouteGeometry { RouteGeometry(List<(double,double)> shape); final List<double> cumulativeKm; double get totalKm; }`
  - `class Projection { final int segmentIndex; final double t; final double crossTrackM; final double alongKm; }`
  - `Projection projectOntoRoute(RouteGeometry g, double lat, double lon, {int searchFrom = 0, int searchWindow = 40})`
  - `double metersBetween(double lat1, double lon1, double lat2, double lon2)` (haversine, réutilise la constante 6371.0 comme `recorder.dart`)

- [ ] **Step 1: Écrire les tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/nav/polyline_math.dart';

void main() {
  // Segment ~nord-sud de 111 m à Lausanne, puis virage est.
  final shape = <(double, double)>[
    (46.5200, 6.6300),
    (46.5210, 6.6300), // ~111 m
    (46.5210, 6.6315), // ~115 m vers l'est
  ];
  final g = RouteGeometry(shape);

  test('cumulative distances are monotonic and total is coherent', () {
    expect(g.cumulativeKm.first, 0);
    expect(g.cumulativeKm.length, shape.length);
    expect(g.totalKm, closeTo(0.226, 0.01));
  });

  test('point beside the first segment projects onto it', () {
    // 46.5205,6.6302 : à mi-hauteur du segment 0, ~15 m à l'est
    final p = projectOntoRoute(g, 46.5205, 6.6302);
    expect(p.segmentIndex, 0);
    expect(p.t, closeTo(0.5, 0.05));
    expect(p.crossTrackM, closeTo(15, 3));
    expect(p.alongKm, closeTo(0.0555, 0.005));
  });

  test('point past the end clamps to the last vertex', () {
    final p = projectOntoRoute(g, 46.5210, 6.6320);
    expect(p.segmentIndex, 1);
    expect(p.t, 1.0);
    expect(p.alongKm, closeTo(g.totalKm, 1e-9));
  });

  test('searchFrom biases forward on overlapping return paths', () {
    // Boucle aller-retour sur le même tronçon : projeté près du départ,
    // mais searchFrom force la seconde passe.
    final loop = RouteGeometry([
      (46.5200, 6.6300), (46.5210, 6.6300), (46.5200, 6.6300),
    ]);
    final back = projectOntoRoute(loop, 46.52045, 6.63005, searchFrom: 1);
    expect(back.segmentIndex, 1);
  });
}
```

- [ ] **Step 2: FAIL** — `flutter test test/nav/polyline_math_test.dart` (fichier absent).

- [ ] **Step 3: Implémenter**

```dart
import 'dart:math' as math;

const _earthRadiusKm = 6371.0;

double metersBetween(double lat1, double lon1, double lat2, double lon2) {
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * _earthRadiusKm * 1000 * math.asin(math.sqrt(a.toDouble()));
}

/// Local equirectangular projection: adequate for sub-km route segments.
(double x, double y) _toLocalMeters(
    double lat, double lon, double refLat, double refLon) {
  final x = (lon - refLon) * 111320.0 * math.cos(refLat * math.pi / 180);
  final y = (lat - refLat) * 110540.0;
  return (x, y);
}

class RouteGeometry {
  final List<(double, double)> shape;
  late final List<double> cumulativeKm;
  RouteGeometry(this.shape)
      : assert(shape.length >= 2, 'route shape needs at least 2 points') {
    final cum = List<double>.filled(shape.length, 0);
    for (var i = 1; i < shape.length; i++) {
      cum[i] = cum[i - 1] +
          metersBetween(shape[i - 1].$1, shape[i - 1].$2, shape[i].$1,
                  shape[i].$2) /
              1000.0;
    }
    cumulativeKm = cum;
  }
  double get totalKm => cumulativeKm.last;
}

class Projection {
  final int segmentIndex;
  final double t; // 0..1 along the segment
  final double crossTrackM;
  final double alongKm;
  const Projection(
      {required this.segmentIndex,
      required this.t,
      required this.crossTrackM,
      required this.alongKm});
}

Projection projectOntoRoute(RouteGeometry g, double lat, double lon,
    {int searchFrom = 0, int searchWindow = 40}) {
  final start = searchFrom.clamp(0, g.shape.length - 2);
  final end = math.min(start + searchWindow, g.shape.length - 2);
  Projection? best;
  for (var i = start; i <= end; i++) {
    final a = g.shape[i];
    final b = g.shape[i + 1];
    final (px, py) = _toLocalMeters(lat, lon, a.$1, a.$2);
    final (bx, by) = _toLocalMeters(b.$1, b.$2, a.$1, a.$2);
    final segLen2 = bx * bx + by * by;
    final t = segLen2 == 0
        ? 0.0
        : ((px * bx + py * by) / segLen2).clamp(0.0, 1.0);
    final dx = px - t * bx;
    final dy = py - t * by;
    final cross = math.sqrt(dx * dx + dy * dy);
    if (best == null || cross < best.crossTrackM) {
      final segKm = g.cumulativeKm[i + 1] - g.cumulativeKm[i];
      best = Projection(
          segmentIndex: i,
          t: t,
          crossTrackM: cross,
          alongKm: g.cumulativeKm[i] + t * segKm);
    }
  }
  return best!;
}
```

- [ ] **Step 4: PASS** — 4 tests verts, `flutter analyze` 0.
- [ ] **Step 5: Commit** — `feat(nav): route geometry projection math`

---

### Task 2: RouteFollower + ETA (TDD, cœur de M2)

**Files:**
- Create: `app/lib/nav/route_follower.dart`, `app/lib/nav/eta.dart`
- Test: `app/test/nav/route_follower_test.dart`

**Interfaces:**
- Consumes: Task 1 (`RouteGeometry`, `projectOntoRoute`) ; `RouteResult`/`Maneuver` de `app/lib/valhalla/models.dart`.
- Produces (consommé par Tasks 3/5/6/7) :
  - `class NavUpdate { final double snappedLat, snappedLon; final double alongKm, remainingKm, crossTrackM; final int maneuverIndex; final String instruction; final double distanceToManeuverM; final bool offRoute; final bool arrived; final Duration? eta; }`
  - `class RouteFollower { RouteFollower(RouteResult route, {double offRouteThresholdM = 30, Duration offRouteGrace = const Duration(seconds: 10), double arrivalRadiusM = 25, SpeedEstimator? speed}); NavUpdate update(double lat, double lon, DateTime time); }`
  - `class SpeedEstimator { SpeedEstimator({double halfLife = 30}); void add(double speedMps, DateTime time); double? get speedMps; }` (EMA ; `eta = remaining / speed`, null tant que < 3 échantillons)

Comportements contraignants (chacun a son test) :
1. La manœuvre courante = première `Maneuver` dont la position (cumul au `beginShapeIndex`) est strictement devant `alongKm` ; `distanceToManeuverM` = distance restante jusqu'à elle ; à la dernière manœuvre, `distanceToManeuverM` vise la fin de route.
2. Progression monotone : le follower repart de `segmentIndex` précédent (searchFrom = lastIndex, window 40) — jamais de saut en arrière > 2 segments même sur tracé auto-croisant.
3. `offRoute` passe à true seulement si `crossTrackM > 30` sans interruption pendant > 10 s (horodatages des updates, pas d'horloge murale) ; revient à false dès un fix < 30 m.
4. `arrived` = distance au dernier point < 25 m ET `maneuverIndex` sur la dernière manœuvre ; une fois arrivé, reste arrivé.
5. Fix aberrant (crossTrack > 200 m un seul échantillon) : l'update le signale (`crossTrackM`) mais ne déplace pas `alongKm` en arrière.

- [ ] **Step 1: Tests** — écrire `route_follower_test.dart` couvrant 1-5 avec des routes synthétiques construites par un helper local `RouteResult syntheticRoute(List<(double,double)> shape, List<(int,String)> maneuvers)` (construit des `Maneuver(instruction, lengthKm: 0, beginShapeIndex)`) ; timestamps espacés d'une seconde. FAIL d'abord.
- [ ] **Step 2: Implémenter** `route_follower.dart` + `eta.dart` (EMA : `speed = speed*f + sample*(1-f)` avec `f = exp(-dt/halfLife)`), 5+ tests PASS, analyze 0.
- [ ] **Step 3: Commit** — `feat(nav): route follower with off-route, arrival and eta`

---

### Task 3: Harnais de rejeu GPX + fixtures

**Files:**
- Create: `app/test/support/gpx.dart`, `app/test/nav/gpx_replay_test.dart`, fixtures `app/test/nav/fixtures/{nominal.gpx,jitter.gpx,detour.gpx,tunnel.gpx}`
- Modify: `app/pubspec.yaml` (dev_dependency `xml: ^6.5.0`)

**Interfaces:**
- Consumes: Task 2 (`RouteFollower`, `NavUpdate`).
- Produces: `List<GpxPoint> parseGpx(String xml)` avec `class GpxPoint { final double lat, lon; final DateTime time; final double? speedMps; }` ; fixtures générées par le script inline du Step 1 (déterministes, committées).

- [ ] **Step 1: Générer les fixtures** — écrire un petit générateur `app/test/support/make_fixtures.dart` (exécutable `dart run`) qui produit les 4 GPX à partir d'une route de référence codée en dur (20 points, ~1,5 km, 3 virages) : `nominal` (sur la route, 1,4 m/s), `jitter` (bruit gaussien ±8 m, graine fixe 42), `detour` (quitte la route au point 8, 60 m à l'écart pendant 90 s, revient), `tunnel` (trou de 45 s sans points au milieu). Committer générateur ET fixtures.
- [ ] **Step 2: Parseur GPX + tests de rejeu** — `gpx_replay_test.dart` rejoue chaque fixture dans un `RouteFollower` construit sur la route de référence et vérifie le scénario : nominal → jamais offRoute, arrived à la fin, manœuvres dans l'ordre sans régression d'index ; jitter → jamais offRoute (le bruit reste < 30 m), distance à la manœuvre strictement décroissante entre manœuvres ; detour → offRoute déclenché entre 10 et 20 s après l'écart, retombe après le retour ; tunnel → pas de fausse arrivée, reprise propre après le trou. FAIL → PASS.
- [ ] **Step 3: Commit** — `test(nav): gpx replay harness with four trace fixtures`

---

### Task 4: Channels natifs en FlutterPlugin (service isolate ready)

**Files:**
- Create: `app/android/app/src/main/kotlin/fr/lmqc/randomwalk/RandomwalkPlugin.kt`
- Modify: `app/android/app/src/main/kotlin/fr/lmqc/randomwalk/MainActivity.kt`, `ValhallaChannel.kt`, `DeviceChannel.kt`

**Interfaces:**
- Consumes: canaux existants `randomwalk/valhalla` (init/route) et device (pas) — lire les fichiers actuels avant refactor.
- Produces: les MÊMES canaux, mais disponibles dans TOUT FlutterEngine du process (y compris celui de flutter_foreground_task), via un `FlutterPlugin` enregistré par le mécanisme standard (`flutterEngine.plugins.add(RandomwalkPlugin())` dans une subclass d'Application ou via l'enregistrement auto — vérifier le mécanisme que flutter_foreground_task utilise pour les plugins de l'app : les plugins du registry GeneratedPluginRegistrant sont enregistrés sur l'engine du service ; un plugin local ajouté manuellement dans MainActivity ne l'est PAS — la solution robuste : déclarer RandomwalkPlugin comme plugin Flutter local (dans le pubspec de l'app via `plugin` dir ou enregistrement dans une Application custom `configureFlutterEngine`-équivalente). Choisir la voie vérifiée dans la doc flutter_foreground_task et la documenter dans le rapport).
- Contrainte : l'acteur Valhalla reste UN par engine (chaque isolate a le sien, tile_dir identique) ; teardown par engine (onDetachedFromEngine).

- [ ] **Step 1:** Lire flutter_foreground_task (pub cache/docs) : comment les plugins sont enregistrés sur l'engine du service ; choisir et noter le mécanisme.
- [ ] **Step 2:** Refactor Kotlin : `RandomwalkPlugin : FlutterPlugin` qui instancie/attache ValhallaChannel + DeviceChannel dans `onAttachedToEngine` et les dispose dans `onDetachedFromEngine` ; MainActivity ne fait plus l'enregistrement manuel (ou le délègue).
- [ ] **Step 3:** Vérifier : `flutter analyze`/`test` inchangés ; push provisoire autorisé pour valider via CI que le job integration (qui exerce le canal valhalla depuis l'UI) reste vert.
- [ ] **Step 4: Commit** — `refactor(android): expose valhalla and device channels to all engines`

---

### Task 5: Navigation dans le service (follower + notification + recalcul offline)

**Files:**
- Modify: `app/lib/tracking/trip_snapshot.dart` (champs nav), `app/lib/tracking/tracking_service.dart` (follower + replan), `app/lib/trip/trip_controller.dart` (seed navigation), `app/lib/trip/active_route_store.dart` (si le seed doit porter la shape complète)
- Test: `app/test/tracking/nav_in_service_test.dart` (+ extensions trip_snapshot_test)

**Interfaces:**
- Consumes: Tasks 2/4 ; seed de démarrage du service (déjà porté par TripController.startTrip) ; `ChannelRoutingEngine` (utilisable dans l'isolate après Task 4).
- Produces:
  - `TripSnapshot` étendu (tous optionnels, défauts rétro-compatibles, même pattern que `gpsSilent`) : `String? navInstruction; double? navDistanceToManeuverM; double? navRemainingKm; int? navEtaSeconds; bool navOffRoute (default false); bool navArrived (default false); int navReplanCount (default 0);`
  - Le seed du service porte : route shape+maneuvers sérialisées (JSON du RouteResult — ajouter `RouteResult.toJson/fromJson` dans `app/lib/valhalla/models.dart` avec test round-trip), destination lat/lon, profil, tileDirPath.
  - Handler : à chaque fix accepté → `follower.update` → snapshot nav + texte notification `« ↰ Rue de Bourg · 120 m » / ligne 2 « 2,4 km restants · 32 min »` (via `guidance_text.dart`, Task 7 fournit le formatteur — pour cette task, format minimal inline) ; si `offRoute` → recalcul : `engine.init(tileDirPath)` (une fois, lazy) puis `engine.route(RouteRequest(from: fix, to: destination, profile))` → nouveau follower + `navReplanCount++` ; échec de recalcul (hors couverture) → notification « Itinéraire perdu — revenez sur le tracé » sans crash, retry au plus 1×/30 s.
- Logique extraite testable : `class NavigationRuntime { NavigationRuntime({required RouteFollower follower, required Future<RouteResult?> Function(double lat, double lon) replan, DateTime Function()? now}); Future<NavSnapshotFields> onFix(double lat, double lon, double speedMps, DateTime time); }` — unit-testée avec un replan fake (déclenchement à l'écart, backoff 30 s, compteur, texte).

- [ ] **Step 1:** Tests de `NavigationRuntime` (déclenchement replan sur offRoute, backoff, arrivée stoppe le suivi, champs snapshot) + round-trip `RouteResult.toJson/fromJson` + rétro-compat snapshot (vieux JSON sans champs nav). FAIL.
- [ ] **Step 2:** Implémenter (runtime pur, snapshot, seed, branchement handler, notification).
- [ ] **Step 3:** `flutter analyze` 0, suite complète verte ; push ; CI 4 jobs verts.
- [ ] **Step 4: Commit(s)** — `feat(nav): turn-by-turn navigation inside the tracking service`

---

### Task 6: Alertes manœuvre (vibration/son) + TTS français optionnel

**Files:**
- Create: `app/lib/nav/tts.dart`
- Modify: `app/lib/tracking/tracking_service.dart` (alertes), `app/lib/settings/settings_screen.dart` (toggles), `app/pubspec.yaml` (`flutter_local_notifications`, `flutter_tts`)
- Test: `app/test/nav/alert_policy_test.dart`

**Interfaces:**
- Produces: `class AlertPolicy { AlertPolicy({required RoutingProfile profile}); bool shouldAlert(NavUpdate u); }` — alerte quand `distanceToManeuverM` franchit 80 m (walk) / 200 m (bike), UNE fois par manœuvre, réarmée à la manœuvre suivante ; alerte spéciale à `offRoute` (transition) et `arrived`.
- Alertes émises depuis le handler : notification `flutter_local_notifications` haute priorité canal « guidage » (son système + vibration), texte = instruction. TTS : façade `TtsSpeaker { Future<void> speak(String text); }` implémentée sur flutter_tts (fr-FR, init lazy) — VÉRIFIER si flutter_tts fonctionne dans l'isolate du service (recherche + test manuel émulateur si possible) ; si non fiable : TTS seulement quand l'UI est attachée (documenter), les notifications restant la voie garantie écran éteint.
- Réglages : toggles « Guidage vocal » et « Vibrations » (shared_preferences `tts_enabled`, `haptics_enabled`, défauts true), lus par le handler au seed + rafraîchis via le canal de données existant.

- [ ] **Step 1:** Tests `AlertPolicy` (franchissement, une-fois-par-manœuvre, réarmement, profils, offRoute/arrived). FAIL → implémentation → PASS.
- [ ] **Step 2:** Brancher notifications+TTS dans le handler ; réglages ; analyze/test verts ; push ; CI verte.
- [ ] **Step 3: Commit** — `feat(nav): maneuver alerts and optional french tts`

---

### Task 7: UI de navigation (carte + ETA + arrivée) et GPS adaptatif

**Files:**
- Create: `app/lib/nav/guidance_text.dart` (+ test)
- Modify: `app/lib/map/map_screen.dart`, `app/lib/session/session_screen.dart`, `app/lib/tracking/tracking_service.dart` (GPS adaptatif)

**Interfaces:**
- Consumes: champs nav du `TripSnapshot` (déjà livrés à l'UI par le canal/poll existant).
- Produces:
  - `guidance_text.dart` : `String formatManeuver(String instruction, double distanceM)` (« Dans 120 m, tournez à gauche » — arrondi 10 m sous 100 m, 50 m au-dessus), `String formatRemaining(double km, Duration? eta)` (« 2,4 km · ~32 min », virgule française) — testés.
  - Carte en trajet route-bound : carte d'instruction en HAUT (SafeArea top, thème encre/papier, instruction en Schibsted 18, distance en Bricolage 28), bandeau bas existant enrichi (restant + ETA) ; à `navOffRoute` : carte orange « Recalcul… » ; à `navArrived` : carte « Arrivé ! » + bouton Terminer mis en avant ; la polyline du NOUVEL itinéraire remplace l'ancienne après recalcul (l'UI détecte `navReplanCount` et redemande la route courante au service via le seed/payload — le service publie la nouvelle shape encodée dans le snapshot : ajouter `String? navRouteShapeEnc` (polyline6, réutiliser `encodePolyline6ForTest` promu en `encodePolyline6` public dans models.dart) que l'UI décode et redessine).
  - GPS adaptatif (handler) : `LocationSettings.distanceFilter` 3 m quand `distanceToManeuverM < 500`, 12 m au-delà ; changement = resouscription du stream (au plus 1×/60 s pour éviter le churn) ; session libre inchangée (3 m).
- [ ] **Step 1:** Tests `guidance_text` + promotion `encodePolyline6` (déplacer hors du helper test, round-trip déjà testé). FAIL → PASS.
- [ ] **Step 2:** UI + GPS adaptatif ; adapter les tests widgets existants ; analyze/test verts ; push ; CI verte (integration incluse).
- [ ] **Step 3: Commit** — `feat(nav): navigation ui with eta, arrival and adaptive gps`

---

### Task 8: Vague backlog M1 (durcissement)

**Files:**
- Modify: `app/lib/coverage/coverage_repository.dart`, `app/lib/coverage/manifest.dart`, `app/lib/map/map_screen.dart`, `app/lib/valhalla/engine_channel.dart`, `app/assets/valhalla_config.json`, `randomwalk-tiles/.github/workflows/build-tiles.yml` (repo frère), `app/android/app/build.gradle.kts`
- Test: extensions des tests coverage/engine existants

Chaque point = un test (quand testable) + fix :
1. **Garde valhalla_version** : constante `kExpectedValhallaVersion = '3.6.2'` ; `ensureCoverage` rejette (exception typée `DatasetVersionMismatch` → SnackBar « Mise à jour de l'app requise pour les nouvelles cartes ») un manifeste dont `valhalla_version != attendu` ; le manifeste en cache reste utilisable.
2. **failed > 0 surfacé** : `CoverageResult.failed > 0` → bandeau carte « Couverture incomplète — certaines zones peuvent manquer » (une fois par session de planification).
3. **Accumulation disque** : purge-by-count inconditionnelle — ne garder que les 2 répertoires de version les plus récents dont au moins un tile présent, même si `failed > 0` (le répertoire actif/du cache n'est jamais supprimé).
4. **Config valhalla assainie** : retirer de `assets/valhalla_config.json` les chemins serveurs morts (`/data/valhalla/*`, ipc `/tmp/*`), `max_cache_size` 268435456 (256 Mo), `id_table_size` proportionné — vérifier que le test d'intégration CI passe toujours (c'est LA validation).
5. **engine_channel** : réponse null → `RoutingException('empty engine reply')` ; `MissingPluginException` catchée → `RoutingException`.
6. **http.Client** : fermer les clients possédés (Coverage/leaderboard) via dispose des providers.
7. **Attribution carte** : petit texte « OpenFreeMap © OpenMapTiles » demi-transparent bas-gauche (inset-safe), lien réglages « À propos des données ».
8. **Workflow tuiles** : étape de garde `if [ $(ls assets | wc -l) -gt 950 ]; then echo '::error::asset count'; exit 1; fi` avant la release (repo randomwalk-tiles, committer+pousser là-bas).
9. **Réglages batterie constructeur** (spec §6) : dans Réglages, tuile « Suivi fiable en arrière-plan » qui détecte les constructeurs agressifs (Build.MANUFACTURER ∈ {xiaomi, oppo, vivo, oneplus, huawei, samsung}) et ouvre les réglages batterie de l'app (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` intent ou page d'info) avec texte explicatif français.
10. **Signature release** : générer un keystore upload local `%USERPROFILE%\randomwalk-upload.jks` (keytool, alias upload, mot de passe stocké dans `app/android/key.properties` NON committé + `.gitignore`), brancher `signingConfigs.release` classique dans build.gradle.kts avec fallback debug si key.properties absent (CI reste verte sans secret). Documenter dans `docs/release-signing.md`.

- [ ] **Step 1:** tests + fixes 1-6 (TDD), analyze/test verts.
- [ ] **Step 2:** 7-9 + push des deux repos ; CI verte des deux côtés.
- [ ] **Step 3: Commits** — `fix(coverage): dataset guards and disk hygiene`, `feat(map): data attribution`, `chore(release): upload signing config`, `ci(tiles): asset count gate`.

---

## Definition of Done (M2)

- [ ] Rejeu GPX : 4 scénarios verts (nominal, jitter, écart→recalcul, tunnel).
- [ ] CI 4 jobs verts sur la branche puis sur master ; test d'intégration émulateur toujours vert (tuiles prod).
- [ ] Écran éteint (QA device propriétaire) : navigation continue — notification mise à jour, vibration aux manœuvres, TTS si activé.
- [ ] Écart volontaire de l'itinéraire (QA device) : recalcul automatique < 15 s, nouvelle polyline affichée au retour sur l'app.
- [ ] Arrivée : carte « Arrivé ! », alerte, Terminer met fin proprement (km bancarisés une fois).
- [ ] Backlog M1 : les 9 points fermés.
- [ ] QA M1 restante rejouée sur la nouvelle APK (checklist device du rapport M1).

**Addendum Task 7 (QA device propriétaire, 2026-08-31) — exigences contraignantes :**
1. Caméra initiale : dernière position connue si disponible (Geolocator.getLastKnownPosition, sans prompt), sinon Genève (46.2044, 6.1432) — plus jamais Lausanne codé en dur.
2. Point de position invisible avant un app-switch : (ré)activer la couche localisation de MapLibre après l'octroi de la permission / à la première position obtenue (toggler myLocationEnabled ou recréer le layer), tester le parcours « fraîche installation → permission accordée → point visible sans quitter l'app ».
3. Carte incontrôlable en navigation : le camera-follow doit être LIBÉRÉ par tout geste utilisateur (onCameraTrackingDismissed ou détection de geste → tracking none) ; bouton « recentrer » (glyphe losange, inset-safe) pour réengager le suivi ; le service continue la navigation indépendamment de l'état caméra.
