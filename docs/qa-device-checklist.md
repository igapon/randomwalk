# Checklist QA appareil réel — M2 à M4

Vérifications à faire sur un **téléphone Android réel** (pas un émulateur) avant
publication : la plupart des points ci-dessous dépendent du GPS réel, du
comportement OS/OEM en arrière-plan, ou d'un moteur TTS installé — autant de
choses que la CI (`flutter test`, l'émulateur `integration_test`) ne peut pas
vérifier. Chaque point indique le fichier/la tâche d'origine pour retrouver le
contexte dans le code.

Convention : cocher `[x]` une fois vérifié, noter l'appareil/version Android
utilisé et la date en fin de section si un problème est trouvé.

---

## 1. Navigation — écran éteint / service premier plan

Contexte : `app/lib/tracking/tracking_service.dart`, `ForegroundServiceTripTracker`
tourne dans un isolate séparé hébergé par un service Android au premier plan,
avec wakelock (`allowWakeLock: true`) — voir aussi
`app/android/app/src/main/AndroidManifest.xml`.

- [ ] **Écran éteint pendant une session (mode "tout le temps" accordé)** —
  démarrer un trajet, éteindre l'écran, marcher 5+ minutes, rallumer l'écran.
  **Résultat attendu** : la distance/durée a continué à progresser ; la
  notification persistante de suivi est toujours affichée pendant que l'écran
  était éteint (vérifiable en la faisant réapparaître sur l'écran de
  verrouillage).
- [ ] **Application balayée (swipe) hors des tâches récentes pendant une
  session** — démarrer un trajet, mettre l'app en arrière-plan, la balayer
  hors de la liste des tâches récentes, attendre 2-3 minutes, rouvrir l'app.
  **Résultat attendu** : le trajet a continué à être enregistré (le service
  premier plan doit survivre au swipe — `stopWithTask: false`) ; à la
  réouverture, la distance parcourue pendant l'absence est bien présente.
- [ ] **Mode "pendant l'utilisation" seulement (background location refusée)**
  — démarrer un trajet, éteindre l'écran quelques minutes.
  **Résultat attendu** : la bannière « Le suivi s'arrêtera si l'écran s'éteint
  — appuyez pour autoriser la localisation tout le temps. » (`ForegroundOnlyBanner`,
  `app/lib/main.dart`) est visible avant d'éteindre l'écran ; le comportement
  réel de coupure dépend de l'OEM, à noter tel quel s'il diffère.
- [ ] **Fiabilité batterie par constructeur** — sur un appareil **Xiaomi,
  Oppo, Vivo, OnePlus, Huawei ou Samsung** (`kAggressiveBatteryOems`,
  `app/lib/settings/battery_optimization.dart`), vérifier que le réglage
  « Suivi fiable en arrière-plan » de l'écran Réglages s'affiche, et que le
  lien vers les paramètres de l'app (`ACTION_APPLICATION_DETAILS_SETTINGS`)
  ouvre bien le bon écran système. Refaire le test « écran éteint » ci-dessus
  sur cet appareil après avoir suivi les instructions de la tuile.
- [ ] **Doze / veille profonde prolongée** — démarrer un trajet, laisser
  l'écran éteint et le téléphone immobile 15+ minutes (le temps que le
  système entre en Doze). **Résultat attendu** : les fixes GPS reprennent
  normalement une fois le mouvement repris ; pas de perte totale du suivi.

## 2. TTS et alertes vocales

Contexte : `app/lib/nav/tts.dart` — TTS natif custom (canal `randomwalk/tts`)
choisi après un conflit AGP/Kotlin avec `flutter_tts`. Se dégrade en silence
(`NoopTtsSpeaker`) si l'appareil n'a pas de moteur/voix française installée.

- [ ] **Appareil avec voix française installée** — démarrer une navigation
  guidée (boucle ou itinéraire), vérifier que les instructions sont bien
  **annoncées à voix haute** à l'approche d'une manœuvre, à l'écart de
  l'itinéraire, et à l'arrivée.
  **Résultat attendu** : « Dans 120 m, tournez à gauche » (ou équivalent),
  « Écart d'itinéraire — recalcul » (ou « … rejoignez la boucle » en mode
  boucle), « Arrivé ! » — entendus clairement, écran allumé et éteint.
