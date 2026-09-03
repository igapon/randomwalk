# Journal des modifications — RandomWalk

Résumé par jalon (milestone). Ce fichier documente les grandes lignes livrées
à chaque étape, pas chaque commit individuel — voir l'historique git pour le
détail.

## M5 — Compte, synchronisation et préparation à la publication (1.0.0)

Version de première publication sur le Play Store.

- **Compte optionnel et synchronisation multi-appareils** : connexion par
  code à usage unique par e-mail (Supabase, hébergement UE), synchronisation
  du journal de jeu entre appareils (push/pull/fusion), classement basé sur
  le compte en plus du classement anonyme existant. Sans compte configuré,
  le comportement reste strictement identique à M4 (aucun appel réseau,
  aucune donnée transmise).
- **RGPD** : export complet des données locales (JSON, partage natif
  Android), suppression de compte (serveur, irréversible) avec purge locale
  optionnelle et distincte, retry en cas de purge partielle.
- **Checkpoint d'état de jeu** : reconstruction rapide de l'état (XP, badges,
  cellules explorées) sans rejouer tout le journal depuis le début à chaque
  démarrage, avec garantie d'équivalence avec un rejeu complet.
- **Retours propriétaire (device QA) intégrés en continu** : onboarding qui
  garantit la localisation "tout le temps", mode basse consommation (pause
  GPS à l'arrêt via détection d'activité, reprise immédiate au mouvement),
  correctifs navigation (repères fantômes après recalcul, seuils d'alerte
  vocale), fin de trajet automatique avec écran de félicitations, historique
  des trajets, refonte du brouillard d'exploration (rendu + performance),
  parcours d'accueil (assistant destination/distance/durée, sans carte à
  l'écran d'accueil), fusion de l'exploration dans la carte principale avec
  bouton d'enregistrement libre, recentrage des points d'intérêt sur le
  patrimoine culturel, correctifs de gel au démarrage/replanification, mode
  jour/nuit manuel.
- **Publication** : politique de confidentialité (française + version HTML
  publiable), fiche Play Store, job CI optionnel de build d'AAB signé, guide
  de remise au propriétaire.

## M4 — Exploration et jeu

8 tâches + vague de revue finale. 995 tests. Correspondance de trace sur
l'appareil (map-matching hors-ligne), économie basée sur un journal
d'événements (fondation de la synchronisation M5), 141 000 points d'intérêt
réels issus du pipeline de tuiles, mode de planification Explorer, format
`dart format` appliqué en CI, checklist QA appareil consolidée.

Fonctionnalités livrées : brouillard de guerre (fog of war) qui se dévoile
en marchant, détection de landmarks (lieux de culte, points de vue, tours),
économie de pièces/énergie via visites de banques/distributeurs et
restaurants/cafés, onglet Aventure avec HUD (pièces, énergie, niveau/XP) et
écran badges/stats.

## M3 — Boucles et promenades

8 tâches + vague de revue finale. 605 tests ; boucle planifiée sur le
moteur réel en 502 ms avec 2,4 % d'écart (objectif : moins de 15 s / 15 %).

Fonctionnalités livrées : itinéraires à distance ou durée fixe, boucles
aller-retour (A-A), sélection plein écran parmi plusieurs candidats
proposés, durées personnalisées selon l'allure réelle du joueur.

## M2 — Navigation

8 tâches + vague de revue finale. 397+ tests, harnais de rejeu GPX, CI verte
(analyse, tests unitaires, APK debug+release, intégration émulateur sur
tuiles de production).

Fonctionnalités livrées : guidage virage par virage, recalcul hors-ligne en
cas d'écart d'itinéraire, alertes de proximité de manœuvre, synthèse vocale
(TTS) native en français, durcissement du suivi en arrière-plan.

## M1 — Fondations

13 tâches + vague de revue finale. 220 tests, CI verte (analyse, tests
unitaires, APK debug, intégration émulateur sur tuiles de production
réelles).

Fonctionnalités livrées : routage hors-ligne (moteur Valhalla embarqué),
téléchargement/couverture des tuiles cartographiques, classement anonyme
minimal, identité joueur générée sur l'appareil (waymark), suivi de trajet
en arrière-plan.
