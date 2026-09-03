# Backlog technique M6

Compilé depuis la revue finale de branche M5
(`.superpowers/sdd/2026-09-01-m5-sync/final-review.md`) : sa colonne
CONFIRM-DEFER (35 lignes triées, section 3 de ce document), plus les points
que cette même revue nomme explicitement comme candidats M6. Rien ici n'est
bloquant pour la publication 1.0.0 — voir `docs/owner-handoff.md` pour ce
qui l'est réellement.

Remplace et complète la liste à 6 points qui vivait directement dans
`docs/owner-handoff.md` (« Backlog technique reporté — M6 ») : ces 6 points
sont repris ci-dessous (points 6 à 11), avec l'ajout du point le plus
important qu'ils ne couvraient pas (le point 1) et de trois autres items
identifiés par la revue finale (points 2, 3, 12).

---

## 1. Filet de sécurité au démarrage (`main()`) — priorité la plus haute

**I8, revue finale.** `main.dart`'s cold-start chain (`_buildTripController()`,
`trip.restore()`, `isOnboarded()`, `ThemeModeStore().load()`) s'exécute sans
aucun `try`/`catch` autour de l'ensemble. N'importe quelle exception dans
cette chaîne — y compris, désormais, tout le chemin de fin automatique de
M5 (`markFinalised`, `addAndGetTotalKm`, `setPendingCelebration`,
`tracker.clearSnapshot()`) ou un `FileSystemException` remonté par
`FileTripSnapshotStore.clear()` — empêche `runApp` d'être atteint : écran
blanc à **chaque** lancement suivant, récupérable uniquement en vidant les
données de l'app.

**Pourquoi ce n'est PAS dans le lot de correctifs M5** : ce comportement est
pré-existant (`master` avait déjà ce chemin non protégé avant M5), et un
`try`/`catch` ajouté sans revue dédiée juste avant un tag de version est
exactement le genre de changement à risque — un mauvais repli masquerait de
vraies erreurs ou lancerait l'app dans un état à moitié initialisé.
**Priorité M6 néanmoins la plus haute** : c'est la première version publiée
publiquement, et M5 a matériellement élargi ce qui peut lever une exception
dans `restore()`.

Tâche M6 attendue : concevoir (avec sa propre revue) un filet de sécurité
explicite — écran de repli minimal + logging, plutôt qu'un `catch` muet —
et des tests couvrant au moins un throw synthétique dans chaque étape de la
chaîne.

---

## 2. L'onglet Session ignore un itinéraire déjà planifié

**Revue finale (item 33 de la table de triage), pré-existant.**
`session_screen.dart` est **octet pour octet identique** à `master` sur
cette branche (`git diff --stat` vide) — ce n'est donc pas une régression
M5, mais un gap fonctionnel réel : démarrer un trajet depuis l'onglet
Session ignore silencieusement tout itinéraire A→B ou boucle déjà planifié
depuis l'onglet Carte (le bouton « Démarrer » y lance toujours un trajet
libre, jamais le plan en attente). Un walker qui bascule sur Session juste
avant de démarrer perd son plan sans avertissement.

Tâche M6 attendue : soit faire lire à `SessionScreen` le même
`activeRouteProvider` que la Carte et proposer de démarrer CE plan-là, soit
a minima avertir explicitement que démarrer ici ignore le plan en cours.

---

## 3. Arrêt d'un trajet libre sans aucun résumé, et bascule inattendue vers le wizard

**Revue finale, I12.** Deux sous-problèmes distincts :

- **Silence total à l'arrêt d'un trajet libre** (comportement M4, inchangé,
  sanctionné par le plan) : `map_screen.dart`/`session_screen.dart` font
  juste `await stopTrip()` et `_onSessionEnded` (`main.dart`) ne dit rien en
  cas de succès — la bannière est simplement remplacée par le bouton de
  démarrage, sans confirmation ni résumé. Ce silence lui-même n'est pas une
  régression M5, mais l'**asymétrie** avec le nouvel écran de félicitations
  des trajets guidés (tâche 2g) le rend plus visible qu'avant.