- [ ] **Appareil sans voix française (ou aucun moteur TTS)** — dans Réglages,
  vérifier que le switch TTS est **désactivé** (grisé) plutôt que planté ou
  silencieusement inopérant sans explication.
  **Résultat attendu** : aucun crash ; l'app navigue normalement sans voix,
  seules les instructions textuelles à l'écran/notification restent.
- [ ] **Alertes avec écran éteint** — pendant une navigation guidée écran
  éteint, vérifier que les alertes sonnent/vibrent bien (canal de
  notification `guidance`, pensé pour être remarqué écran éteint).
- [ ] **Démarrage TTS lent/bloqué** — sur un appareil lent ou avec un moteur
  TTS tiers capricieux, vérifier qu'un TTS qui ne répond pas ne bloque pas le
  démarrage de la navigation (budget interne ~5 s avant repli silencieux).

## 3. UX de planification — boucles, Distance/Durée/Explorer

Contexte : `app/lib/map/plan_mode.dart`, `app/lib/map/candidate_chips_bar.dart`
— retours propriétaire des tâches 6-8 (« device-QA brief »).

- [ ] **Sélection plein écran des candidats** — lancer une proposition
  (Distance, Durée ou Explorer). **Résultat attendu** : dès que des
  candidats apparaissent, le sélecteur de mode, la barre de recherche, le
  sélecteur de profil et le panneau de cible disparaissent — seule la carte
  plein écran et la rangée compacte de choix en bas restent visibles
  (« cache les menus… pour mieux voir la carte »).
- [ ] **« Autres propositions »** — vérifier que le bouton propose bien un
  nouveau jeu de boucles à chaque appui, et qu'il est **masqué** (pas
  affiché comme un no-op) quand un seul candidat direct est retourné (pas
  assez de budget de détour).
- [ ] **Retour Android pendant la sélection** — candidats affichés ou
  proposition en cours : le bouton retour doit **quitter la sélection**
  plutôt que fermer l'app ou l'écran carte.
- [ ] **Passage à une session libre pendant une proposition** — proposer des
  candidats (boucle/durée), avant de choisir basculer sur l'onglet Session et
  démarrer un trajet libre, puis revenir sur l'onglet Carte.
  **Résultat attendu** : les candidats/tracés d'aperçu ne sont plus affichés
  (une session en cours prend toujours le dessus), pas de proposition qui
  atterrit après coup sur un écran qui ne l'attend plus.
- [ ] **Couverture incomplète** — se placer en bordure de la zone de
  couverture téléchargée et planifier. **Résultat attendu** : bannière
  « Couverture incomplète — certaines zones peuvent manquer », affichée au
  plus une fois par session de planification.
- [ ] **Manifeste incompatible (mise à jour requise)** — scénario simulable
  seulement avec un ancien build face à un nouveau manifeste ; si applicable,
  vérifier le message « Mise à jour de l'app requise pour les nouvelles
  cartes », qui doit réapparaître à **chaque** occurrence (contrairement à la
  bannière couverture incomplète).
- [ ] **Caméra par défaut** — première ouverture sans position connue (permission
  refusée ou GPS froid) : la carte doit s'ouvrir centrée sur **Genève**, jamais
  Lausanne.
- [ ] **Contrôle caméra en navigation** — pendant une navigation guidée,
  déplacer/zoomer manuellement la carte. **Résultat attendu** : le bouton de
  recentrage apparaît et la caméra ne « lutte » pas contre le geste de
  l'utilisateur (pas de re-snap intempestif au fix GPS suivant).

## 4. Aventure — fog of war, visites, HUD, badges

Contexte : `app/lib/adventure/`, `app/lib/game/` — logique pure et testée en
CI, mais dépend en pratique de vrais fixes GPS et du rythme réel de
déplacement de la carte. Les points ci-dessous sont la première passe de
notes « device-QA » explicites pour cette zone.

