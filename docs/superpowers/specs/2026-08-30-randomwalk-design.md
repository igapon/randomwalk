# RandomWalk — Design v1

**Date :** 2026-08-30
**Statut :** validé en brainstorming, en attente de relecture finale
**Objectif :** produit à publier sur les stores (Android d'abord, iOS en v2)

## 1. Vision

Application de navigation GPS à pied et à vélo, offline-first, avec une couche
d'exploration ludique du monde réel :

- Itinéraires A→B classiques (piéton / vélo).
- Boucles (A→A) ou routes A→B d'une **distance approximative fixée**.
- Boucles ou routes d'un **temps approximatif fixé**.
- **Mode exploration** : suivi des rues jamais parcourues, génération de routes
  vers l'inexploré.
- **Couche jeu** : fog of war, landmarks réels (églises = révélation de carte,
  banques/ATM = pièces, restaurants = énergie), XP, badges, streaks.
- Guidage écran éteint, notifications téléphone (smartwatch en v2).
- Collaboratif (heatmaps partagées, défis) prévu architecturalement, non
  construit en v1.

**Principe directeur : le jeu ne bloque jamais l'outil.** La navigation et la
carte réelle fonctionnent toujours à 100 % ; la couche jeu vit sur la carte
d'exploration (« mode aventure »).

## 2. Décisions structurantes

| Décision | Choix | Raison |
|---|---|---|
| Stack app | **Flutter** (Dart) | Un codebase Android+iOS ; natif limité au GPS background, FFI et montre |
| Carte | **MapLibre GL** (`maplibre_gl`) | Rendu vectoriel OSM, open source, support offline |
| Routage | **Valhalla embarqué** via l'AAR précompilé `io.github.rallista:valhalla-mobile` (0.6.3, Valhalla 3.6.2) piloté par MethodChannel — API JSON in/out ; FFI direct possible plus tard sans changer l'interface Dart | Offline, zéro coût serveur de routage, recalcul instantané, map-matching (Meili) inclus, pas de toolchain NDK à maintenir. Contrainte : version Valhalla identique côté build serveur (tuiles) et côté app |
| Backend | **Supabase** (Auth + Postgres/PostGIS) | Comptes + sync dès v1 ; PostGIS prêt pour le collaboratif géo |
| Données | **Local-first, SQLite (drift)** + journal d'événements synchronisé | Offline total, sync sans conflits, base du multijoueur |
| État Flutter | Riverpod | Standard, testable |
| Indexation spatiale jeu | Grille **H3** | Agrégation de couverture, comparaisons futures entre joueurs |

## 3. Architecture

```
┌─────────────────────── App Flutter ───────────────────────┐
│  UI : carte, planification, navigation, aventure, stats   │
│  Logique métier Dart (Riverpod)                           │
│  SQLite local (drift) = source de vérité                  │
├──────────── Couche native (interfaces communes) ──────────┤
│  • valhalla_ffi : routage A→B, matrice, map-matching      │
│  • location_service : foreground service Android          │
│    (type location) / background location iOS (v2)         │
│  • guidance_notifications : notification persistante,     │
│    sons/vibrations, TTS                                   │
└────────────────────────────────────────────────────────────┘
                    ↕ sync événements (en ligne)
┌────────────────── Backend Supabase ────────────────────────┐
│  Auth (email + Google/Apple) · Postgres + PostGIS          │
│  Tables miroir du journal d'événements                     │
└─────────────────────────────────────────────────────────────┘
        + dev.lmqc.fr : tuiles Valhalla statiques (build cron unique,
          téléchargées à la demande par le client) + micro-API leaderboard
        + OpenFreeMap : tuiles d'affichage MapLibre (direct client)
```

### Modules Dart (paquets internes)

| Module | Rôle | Dépend de |
|---|---|---|
| `core_events` | Journal d'événements append-only, reducers d'état | — |
| `routing` | Client Valhalla FFI, algo de boucles, scoring | valhalla_ffi |
| `navigation` | Suivi de route, instructions, détection d'écart, recalcul | routing, location |
| `exploration` | Map-matching des traces, couverture d'edges, cellules H3 | routing, core_events |
| `game` | Fog of war, landmarks, pièces, énergie, XP, badges | exploration, core_events |
| `coverage` | Cellules adaptatives : détection, téléchargement repris/vérifié, purge LRU | — |
| `sync` | Push/pull d'événements vers Supabase, file persistante | core_events |
| `ui_*` | Écrans par domaine | tous |

Chaque module expose une API publique étroite et se teste isolément.

## 4. Fonctionnalités

### 4.1 Routage A→B
Profils Valhalla `pedestrian` et `bicycle`, alternatives, instructions
turn-by-turn localisées (fr/en). Coûts ajustés pour privilégier les voies
agréables (pénalité grands axes).

UX de planification : **le départ par défaut est la position actuelle** ;
la destination se choisit par appui long sur la carte **ou par recherche
d'adresse** (barre type Google Maps — géocodage Photon/OSM en ligne, biaisé
vers la position, derrière une interface `GeocodingService` remplaçable ;
la recherche exige le réseau, le routage reste offline). Départ modifiable
manuellement.