- **Régression M5, tâche 2i** : pour un trajet libre démarré depuis l'onglet
  **Session**, `_showMap` reste `false` ; à l'arrêt, `shouldShowWizardHome`
  (`carte_tab.dart`) redevient vrai et `MapScreen` — surface native de carte
  incluse — est démonté puis remplacé par l'écran d'accueil du wizard, alors
  que rien n'a été demandé côté Carte.

Tâche M6 attendue : au minimum corriger la bascule inattendue vers le
wizard (régression M5, la plus concrète des deux) ; envisager un résumé de
fin de trajet libre (parité UX avec les trajets guidés) comme amélioration
produit séparée.

---

## 4. Diff des symboles de carte par identifiant

Repère ledger M4 : « symbols diff par id si trivial, sinon documenté ». Les
couches de marqueurs sur la carte (points d'intérêt, repères de jeu) sont
aujourd'hui recréées en bloc à chaque rafraîchissement plutôt que diffées
symbole par symbole (ajout/suppression uniquement de ce qui a changé, par
id) — même famille de problème que le bug de « repères fantômes » corrigé
en tâche 2e pour les lignes de route (`updateLine` en place plutôt que
suppression+recréation). **Non trivial** : nécessite le harnais de test du
point 5 ci-dessous pour être fait sans régression silencieuse — reporté,
pas traité « à l'aveugle ».

## 5. Harnais de test `MapLibreMapController` factice

Lacune transversale identifiée dès la tâche 2e (confirmée en 2j, et de
nouveau en I5 de la revue finale) : aucun faux contrôleur de carte n'existe
pour tester en isolation les mises à jour de couches (lignes, symboles,
sources) sans dépendre d'un vrai widget carte. C'est aussi la raison
structurelle pour laquelle `MapScreen`, `TripHistoryDetailScreen`,
`AdventureScreen` et `TripCelebrationScreen` restent non testables en
widget test aujourd'hui. Bloque proprement le point 4 ci-dessus et tout
futur test d'idempotence de rafraîchissement de couche.

## 6. Test adverse pour la simplification Douglas-Peucker

L'algorithme de simplification d'affichage du tracé de route (`app/lib/
nav/` — introduit/optimisé en tâche 2l pour le gel au démarrage/
replanification) est O(n²) dans le pire cas sur l'isolate UI ; aucun test
n'existe avec une entrée pathologique construite pour maximiser ce coût. À
date, seules des traces réelles ont été mesurées.

Même lot (mineurs 2l) : le banc d'essai `waymarkDiamondPng` écarté pendant
le diagnostic du gel (pendait 10 min en `testWidgets` nu) mériterait d'être
réparé et conservé comme garde de régression du soupçon (d) — rafale
d'enregistrement d'icônes.

## 7. Synchronisation de l'historique des trajets

`TripHistoryStore` (historique détaillé introduit en tâche 2f, avant la
conception de la synchronisation) n'est **pas** synchronisé par le moteur
de sync M5 (qui ne couvre que le journal d'événements de jeu) : l'historique
des trajets, avec ses traces GPS, reste local à chaque appareil, jamais
fusionné entre plusieurs appareils d'un même compte. C'est aussi, en creux,
la limite documentée de l'export RGPD (`docs/privacy-policy.md` section 6) :
tant que ce point n'est pas traité, l'export ne peut pas non plus inclure
cet historique.

## 8. Nouvelle source de pièces (coins)

La tâche 2k a retiré la seule source existante de pièces (visites de POI
banque/distributeur, POIs désormais recentrés sur le patrimoine culturel) ;
le HUD masque la pastille pièces tant qu'aucune source n'existe, mais les
réducteurs et l'état restent en place (identité de rejeu M4 préservée). Une
décision produit reste à prendre sur la prochaine source de pièces, le cas
échéant.

## 9. Taille du checkpoint d'état de jeu en O(cellules)

Le fichier `game_state_checkpoint.json` (tâche 5) grossit linéairement avec
le nombre de cellules de carte explorées, sans compression ni pagination ;
acceptable aux volumes actuels, à surveiller si l'exploration cumulée d'un
joueur de longue date devient significative.

## 10. Assertion zéro-tolérance du test d'intégration (flake sha)

**Revue finale, item 31 de la table de triage — explicitement absent du
backlog jusqu'ici, correction apportée par ce document.**
`app/integration_test/routing_test.dart` (`reason: 'no tile download should
fail sha check'`) affirme zéro échec possible contre un vrai CDN de tuiles
en conditions réelles de réseau — la cause du flake identifié en tâche 3.
Actuellement mitigé au niveau du job CI par l'étape « deux tentatives » sur
l'émulateur (`2ca2ba1`), pas au niveau de l'assertion elle-même. Envisager
une tolérance explicite (retry borné dans le test, ou assertion moins
stricte avec log) plutôt que de compter uniquement sur le contournement CI.

## 11. Job CI `aab` : pas d'étape de nettoyage disque

Le job `aab` (`.github/workflows/ci.yml`) ne reprend pas l'étape « Free disk
space » que le job `apk` a dû ajouter pour éviter un `ENOSPC` — même
runner, même type de build release AGP complet. À surveiller si le job
`aab` (déclenché manuellement seulement, donc moins souvent exercé) échoue
un jour pour la même raison.

---

## Reste de la colonne CONFIRM-DEFER (revue finale, section 3)

Items déjà couverts individuellement ci-dessus ne sont pas répétés. Le
reste, groupé par origine, pour mémoire — voir `final-review.md` pour le
détail complet de chacun :

| Item | Statut / raison du report |
|---|---|
| 2g M6 — un trajet repris à l'arrivée ne peut jamais finir automatiquement (`NavFields()` vide `navLeftArrivalRadius`) | Faux négatif seulement ; « Terminer » manuel fête quand même le trajet |
| 2g M3 — la célébration ne s'affiche qu'une fois (marqueur effacé avant l'affichage) | Écran de récompense seulement, aucune perte de donnée |
| 2g M5 — la trace enregistrée s'arrête un peu avant la destination après le loquet d'arrivée | Délibéré ; documenter le compromis plutôt que le changer |
| 2g M2 — `resolveCelebrationEntry` dort encore après sa dernière tentative | 200 ms, négligeable |
| 2g M4/M7 — testabilité widget de la célébration surestimée ; contrat de `consume` surestimé | Dette de test + doc, pas un bug utilisateur |
| 2d M1 — `lowPowerPaused` (pause basse consommation) n'atteint jamais l'UI Flutter | Vrai manque UX (voir I7, revue finale) ; nécessite une conception d'écran, pas un correctif ponctuel |
| 2d M2–M7 — dérive doc/commentaire, `_publish` pendant une pause, race `MotionChannel.kt` `start()`, asymétrie `stop()`, `debugSafetyFixCount`, abandon de `_navBusy` | Tous inatteignables avec le câblage actuel, ou cosmétiques |
| T4 minors 2/3 — gardes `mounted` de `account_screen` + état de déconnexion inconditionnel | Race étroite, récupérable par redémarrage |
| T4 minors 1/4/5/6b/6c/7 — faux commentaire de test, deux trous de test, fragilité de `ev()`, purge de curseur sur violation de contrat, mutation d'argument de `_compact`, contournement DI de `_pushInitialProfile` | Mineurs, non exploitables en pratique |
| T5 M1–M5 — collections restaurées mutables, chemin `.tmp` partagé, taille du checkpoint en O(cellules) (voir point 9 ci-dessus), assertion de perf faible, rapport qui survend certains points | Déjà en grande partie repris ci-dessus |
| T5 ⚠1 DORMANT — `coins_spent` lirait des pièces écrites par `coins_earned` (même palier de tri) | Vérifié dormant : aucun émetteur de `coins_spent` n'existe ; à lier à la tâche qui ajoutera un jour une dépense de pièces (voir point 8) |
| 2h minors — test de franchissement de corridor, `try`/`catch` couplé icône+brouillard, doc antiméridien | Mineurs |
| 2i minors — décompte de rapport, `_runAutoPlan` non couvert, fenêtre de kill qui refait apparaître le wizard | Mineurs |
| 2j minors — flash du bouton bascule au démarrage à froid, 3ᵉ FAB en cours de navigation, doc de `GameLayer.visible` | Choix produit, pas des bugs |
| 2b/2c minors — garde `_preloadTriggered` redondante, `catch` inatteignable, garde `_continuing` inatteignable, allocation de service par tap | Mineurs |
| 2e — restart qui redéclenche l'alerte des 20 m | Déjà listé comme item M6 avant ce document (voir point 5 ci-dessus pour le harnais factice associé) |
| T2 minors — `top_profiles` réservé aux authentifiés, index élargi, résultat RPC `push_events` ignoré | Tous jugés corrects lors de leur propre revue |
| T6 minors — `SpeedHistoryStore` désormais bien documenté dans les exclusions de purge (`local_purge.dart`), timing de snackbar à élargir | Le point de documentation est déjà réglé (voir `local_purge.dart`) ; le timing de snackbar reste un potentiel futur ajustement UX mineur |
| M-a — `privacy-policy.html` : écart de structure avec le `.md` | Réglé dans le lot de correctifs qui a produit ce document (F3) |
| M-b — renvoi de section erroné dans `privacy-policy.md` | Réglé dans le même lot (F3) |
| M-c — libellé « deux mécanismes indépendants » pour les classements, alors qu'ils s'excluent mutuellement en pratique | Divergence sans risque (moins de données déclarées que la réalité) ; à corriger un jour par souci d'exactitude |
| M-d — `supabase/notes.md` lit comme un TODO déjà résolu | Cosmétique |
| M-e — `top_profiles` sans tie-breaker déterministe en fin de page | Le rang lui-même reste correct |
| M-f — résultat d'insertion de `push_events` ignoré côté client | Filet de sécurité inutilisé, pas un bug |
| M-g — `kAppVersion` dupliqué à la main depuis `pubspec.yaml` | Actuellement correct, simple point de vigilance |
| M-h — 14 renvois de documentation vers des `task-N-report.md`/`task-N-brief.md` absents du dépôt fusionné | Soit committer les rapports, soit réécrire ces renvois avant que le prochain jalon ne s'appuie dessus |
| M-i — aucun `README.md`/`CLAUDE.md`/`AGENTS.md` décrivant l'architecture | Absence, pas une erreur ; un nouvel arrivant n'a aucun point d'entrée |
| M-j — attribution OSM en bas à gauche sous la barre de navigation système sur l'écran de détail d'historique | Seul défaut de SafeArea de la branche M5 ; cosmétique mais l'attribution est une exigence de licence |
| M-k — `Positioned(bottom: 24)` sans marge propre dans `adventure_screen.dart`, sûr seulement parce que c'est un corps d'onglet | Latent |
| M-l — incohérences de copie ponctuelles (« historique »/« trajet », « effacés », « sortie »/« trajet ») | Mineur ; la distinction trajet/promenade/itinéraire elle-même est intentionnelle, ne pas l'unifier |
| M-m — typographie (espaces insécables fines, apostrophes ASCII) | Style de la maison, uniforme sur tout le projet |
| M-n — `commitPromenadePlan` avec un `ActiveRoute` vide supprime silencieusement un plan A→B précédent | Jugé acceptable : choix explicite d'un autre mode de planification |
| M-o — churn de `MapScreen`/surface native sur chaque trajet libre démarré depuis Session | Recoupe le point 3 ci-dessus |
| M-p — pas de garde de réentrance sur `_showCelebration` ; `popUntil` du wizard pourrait avaler une route de célébration | Aucune séquence constructible ne l'atteint actuellement |
| M-q — `reduceAll(readAll())` complet sur l'isolate UI par visite/à la finalisation | Conforme au plan ; même coût que M4, la tâche 5 ne le borne pas |
| M-r — pas de sérialisation d'écriture entre les trois écrivains du journal | Borné : `readAll` ignore les lignes illisibles, le hasard de niveau index déjà géré par la relecture de `sync_engine.dart` |
| M-t — job CI `aab` sans étape de nettoyage disque | Voir point 11 ci-dessus |
| M-u — `owner-handoff.md` fournit une commande `appbundle` puis pointe vers une checklist qui suppose un APK installé | Mineur, à clarifier |

---

*Document créé lors du lot de correctifs final M5 (F8) — voir
`docs/owner-handoff.md`, section « Backlog technique reporté — M6 », pour le
lien depuis le guide de remise au propriétaire.*
