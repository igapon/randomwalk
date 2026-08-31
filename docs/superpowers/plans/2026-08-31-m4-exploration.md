# M4 Exploration & Jeu — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Le mode aventure : rues déjà parcourues (map-matching embarqué), fog of war révélé en marchant, landmarks réels (églises/tours = révélation, banques/ATM = pièces, restaurants/cafés = énergie), XP/niveaux/badges/streaks, % d'exploration, et un mode de planification « Explorer » qui tire les boucles vers l'inconnu. Le jeu ne bloque JAMAIS l'outil.

**Architecture:** La vérité terrain de l'exploration est l'**edge OSM** : chaque trajet terminé est map-matché sur l'appareil (`trace_attributes` de l'acteur Valhalla, exposé par notre canal) → ids d'edges parcourus, stockés en SQLite (sqflite). L'affichage et les agrégats utilisent une **grille de cellules ~150 m** (quantification pure Dart, réutilisant le pattern de repeated_segments — H3 remplacé par cette grille documentée : zéro dépendance native, suffisant pour l'agrégation locale ; conversion H3 possible en M5 côté serveur). Le fog = couche MapLibre (GeoJSON de cellules révélées, mise à jour incrémentale). Les POIs jeu sont extraits par le cron du repo tuiles (osmium tags-filter) et livrés comme asset de la Release, téléchargés avec la couverture. Les visites (geofence 25 m + 5 s) sont détectées dans le service. TOUT l'état jeu (visites, pièces, énergie, XP, badges, streaks, edges) passe par un **journal d'événements append-only** (fichier JSONL + réducteurs purs) — la fondation de la sync M5.

**Tech Stack:** Dart pur (réducteurs, grille, geofence) ; sqflite (edges) ; Kotlin (trace_attributes sur le canal existant) ; osmium (tiles repo) ; MapLibre GeoJSON layers.

## Global Constraints

- Base : master `v0.3.0-m3` (branche `m4-exploration`). Valhalla 3.6.2. TDD ; CI 4 jobs verts par push (polling FOREGROUND uniquement) ; gradle local impossible.
- **Le jeu ne bloque jamais l'outil** : navigation/boucles/sessions restent 100 % fonctionnelles si le jeu échoue (POIs absents, journal corrompu → l'app marche, le jeu se désactive gracieusement).
- Journal d'événements (spec §5) : JSONL append-only `game_events.jsonl` (app support dir), événements `{id: uuid, ts: iso8601, type, payload}` ; état recalculé par réducteurs purs ; écriture atomique append ; relecture au démarrage avec tolérance aux lignes corrompues (skip + log). Types M4 : edge_covered_batch, cell_revealed, landmark_visited, coins_earned, coins_spent, energy_changed, xp_earned, badge_unlocked, streak_updated.
- Économie spec §4.6 : pièces banques/ATM cooldown 24 h/lieu, rendement décroissant (100/50/25/10 pièces aux visites successives d'un même lieu, plancher 10) ; énergie 0-100, −4/km en aventure, +40 restaurant/+25 café (cooldown 6 h/lieu) ; XP : +10/km, +5/cellule révélée, +25/landmark, +50/boucle terminée ; multiplicateur énergie : ≥60 → ×1.5, ≥20 → ×1.0, <20 → ×0.5 (JAMAIS un blocage) ; niveaux : seuil n → 100·n^1.5 XP cumulés ; badges v1 : premier trajet, première boucle, 10/50/100 km cumulés, 10 landmarks, streak 7 jours, 25 % d'un « quartier » (grille 8×8 cellules).
- Révélation : corridor 75 m autour des traces (cellules ~150 m intersectées) ; sync points (place_of_worship, tourism=viewpoint, man_made=tower, historic=*) révèlent rayon 400 m ; fog rendu uniquement dans l'onglet Aventure (la carte outil reste claire).
- POIs (repo tuiles) : osmium tags-filter sur le pbf ch-fr → JSON compact {id osm, type jeu (reveal|coins|energy), lat, lon, name?} gzippé, asset `pois.json.gz` + entrée manifeste `pois` {asset, bytes, sha256} (rétro-compat : clé optionnelle, vieux manifestes OK).
- UI : 4e onglet « Aventure » (losange), thème balisage (fog = encre 60 % ; révélé = transparent ; landmarks = losanges par type : jaune reveal / hydro coins / terre energy #B0552F à ajouter aux tokens) ; insets ; français.
- Interfaces M1-M3 intactes ; sessions libres/nav identiques hors ajout du hook de visite/edge.

## Structure des fichiers

```
randomwalk-tiles/.github/workflows/build-tiles.yml   (modif) étape POIs
app/lib/game/events.dart            GameEvent + journal (append/replay)
app/lib/game/reducers.dart          état jeu pur (wallet, energy, xp, badges, streaks)
app/lib/game/grid.dart              cellules ~150 m (quantification, corridor, quartiers)
app/lib/game/reveal.dart            état de révélation + geojson du fog
app/lib/game/pois.dart              POI store (download+parse+index spatial simple)
app/lib/game/visits.dart            geofence/dwell + attribution récompenses (pur)
app/lib/exploration/matcher.dart    trace_attributes → edge ids (via canal)
app/lib/exploration/edges_store.dart  SQLite edges couverts
app/lib/exploration/explore_planner.dart  biais waypoints vers cellules non couvertes
app/lib/adventure/adventure_screen.dart  onglet Aventure (fog, HUD, badges)
app/android/…/ValhallaChannel.kt    (modif) méthode trace_attributes
```

---

### Task 1: Journal d'événements + réducteurs (TDD pur, fondation)
**Files:** app/lib/game/events.dart, reducers.dart + tests.
**Produces:** `class GameEvent {String id; DateTime ts; String type; Map payload;}` ; `class GameJournal {Future<void> append(GameEvent); Stream<GameEvent> replay(); }` (fichier JSONL, append atomique, relecture tolérante) ; `class GameState {int coins; double energy; int xp; int level; Set<String> badges; int streakDays; DateTime? lastActivityDay;}` + `GameState reduceAll(Iterable<GameEvent>)` avec TOUTES les règles économiques des Global Constraints (chacune testée : cooldowns par lieu, rendement décroissant, multiplicateur énergie, niveaux, chaque badge, streak avec jours manqués). Réducteurs 100 % purs (horloge dans les événements).

### Task 2: Grille + révélation (TDD pur)
**Files:** app/lib/game/grid.dart, reveal.dart + tests.
**Produces:** `CellId {int x, y}` (~150 m, quantification cohérente réf. latitude comme repeated_segments) ; `Set<CellId> corridorCells(List<(double,double)> shape, {double radiusM = 75})` ; `Set<CellId> discCells(double lat, double lon, double radiusM)` ; `String revealedGeoJson(Set<CellId>)` (MultiPolygon des cellules NON révélées dans un viewport donné — le fog) ; quartiers = blocs 8×8, `double quartierCompletion(CellId any, Set<CellId> revealed)`.

### Task 3: trace_attributes + edges store
**Files:** ValhallaChannel.kt (+ dart engine/channel), app/lib/exploration/matcher.dart, edges_store.dart + tests (fake channel ; store sur sqflite_common_ffi en test).
**Produces:** canal `traceAttributes(configured actor, shapeJson)` → JSON (le brief d'exécution vérifiera l'API exacte de l'AAR : trace_attributes existe depuis 0.6.0) ; `matchTrace(List<(double,double)>) → List<String> edgeIds` (requête trace_attributes shape_match=map_snap, extraction edge.id/way_id) ; `EdgesStore` (sqflite) : upsert batch, count, containsAll, edgesNear? (non requis M4 — count par région suffit). Un trajet terminé → matcher (dans l'UI isolate, post-trip, best-effort) → edges + cellules → événements journal.
**Le jeu ne bloque jamais** : échec de matching → log, trajet inchangé.

### Task 4: POIs — pipeline tuiles + client
**Files:** randomwalk-tiles workflow (osmium tags-filter nwr amenity=bank,atm,restaurant,cafe,fast_food + tourism=viewpoint + man_made=tower + historic + amenity=place_of_worship → JSON compact via jq/python, gzip, asset + manifeste) ; app/lib/game/pois.dart (+ CoverageRepository : téléchargement de l'asset pois quand présent, rétro-compat sinon) + tests (fixture JSON).
**Produces:** `class GamePoi {String id; PoiKind kind; double lat, lon; String? name;}` ; `PoiStore {Future<List<GamePoi>> near(double lat, double lon, double radiusM); int get count;}` (index par cellule de grille). Un run manuel du workflow tuiles valide l'asset réel (tag prerelease interdit — la release normale du cron l'embarquera ; utiliser workflow_dispatch et vérifier l'asset).

### Task 5: Visites dans le service + récompenses
**Files:** app/lib/game/visits.dart (+ intégration TripTaskHandler), tests purs.
**Produces:** `VisitDetector {VisitDetector(List<GamePoi> pois); PoiVisit? onFix(lat, lon, DateTime);}` (25 m + dwell 5 s, un déclenchement par lieu par session, pur) ; le handler charge les POIs du voisinage au seed (kind + position), publie les visites via le snapshot (champ optionnel `pendingVisits`) ; l'UI isolate consomme → événements journal (visite + récompense selon kind/cooldowns via réducteurs). Alerte discrète (notification guidance existante) « ⚑ Château de X — +25 XP ».

### Task 6: Onglet Aventure
**Files:** app/lib/adventure/adventure_screen.dart (+ main.dart 4e onglet, tokens terre) + widget tests logiques.
**Produces:** carte MapLibre dédiée avec fog (source GeoJSON mise à jour au viewport/reveal), landmarks losanges par type (visités = remplis, non = contour), HUD compact (pièces · énergie · niveau+XP progress) inset-safe, écran badges/stats (% quartier courant, streak, km) accessible du HUD. Perf : reveal GeoJSON régénéré au plus 1×/2 s et seulement sur changement.

### Task 7: Mode « Explorer » (planification)
**Files:** app/lib/exploration/explore_planner.dart (+ plan_mode/UI : 4e mode « Explorer » avec distance) + tests.
**Produces:** biais des azimuts/waypoints du LoopPlanner : générer 8 azimuts candidats, scorer chaque direction par (cellules non révélées dans un secteur 60° au rayon cible), prendre les 3 meilleurs comme startBearing des candidats (le reste du LoopPlanner inchangé) ; candidats re-scorés avec bonus exploration (fraction de shape en cellules non révélées, poids 0.3). UI : mode Explorer = Distance + biais (même slider).

### Task 8: Vague backlog M3→M4
1. Arrival latch « sorti du rayon une fois » (route_follower — la fenêtre étroite parquée).
2. Timeouts HTTP coverage (10 s connect/30 s total sur manifest + tuiles + pois).
3. Décision dart format : ADOPTÉE — un commit standalone `style: dart format .` + étape CI `dart format --output=none --set-exit-if-changed .` dans le job flutter (fin de branche, jamais mélangé).
4. « Boucle » résiduels dans les commentaires ; progress-sink partagé (interleave cosmétique) ; A→B diversité : 3e candidat = bearing perpendiculaire du bulge (quick win, sinon documenter).
5. QA doc device consolidée M2-M4 (docs/qa-device-checklist.md) pour le propriétaire.

## Definition of Done (M4)
- [ ] Un trajet terminé marque ses edges + révèle son corridor (visible onglet Aventure au retour).
- [ ] Landmark église visité → révélation 400 m + XP ; banque → pièces avec cooldown ; restaurant → énergie.
- [ ] % quartier et badges progressent ; streak survit au redémarrage (journal relu).
- [ ] Mode Explorer propose des boucles orientées vers le non-révélé (test unitaire du biais + intégration : sur état vierge ≡ Distance).
- [ ] POIs livrés par la release tuiles (asset vérifié) ; vieux manifestes toujours acceptés.
- [ ] Jeu indisponible (pas de POIs/journal) → outil intact (test).
- [ ] CI verte ; QA device propriétaire (fog, visites réelles, HUD).