### 4.2 Boucles et routes à distance fixe
1. Placer k points intermédiaires (2–4) sur un cercle autour du départ, azimuts
   partiellement aléatoires ; rayon initial ≈ distance_cible / 2π (boucle).
2. Router à travers, mesurer, ajuster le rayon par dichotomie (2–4 itérations,
   cible ±10 %).
3. Générer 3 candidats (jeux d'azimuts différents), scorer : écart à la cible,
   taux de segments répétés, agrément.
4. Si aucun candidat ≤ écart max après N itérations : présenter le meilleur
   avec son écart réel (« 4,2 km trouvé pour 5 km demandé »), jamais un échec sec.

Variante A→B à distance fixe : points intermédiaires placés sur une ellipse
dont A et B sont les foyers.

### 4.3 Routes à temps fixe
distance_cible = temps × vitesse estimée. Vitesse = moyenne mobile par mode
issue de l'historique utilisateur ; défauts avant historique : 4,5 km/h
(marche), 16 km/h (vélo).

### 4.4 Navigation, background, notifications
- Android : **foreground service `location`** (Kotlin), GPS 1 Hz en navigation,
  notification persistante mise à jour (instruction courante + distance),
  vibration/son à l'approche des manœuvres, TTS optionnel.
- Écart de route : > 30 m du tracé pendant > 10 s → recalcul local instantané.
- Batterie : GPS réduit à 0,2 Hz sur longs segments droits, 1 Hz près des
  manœuvres.
- État de navigation persisté en continu → restauration après kill par l'OS ;
  détection des constructeurs agressifs (Xiaomi, etc.) et guidage vers les
  réglages batterie.

### 4.5 Mode exploration
- Chaque trace terminée est map-matchée sur l'appareil (Valhalla/Meili) →
  edges OSM parcourus (id stable, compteur, dates) en SQLite.
- Carte de couverture : rues parcourues surlignées, % par cellule H3 et par
  quartier/ville.
- Route « explore » : algo des boucles avec points intermédiaires attirés vers
  les cellules H3 à faible couverture ; candidats scorés au ratio d'edges
  jamais parcourus.

### 4.6 Couche jeu (mode aventure)
- **Fog of war** : carte d'aventure voilée. Révélation par (a) couloir ~75 m
  autour des traces, (b) **points de synchronisation** — églises, tours,
  points de vue, monuments (`place_of_worship`, `man_made=tower`,
  `tourism=viewpoint`, `historic=*`) : visite physique → révèle 300–500 m et
  les landmarks contenus.
- **Pièces** : banques/ATM (`amenity=bank|atm`) donnent des pièces à la visite ;
  cooldown 24 h par lieu, rendement décroissant anti-farming.
- **Sinks** : gel de streak, « radar » (pulse la direction du landmark non
  visité le plus proche), thèmes de carte cosmétiques.
- **Énergie (faim)** : se vide avec les km en mode aventure ; restaurants/cafés
  (`amenity=restaurant|cafe|fast_food`) rechargent à la visite. Effet :
  multiplicateur d'XP (pleine ×1,5 → vide ×0,5), **jamais un blocage**.
- **XP/niveaux** : km, cellules révélées, landmarks, boucles complétées.
- **Badges** : distance cumulée, exploration (100 % d'un quartier, toutes les
  églises d'une zone), régularité (streaks).
- **Détection de visite** : geofence ~25 m + présence de quelques secondes,
  validée sur trace map-matchée (fonctionne écran éteint ; vraisemblance de
  vitesse prête pour l'anti-triche du collaboratif).
- **Source POIs** : extraits d'OSM par région (même job que les tuiles
  Valhalla), fichier compact téléchargé avec la région.

### 4.7 Couverture adaptative, tirée par le client (serveur minimal)
La notion de « région » est invisible pour l'utilisateur : **la couverture
s'adapte à sa position**, et c'est **le client qui télécharge ses tuiles** —
le serveur ne fait aucun travail par requête.

- **Affichage** : MapLibre consomme directement les tuiles vectorielles d'un
  fournisseur gratuit (OpenFreeMap) — rien ne transite par notre serveur.
- **Routage** : les tuiles Valhalla vivent sur une grille géographique fixe
  (niveau 2 = 0,25° ≈ 25 km, niveaux 1 et 0 plus larges pour la hiérarchie).
  Un **build périodique unique** (cron) couvre une grande zone (M1 : Suisse +
  France frontalière — extraits Geofabrik fusionnés puis découpés, un seul
  build ; extensible à l'Europe) et publie l'arborescence de tuiles en
  statique. L'app calcule les ids de tuiles couvrant la
  position + une couronne (calcul purement local, la grille est déterministe)
  et télécharge uniquement celles-ci. Cohérence garantie : toutes les tuiles
  publiées viennent du même build (`dataset_version` global ; l'app ne
  mélange jamais deux versions).
- **POIs jeu** (M4) : extraits par cellule dans le même job cron, servis en
  statique de la même façon.
- Téléchargement avec reprise (HTTP Range) et checksums ; purge LRU locale ;
  re-téléchargement quand `dataset_version` change (en Wi-Fi par défaut).
- Réglages : voir/supprimer/précharger une zone (ex. avant un voyage).

**Infrastructure** (volontairement minimale ; le VPS dev.lmqc.fr a peu de
disque — les tuiles n'y touchent pas) :
1. **Build : GitHub Actions** (cron hebdo + déclenchement manuel) — Geofabrik
   → `valhalla_build_tiles` (Docker, version Valhalla épinglée = celle de
   l'app) → manifeste (`dataset_version`, checksums).
2. **Stockage/CDN : GitHub Releases** d'un dépôt public `randomwalk-tiles`
   (1 asset par tuile + `manifest.json`) ; découverte via l'URL stable
   `releases/latest/download/manifest.json`, bande passante gratuite.
3. **VPS dev.lmqc.fr : uniquement la micro-API leaderboard** (voir 4.8),
   conteneur Docker derrière le Traefik existant.

### 4.8 Leaderboard primitif (v1, dès M1)
Classement global minimal synchronisé via `dev.lmqc.fr` :
- Client : identité anonyme générée sur l'appareil (UUID + pseudo choisi),
  envoi périodique du score (km cumulés ; XP quand la couche jeu existera).
- Serveur : micro-API (2 endpoints : `POST /v1/score`, `GET /v1/leaderboard`)
  avec stockage SQLite, limitation de débit basique. Pas de compte requis.
  Exposée sur `https://drive.lmqc.fr` (sous-domaine réutilisé — l'ancien
  conteneur lmqc-drive est arrêté et conservé, pas supprimé).
- UI : écran classement (top 50 + rang de l'utilisateur), pseudo modifiable.
- À l'arrivée de Supabase (M5), l'identité anonyme est rattachée au compte ;
  l'API leaderboard migre ou est absorbée — le client passe par la même
  interface Dart (`LeaderboardRepository`) dans les deux cas.

## 5. Données et sync

SQLite local, miroir Postgres/PostGIS :
`traces`, `covered_edges`, `revealed_cells`, `landmark_visits`,
`wallet_events`, `energy_events`, `xp_events`, `badges`, `cells`
(cellules de couverture téléchargées : versions carte/routage/POIs, dernier usage).

Écriture exclusivement via **journal d'événements append-only**
(UUID v7, horodatage, device_id). Sync = push/pull d'événements ; l'état est
recalculé localement par reducers. Les événements étant immuables, pas de
résolution de conflits. Multi-appareils et collaboratif futur consomment le
même journal.

RGPD : compte supprimable (cascade serveur), export des données (le journal
*est* l'export), traces GPS = données sensibles → minimisation côté serveur
(possibilité de ne synchroniser que les agrégats, à trancher en implémentation
de M5).

## 6. Gestion d'erreurs

| Cas | Comportement |
|---|---|
| Perte GPS (tunnel, canyon urbain) | Extrapolation courte sur le tracé, bannière « signal faible », pas de recalcul paniqué |
| Service tué par l'OS | État persisté en continu → restauration complète ; guidage réglages batterie constructeur |
| Boucle introuvable | Meilleur candidat présenté avec écart réel |
| Téléchargement interrompu | Reprise par morceaux, checksums |
| Sync hors-ligne | File locale persistante, retry backoff ; l'app ne dépend jamais du réseau |

## 7. Tests

- **Unitaires Dart** : algo de boucles (graphe de test), scoring exploration,
  économie du jeu (cooldowns, XP, énergie), reducers d'événements.
- **Intégration FFI** : Valhalla sur petit extrait OSM embarqué dans le repo —
  routage et map-matching déterministes.
- **Rejeu de traces GPX** (le plus rentable pour une app GPS) : traces réelles,
  y compris signal dégradé, rejouées dans le moteur de nav → vérifie
  instructions, écarts, visites de landmarks.
- **E2E Flutter** (`integration_test`) : planifier → naviguer → terminer → stats.

## 8. Phasage

| Jalon | Contenu |
|---|---|
| **M1 Fondations** | App Flutter + MapLibre (tuiles OpenFreeMap), Valhalla FFI Android (A→B piéton/vélo), tuiles de routage statiques sur dev.lmqc.fr téléchargées par le client autour de sa position, leaderboard primitif |
| **M2 Navigation** | Turn-by-turn, foreground service écran éteint, notifications, TTS, recalcul |
| **M3 Boucles** | Distance/temps fixe, candidats multiples, UI de choix |
| **M4 Exploration + jeu** | Map-matching, couverture, fog of war, landmarks, économie, XP/badges |
| **M5 Comptes & sync** | Supabase auth + sync du journal, publication Play Store (bêta fermée → ouverte) |
| **v2+** | iOS (Dart + C++ portables ; UI natives : Live Activities, background iOS), Wear OS/watchOS, collaboratif (heatmaps, défis), routage serveur de secours |

## 9. Hors périmètre v1 (explicite)

Smartwatch, iOS, collaboratif/social, guidage voiture, import/export GPX
(candidat v1.x facile), météo, monétisation.
