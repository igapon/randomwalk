# Google Play — fiche de présentation et formulaires

Ce document rassemble tout ce qui doit être saisi dans la Play Console au
moment de la publication : titre, descriptions, catégorie, questionnaire de
classification par âge, et surtout le formulaire "Sécurité des données" —
qui doit rester **exactement cohérent** avec `docs/privacy-policy.md`
(section 9 de ce dernier renvoie ici).

Voir `docs/owner-handoff.md` pour les étapes concrètes de publication
(compte développeur, upload de l'AAB, où coller chaque champ ci-dessous).

## Titre (30 caractères max)

```
RandomWalk : Balades à pied
```
(28 caractères)

## Description courte (80 caractères max)

```
Balades et boucles à pied, hors-ligne, avec exploration façon jeu.
```
(68 caractères)

## Description complète (4000 caractères max, français)

```
RandomWalk transforme vos sorties à pied ou à vélo en aventure, sans jamais
dépendre d'une connexion internet.

NAVIGATION ET BOUCLES, 100% HORS-LIGNE
Un moteur de routage embarqué calcule vos itinéraires directement sur votre
téléphone : pas de connexion nécessaire, pas de données mobiles consommées,
ça fonctionne même en pleine nature ou en zone blanche.

Dites-lui simplement une distance ("je veux marcher 5 km") ou une durée
("j'ai 45 minutes devant moi") : RandomWalk génère plusieurs boucles
réalistes autour de votre position, avec une nouvelle proposition en un tap
si aucune ne vous convient. Vous pouvez aussi viser une destination précise
et laisser l'app calculer le meilleur itinéraire à pied.

EXPLORATION FAÇON JEU — LA CARTE SE DÉVOILE EN MARCHANT
Une carte brumeuse recouvre votre quartier : chaque trajet réel dévoile pour
de bon la zone que vous avez parcourue. Croisez des lieux culturels
remarquables — églises, points de vue, tours historiques — pour gagner de
l'XP, débloquer des badges et progresser en niveau. Un jeu léger, pensé pour
donner envie d'emprunter une rue jamais explorée plutôt que de refaire
toujours le même tour du pâté de maisons.

LE JEU NE BLOQUE JAMAIS LA MARCHE
Navigation, boucles et enregistrement de trajet fonctionnent à 100% même si
la couche de jeu est indisponible (ancienne carte, aucune donnée
d'exploration...). L'exploration est un bonus qui s'ajoute à l'app, jamais
une dépendance dont le reste a besoin pour fonctionner.

PENSÉ POUR LA VRAIE VIE
- Suivi fiable écran éteint, y compris après avoir balayé l'app hors des
  tâches récentes.
- Pause automatique du GPS quand vous êtes à l'arrêt (feu rouge, pause
  café), reprise immédiate au mouvement — pour préserver votre batterie sans
  jamais couper l'enregistrement par erreur.
- Instructions vocales en français pendant la navigation guidée.
- Historique de vos trajets passés, consultable à tout moment.
- Mode jour/nuit manuel pour la carte.

RESPECT DE LA VIE PRIVÉE, PAR DÉFAUT
- Fonctionne sans compte et sans connexion, dès l'installation.
- Vos trajets et traces GPS restent sur votre téléphone — jamais envoyés à
  un serveur.
- Un compte est optionnel, uniquement pour synchroniser votre progression
  entre plusieurs appareils et apparaître sur un classement.
- Aucune publicité. Aucun traqueur publicitaire. Aucun outil d'analyse
  tiers. Vos données s'exportent et se suppriment intégralement à tout
  moment depuis les réglages.

RandomWalk, c'est marcher (ou pédaler) sans itinéraire figé, sans connexion
obligatoire, et avec une bonne raison de prendre la rue d'à côté.
```
(≈2 680 caractères avec la mise en forme — largement sous la limite de 4000)

## Catégorie

**Suggestion principale : Cartes et navigation** (Maps & Navigation) — le
routage/la navigation hors-ligne est la fonctionnalité d'entrée de l'app.

**Alternative plausible : Santé et remise en forme** (Health & Fitness), si
l'angle marche/vélo/activité est jugé plus vendeur pour le public visé —
décision produit du propriétaire, les deux sont défendables ; à choisir une
fois pour ne pas déstabiliser le classement algorithmique du store par la
suite.

## Questionnaire de classification par âge (content rating / IARC)

Notes pour remplir le questionnaire officiel dans la Play Console (il repose
sur un tiers, IARC — ce document ne remplace pas le questionnaire, il
prépare les réponses) :

- **Violence** : aucune.
- **Contenu sexuel** : aucun.
- **Langage grossier** : aucun (textes de l'app entièrement rédigés par
  l'éditeur).
- **Substances contrôlées** : aucune mention.
- **Jeu d'argent simulé / achats intégrés réels** : aucun — les pièces et
  l'énergie du jeu sont des mécaniques internes sans aucun lien avec de
  l'argent réel, pas d'achat intégré.
- **Contenu généré par les utilisateurs partagé publiquement** : non — le
  seul élément visible par d'autres joueurs est un pseudo choisi
  librement sur un classement (pas de messagerie, pas de commentaires, pas
  de photos).
- **Partage de localisation** : **répondre "oui" à toute question du
  questionnaire portant sur la localisation** — l'app utilise activement le
  GPS (y compris en arrière-plan) pour sa fonctionnalité principale. Ne pas
  minimiser cette réponse : c'est exactement le type de sous-déclaration que
  Google Play sanctionne le plus sévèrement à la revue.
- **Public visé** : tout public (PEGI 3 / Everyone attendu), sous réserve du
  résultat réel du questionnaire IARC.

## Déclaration de la localisation en arrière-plan (formulaire Play dédié)

Indépendamment du questionnaire de classification, la Play Console impose un
formulaire séparé et obligatoire pour toute app demandant
`ACCESS_BACKGROUND_LOCATION` ("Permissions sensibles" → "Accès à la
position en arrière-plan"). Réponses attendues, reprises de
`docs/privacy-policy.md` section 1 :

- **Fonctionnalité principale nécessitant la localisation en
  arrière-plan** : enregistrement d'un trajet de marche/vélo (distance,
  durée, tracé) qui doit continuer quand l'écran s'éteint — un cas d'usage
  explicitement reconnu par la politique Play sur la localisation
  (fitness/activity tracking).
- Prévoir une courte vidéo ou des captures d'écran montrant : la demande de
  permission avec son explication en français avant la demande système, la
  notification persistante pendant l'enregistrement, et le fonctionnement
  écran éteint. (À préparer par le propriétaire au moment de la soumission —
  voir `docs/qa-device-checklist.md` section 1 pour le scénario exact à
  filmer.)

## Formulaire "Sécurité des données" (Data safety)

Mapping exact vers `docs/privacy-policy.md`. Catégories dans l'ordre du
formulaire Play Console (menu "App content" → "Data safety").

**Cette app collecte-t-elle ou partage-t-elle des données utilisateur ?**
Oui.

| Type de donnée | Collectée ? | Partagée avec un tiers ? | Finalité déclarée | Suppression possible ? | Note |
|---|---|---|---|---|---|
| Position précise | **Oui** | Non | Fonctionnalité de l'app | Oui | Traitée entièrement sur l'appareil (distance, map-matching, détection de lieux visités) ; **aucune coordonnée GPS précise/brute n'est jamais transmise à un serveur**, quel qu'il soit — voir cependant la ligne "Activité dans l'app" ci-dessous pour la donnée de localisation *approximative* qui, elle, est bien envoyée dès qu'un compte est configuré. Déclarée "collectée" par prudence de revue (l'app lit activement le GPS pour sa fonction principale), pas "partagée". |
| Position approximative | **Oui, seulement si un compte est créé** | Non | Fonctionnalité de l'app (synchronisation multi-appareils, reconstruction de la carte explorée) | Oui — "Supprimer mon compte" | **À ne pas sous-déclarer** : dès qu'un compte est configuré, le journal d'événements synchronisé encode les cellules géographiques explorées (grille d'environ 150 m de côté — jamais une coordonnée précise) et les identifiants des lieux culturels visités. C'est une donnée de localisation approximative réelle, distincte d'une trace GPS ou d'un tracé de trajet (qui, eux, ne sont jamais synchronisés — voir `docs/privacy-policy.md` section 3). Sans compte configuré, rien de tout cela ne quitte l'appareil. |
| Adresse e-mail | Oui, **seulement si un compte est créé** | Non | Authentification du compte (Supabase Auth) | Oui — "Supprimer mon compte" | Optionnelle : jamais collectée sans action explicite du joueur. |
| Identifiants utilisateur/appareil (pseudo + identifiant anonyme) | Oui | Non (le serveur `drive.lmqc.fr` est exploité par l'éditeur lui-même, pas un tiers) | Fonctionnalité de l'app (classement) | Oui — changer de pseudo/réinstaller | Identifiant généré aléatoirement sur l'appareil, jamais un identifiant publicitaire ou matériel (IMEI, AAID). |
| Activité dans l'app (journal d'événements de jeu : XP, badges, pièces, énergie, distance cumulée, **cellules de carte explorées, lieux culturels visités**) | Oui, **seulement si un compte est créé** | Non | Fonctionnalité de l'app (synchronisation multi-appareils, classement, reconstruction de la carte explorée) | Oui — "Supprimer mon compte" | Sans compte, rien de tout cela ne quitte l'appareil. Les deux derniers éléments (cellules/lieux) sont aussi de la localisation approximative — voir la ligne "Position approximative" ci-dessus, ne pas déclarer l'un sans l'autre. |
| Historique des trajets et traces GPS détaillées | **Non** | — | — | — | Jamais synchronisé, avec ou sans compte (`docs/privacy-policy.md` section 3) — reste local à chaque appareil, supprimable via la purge locale ou la désinstallation. |
| Activité physique / nombre de pas | **Non** | — | — | — | Utilisé uniquement comme signal local de reprise de mouvement (repli podomètre) et pour la mise en pause GPS batterie ; jamais transmis hors de l'appareil, donc non "collecté" au sens du formulaire Play. |
| Informations financières | Non | — | — | — | Aucun achat intégré, aucune donnée de paiement. |
| Publicité / identifiants publicitaires | Non | — | — | — | Aucun SDK publicitaire dans l'app. |
| Analyse d'usage / crash tiers | Non | — | — | — | Aucun outil d'analyse ou de mesure d'audience tiers intégré. |

**Sécurité des données en transit** : toutes les données qui quittent
effectivement l'appareil (compte, classement) transitent en HTTPS/TLS
(Supabase et `drive.lmqc.fr`).

**Le compte peut-il être supprimé ?** Oui — voir `docs/privacy-policy.md`
section 7 : suppression serveur immédiate et irréversible, purge locale
optionnelle proposée séparément.

## URL de la politique de confidentialité

À renseigner dans la Play Console une fois `docs/privacy-policy.html` publié
quelque part en HTTPS public — voir `docs/owner-handoff.md` étape 2 pour les
deux options suggérées (drive.lmqc.fr ou GitHub Pages).