- [ ] **Révélation du brouillard en marchant** — marcher un trajet réel avec
  l'onglet Aventure ouvert (ou revenir dessus après le trajet).
  **Résultat attendu** : le corridor autour du tracé (~75 m) devient visible
  (non brumeux), mis à jour au plus 1×/2 s pendant la marche (pas de
  scintillement ni de blocage de l'UI).
- [ ] **Landmark église/tour visité** — passer à proximité d'un lieu de culte,
  d'un point de vue ou d'une tour référencés (rayon de détection 25 m,
  maintien 5 s). **Résultat attendu** : notification discrète type
  « ⚑ Nom du lieu — +25 XP », révélation à 400 m autour du point, XP crédité.
- [ ] **Faux positif à 25 m — passer PRÈS d'un landmark sans jamais entrer
  dans le rayon** (`kVisitRadiusM`, `app/lib/game/visits.dart:7`) — marcher un
  trajet qui passe volontairement à côté (pas devant) d'un lieu de culte/point
  de vue référencé, par exemple sur le trottoir opposé d'une rue assez large
  pour rester au-delà de 25 m tout le long. **Résultat attendu** : aucune
  notification, aucune entrée dans `pendingVisits`/le journal pour ce lieu —
  le geofence ne doit jamais se déclencher sur simple proximité de rue, y
  compris en marchant lentement ou en s'arrêtant (feu, photo) juste en dehors
  du rayon.
- [ ] **Banque/ATM visité** — s'arrêter 5 s dans les 25 m d'une banque/ATM.
  **Résultat attendu** : pièces créditées (100 à la première visite du lieu,
  rendement décroissant 50/25/10 aux visites suivantes, cooldown 24 h/lieu —
  revisiter le même lieu avant 24 h ne doit rien créditer).
- [ ] **Restaurant/café visité** — même geofence, vérifier l'énergie créditée
  (+40 restaurant / +25 café, cooldown 6 h/lieu) et que l'énergie ne dépasse
  jamais 100 ni ne descend sous 0.
- [ ] **HUD** — pendant un trajet en mode Aventure, vérifier l'affichage
  compact pièces · énergie · niveau/XP, lisible avec les encoches
  (notch/barre de statut) de l'appareil.
- [ ] **Écran badges/stats** — ouvrir l'écran badges depuis le HUD :
  pourcentage du quartier courant, streak de jours, km cumulés cohérents
  avec le trajet réellement parcouru.
- [ ] **Le pourcentage de quartier suit la caméra, pas une valeur figée** —
  depuis l'écran badges/stats (ou le HUD, selon l'écran courant), déplacer
  (pan) manuellement la carte vers un quartier différent de celui où le
  trajet a lieu. **Résultat attendu** : le pourcentage affiché change pour
  refléter le quartier maintenant sous la caméra (généralement 0 % s'il n'a
  jamais été exploré) plutôt que de rester bloqué sur le pourcentage du
  quartier de départ — un pourcentage qui ne bouge jamais en pannant est le
  signe d'un calcul figé sur la position GPS plutôt que sur le centre caméra.
- [ ] **Streak après redémarrage** — effectuer une sortie un jour, tuer
  complètement l'app, la rouvrir le lendemain avec une nouvelle sortie.
  **Résultat attendu** : le streak progresse (journal d'événements relu au
  démarrage, tolérant aux lignes corrompues).
- [ ] **Jeu indisponible ne bloque jamais l'outil** — si possible, simuler
  l'absence de POIs (ancien manifeste sans clé `pois`) ou un journal corrompu
  (tronquer/altérer une ligne de `game_events.jsonl`).
  **Résultat attendu** : navigation/boucles/sessions restent 100%
  fonctionnelles ; le jeu se désactive proprement, sans crash ni blocage.
  Logs concrets à vérifier :
  - Absence de POIs / manifeste sans `pois`, ou init de la couche
    exploration en échec : `adb logcat` doit montrer la ligne
    `flutter: main: exploration layer unavailable, game disabled: ...`
    (`app/lib/main.dart:118`) au démarrage — jamais de crash ni de stack
    trace non catchée juste après.
  - Journal corrompu : il n'existe **volontairement** aucune ligne de log
    dédiée (`GameJournal.readAll` compte silencieusement les lignes ignorées
    via `skippedLines`, `app/lib/game/events.dart:83`) — vérifier plutôt
    l'absence de comportement aberrant à l'écran (HUD/badges cohérents, pas
    de valeur `NaN`/négative) plutôt qu'une trace logcat.
  - Un trajet qui vient de se terminer (`ExplorationRecorder.process()` en
    échec quelque part dans son pipeline) loggue
    `flutter: ExplorationRecorder: failed, continuing: ...`
    (`app/lib/exploration/exploration_recorder.dart:167`) — présence normale
    en cas d'échec best-effort, mais ne doit jamais s'accompagner d'un crash
    de l'app ni d'un blocage de la session suivante.

### Performance (usage prolongé / zone dense)

Contexte : rien ci-dessous n'a de seuil d'échec/réussite strict — le but est
de repérer un ressenti « qui rame » qu'un émulateur ou un jeu de données de
test ne révèle jamais.

- [ ] **`trace_attributes` (map-matching) sur une trace de ~2000 points** —
  faire une sortie longue (~1-2 h, GPS continu) puis arrêter le trajet.
  Chronométrer (montre, ou `adb logcat` horodaté) le temps entre l'arrêt et
  la fin du traitement `ExplorationRecorder.process()`
  (`app/lib/exploration/exploration_recorder.dart`, appel Valhalla
  `trace_attributes` dans `matcher.dart`). **Résultat attendu** : quelques
  secondes maximum, pas de gel perceptible de l'UI pendant le calcul (il
  tourne en fire-and-forget, voir le commentaire de classe
  d'`ExplorationRecorder`).
- [ ] **Cadence d'écriture du fichier de trace** — pendant une sortie longue,
  vérifier que `active_track.jsonl` (répertoire de session) ne grossit pas
  sans limite et que les écritures successives n'introduisent pas de à-coups
  visibles dans la distance/le tracé affiché (le fichier est borné à
  `kTrackMaxPoints`, `app/lib/exploration/track_sampler.dart` — un dépassement
  silencieux serait le signe d'une régression de ce plafond).
- [ ] **Coût de `PoiStore.near` par fix, en zone urbaine dense** —
  démarrer un trajet Aventure dans un centre-ville dense en POIs
  (`app/lib/game/pois.dart`, `PoiStore.near` interrogé à chaque fix via
  `VisitDetector`, `app/lib/game/visits.dart`). **Résultat attendu** : pas de
  ralentissement perceptible de la fréquence des fixes GPS affichés ni de
  la réactivité de l'écran carte comparé à une zone peu dense, même avec
  plusieurs centaines de POIs dans le disque de recherche.
- [ ] **Latence « Proposer » juste après l'arrêt d'un trajet (« shared-actor
  stall »)** — arrêter un trajet Aventure/navigation, puis immédiatement
  (dans la seconde qui suit) lancer une proposition de boucle/itinéraire
  (bouton « Proposer », `app/lib/map/map_screen.dart`). **Contexte** : le
  moteur natif Valhalla est un acteur unique partagé par isolate
  (`ValhallaChannel.kt`) — le post-traitement du trajet qui vient de se
  terminer (`_buildExplorationEngine`, `app/lib/main.dart:159`) réinitialise
  ce même acteur (fermeture + réouverture, remmapping des tuiles), ce qui
  peut brièvement geler l'acteur que le planificateur de route utilise
  aussi. **Résultat attendu** : la proposition finit par arriver (pas
  d'erreur), mais noter tout délai visiblement plus long que d'habitude —
  un délai de plusieurs secondes juste après l'arrêt, absent en dehors de
  cette fenêtre, confirme ce chevauchement et n'est pas un bug à corriger
  dans cette passe (limitation connue, voir le commentaire de
  `_buildExplorationEngine`).

## 5. Permissions

Contexte : `app/lib/tracking/permissions.dart` — ordre exact testé :
notifications (Android 13+) → localisation précise (bloquant) → dialogue
maison avant la demande background location (Android 11+) → activité
physique (podomètre). Chaque demande au plus une fois par installation.

- [ ] **Premier lancement, tout accepté** — dérouler le parcours complet dans
  l'ordre ci-dessus. **Résultat attendu** : chaque permission est demandée
  une seule fois, dans cet ordre, et le premier trajet démarre normalement.
- [ ] **Refus localisation précise** — refuser la permission de localisation.
  **Résultat attendu** : message clair, pas de crash, l'app reste utilisable
  hors navigation/enregistrement.
- [ ] **« Autoriser tout le temps » (Android 11+)** — vérifier que le
  dialogue maison en français s'affiche **avant** la demande système, et que
  la demande système elle-même ne propose que « Cette fois » — sur Android
  11+, l'option « Tout le temps » n'apparaît **que** dans les réglages
  système ; vérifier que l'app y renvoie bien (`openAppSettings()`).
- [ ] **Notifications refusées (Android 13+)** — refuser la permission
  notifications. **Résultat attendu** : le suivi continue de fonctionner,
  mais la notification persistante de trajet est silencieusement absente —
  vérifier que l'app ne plante pas et l'indique clairement si nécessaire.
- [ ] **Retour au premier plan après avoir changé un réglage** — pendant un
  trajet en mode dégradé (pas de background location), aller dans les
  réglages système, activer « Tout le temps », revenir dans l'app.
  **Résultat attendu** : la bannière de mode dégradé disparaît **sans avoir
  à redémarrer le trajet**.
- [ ] **Podomètre absent / permission activité refusée** — sur un appareil
  sans capteur de pas, ou permission refusée. **Résultat attendu** : repli
  propre (pas de crash), fonctionnalités liées aux pas simplement absentes.

## 6. Marqueurs logcat

Contexte : `RandomwalkPlugin.kt` — breadcrumbs ajoutés spécifiquement pour la
QA device (tag `RandomwalkPlugin`).

- [ ] **`adb logcat -s RandomwalkPlugin`** pendant le démarrage d'une
  navigation guidée avec l'écran app ouvert. **Résultat attendu** : **deux**
  lignes `attached to engine` — une pour le moteur Flutter de l'UI
  (`MainActivity`), une pour le moteur du service d'arrière-plan
  (`RandomwalkTaskLifecycleListener`). Une seule ligne, ou aucune, indique un
  problème de branchement du plugin sur l'un des deux moteurs.
- [ ] **Fin de trajet / fermeture** — vérifier la ou les lignes symétriques
  `detached from engine` à l'arrêt du service.
- [ ] **Aucun `MissingPluginException`** — sur toute la durée d'un trajet
  enregistré en arrière-plan (`adb logcat | grep -i missingplugin`).
  **Résultat attendu** : rien. Une occurrence indique que
  `GeneratedPluginRegistrant.registerWith` n'a pas été correctement rejoué
  sur le moteur du service d'arrière-plan (régression à traiter en priorité,
  puisque ça casse `flutter_local_notifications` et tout canal appelé depuis
  l'isolate service).
- [ ] **Arrêt anormal du service (isolate figé)** — si reproductible (force
  stop pendant un trajet, par ex.), vérifier dans les logs qu'il n'y a pas de
  fuite du thread/worker natif Valhalla signalée (point relevé pour la QA
  device en tâche 5 : `flutterEngine.destroy()` peut ne jamais s'exécuter si
  l'isolate est trop gravement bloqué). Il n'existe pas de ligne de log
  dédiée à cette fuite spécifiquement (le worker Valhalla —
  `Executors.newSingleThreadExecutor()`, `ValhallaChannel.kt:50` — ne loggue
  rien à sa propre fermeture) ; les signaux concrets à chercher sont :
  - `adb logcat -s RandomwalkPlugin` : la ligne symétrique
    `detached from engine` (voir section 6, deux lignes plus haut) doit
    apparaître pour CHAQUE `attached to engine` — une `attached` sans
    `detached` correspondante après l'arrêt anormal indique que le moteur du
    service isolate n'a jamais été détruit proprement.
  - `adb shell dumpsys activity services fr.lmqc.randomwalk` (ou le profiler
    Android Studio, onglet Threads) juste après l'arrêt anormal : un thread
    nommé `pool-*-thread-1` toujours vivant plusieurs minutes après que le
    service a été tué est le worker Valhalla resté bloqué.

## 7. Bannières GPS et couverture

Contexte : `app/lib/main.dart` (`GpsSilentBanner`), `app/lib/tracking/tracking_service.dart`
(seuil de silence GPS), `app/lib/map/map_screen.dart` (bannières de
couverture — voir section 3).

- [ ] **Silence GPS pendant un trajet enregistré** — démarrer un trajet dans
  un endroit qui coupe le signal GPS (parking souterrain, tunnel, mode avion)
  pendant plus d'une minute. **Résultat attendu** : bannière
  « GPS silencieux — vérifiez les autorisations de localisation. »
  (icône GPS barré) après ~60 s sans fix — un peu plus en navigation
  (le seuil s'élargit avec le filtre GPS adaptatif, jusqu'à quelques minutes
  au rythme le plus large). **Ne doit pas** se déclencher pour un simple
  arrêt (feu rouge, photo) : vérifier qu'un arrêt de 1-2 minutes en extérieur
  avec GPS fonctionnel ne l'affiche pas.
- [ ] **Bannière tapée** — appuyer sur la bannière silence GPS.
  **Résultat attendu** : ouvre les réglages Android de l'app (accès rapide
  aux autorisations de localisation).
- [ ] **Signal perdu en cours de route (erreur de flux, pas juste silence)** —
  si reproductible, vérifier le message ponctuel « Signal GPS perdu —
  session enregistrée. » (SnackBar), distinct de la bannière silence GPS
  persistante.
- [ ] **Ne pas confondre les 4 messages** — s'assurer, en repassant en revue
  les captures/logs d'un run de test complet, que les quatre messages
  distincts (silence GPS, signal perdu, couverture incomplète, mise à jour
  requise) apparaissent chacun dans leur scénario propre et ne se
  chevauchent/masquent pas mutuellement à l'écran.

## 8. Compte et synchronisation (M5)

Contexte : `app/lib/sync/`, `app/lib/settings/account_screen.dart` — le
moteur de sync (`SyncEngine`) et l'écran de compte sont testés à blanc
(fakes) en CI ; les points ci-dessous ne peuvent être vérifiés que contre
un vrai projet Supabase configuré (`SUPABASE_URL`/`SUPABASE_ANON_KEY`).

- [ ] **Forme exacte des erreurs PostgREST sans session** — appeler les
  chemins `push_events`/`delete_account` (RPC) sans être connecté sur le
  vrai projet, et confirmer qu'ils atterrissent bien en `SyncAuthError`
  (pas `SyncNetworkError`) côté app — voir `SupabaseBackend.mapError`
  (`app/lib/sync/supabase_backend.dart`) et le point non vérifié noté dans
  `task-3-report.md`/`task-4-report.md` (concern (c) : le code/message
  PostgREST exact pour un appelant `anon` n'a été lu que dans la doc
  postgrest-dart, jamais observé contre un projet réel).
- [ ] **Copie française à la déconnexion forcée** — pendant que l'app est
  connectée, révoquer la session côté Supabase (dashboard) ou attendre son
  expiration, puis déclencher une synchronisation (bouton manuel ou
  automatique). **Résultat attendu** : `AccountScreen` affiche « Session
  expirée — reconnectez-vous. » (le mapping `SyncAuthError` de
  `runAutoSync`/`auto_sync.dart`), pas un message réseau générique.
- [ ] **Restauration de session au lancement (course froide)** — se
  connecter, tuer complètement l'app, la rouvrir. **Résultat attendu** :
  reconnecté automatiquement sans repasser par l'écran OTP (tolère le
  délai de `supabase_flutter`'s session recovery — voir
  `restoreAccountAndAutoSync`, `app/lib/sync/auto_sync.dart`) ; si ce
  n'est pas le cas de façon reproductible, le correctif actuel (une seule
  retentative après 300 ms) est probablement insuffisant sur cet appareil.

---

## Suivi des anomalies trouvées

| Date | Appareil / Android | Section | Constat | Statut |
|------|--------------------|---------|---------|--------|
|      |                    |         |         |        |
