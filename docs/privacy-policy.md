# Politique de confidentialité — RandomWalk

**Dernière mise à jour : 3 septembre 2026**

Cette politique décrit quelles données l'application Android **RandomWalk**
(éditeur : lmqc, `fr.lmqc.randomwalk`) collecte, pourquoi, où elles sont
stockées, et comment les supprimer. Elle est écrite pour être lue par un
joueur, mais reprend aussi (section 8) les réponses exactes attendues par le
formulaire "Sécurité des données" de la Google Play Console — les deux
doivent rester cohérentes.

**Contact** : `contact@lmqc.fr` *(à confirmer par le propriétaire de
l'application avant publication — voir `docs/owner-handoff.md`)*.

## Résumé en une phrase

RandomWalk fonctionne **hors-ligne et sans compte par défaut** : sans
compte, vos trajets, votre journal de jeu et vos traces GPS restent
entièrement sur votre appareil. Créer un compte est **optionnel** et sert à
synchroniser votre progression (y compris, de façon approximative, les
zones explorées et les lieux visités — voir section 4) entre appareils et à
afficher votre pseudo sur un classement ; vos traces GPS détaillées et
l'historique complet de vos trajets, eux, ne sont **jamais** synchronisés,
compte ou pas (voir section 3). Il n'y a **aucune publicité, aucun traqueur
publicitaire et aucun outil d'analyse tiers** dans l'application.

## 1. Localisation en arrière-plan (« Autoriser tout le temps »)

RandomWalk demande la permission Android **"Localisation en arrière-plan"**
(`ACCESS_BACKGROUND_LOCATION`). Voici pourquoi, et pourquoi c'est nécessaire
au fonctionnement même de l'app plutôt qu'accessoire :

RandomWalk enregistre des trajets de marche ou de vélo (distance, durée,
tracé GPS) via un **service au premier plan** (notification persistante
visible en permanence pendant l'enregistrement, conformément aux règles
Android). Cet enregistrement doit continuer **quand l'écran est éteint** —
c'est l'usage normal d'une app de suivi de trajet : personne ne garde son
téléphone allumé en main pendant une heure de marche. Sans l'autorisation
"tout le temps", Android interrompt la remontée de position dès que l'écran
s'éteint ou que l'app passe en arrière-plan, ce qui casserait
l'enregistrement du trajet en cours.

- La position n'est utilisée **que pendant un trajet activement
  enregistré** (ou une navigation guidée activement en cours) — jamais en
  tâche de fond permanente, jamais pour un profilage de localisation en
  dehors de ces sessions explicitement démarrées par le joueur.
- La position est traitée **entièrement sur l'appareil** : calcul de
  distance, correspondance à la carte (map-matching hors-ligne via un moteur
  de routage embarqué), détection des lieux visités pour le jeu. Aucune
  position brute, aucun tracé GPS n'est jamais envoyé à un serveur.
- Une notification claire signale l'enregistrement en cours tant qu'il
  dure ; il peut être arrêté à tout moment depuis l'app.
- Une bannière propose de refuser l'accès permanent et de rester en mode
  "pendant l'utilisation" — l'app reste alors utilisable, mais
  l'enregistrement s'interrompt quand l'écran s'éteint (limitation du
  système d'exploitation, pas un choix de l'app).

## 2. Reconnaissance d'activité physique (podomètre / immobilité)

RandomWalk demande la permission Android **"Activité physique"**
(`ACTIVITY_RECOGNITION`), utilisée pour deux choses, toutes deux
strictement locales à l'appareil :

- **Économie de batterie** : détecter automatiquement quand vous êtes
  immobile (arrêté depuis plusieurs minutes) pour mettre en pause la prise
  de position GPS, puis reprendre dès que vous rebougez — sans que vous
  ayez besoin d'arrêter/relancer l'enregistrement manuellement.
- **Repli podomètre** : sur les appareils ou situations où le signal de
  mouvement précis n'est pas disponible, le nombre de pas du capteur
  matériel du téléphone sert de signal de secours pour détecter la reprise
  du mouvement.

Aucune donnée de pas ni d'activité n'est transmise hors de l'appareil ;
cette permission sert uniquement à optimiser la consommation de batterie
pendant l'enregistrement d'un trajet.

## 3. Données qui ne quittent jamais votre appareil, avec ou sans compte

Que vous ayez créé un compte ou non, les données suivantes ne sont **jamais
synchronisées ni envoyées** à un serveur, sous quelque forme que ce soit :

- **l'historique détaillé de vos trajets et leurs traces GPS point par
  point** — la synchronisation décrite section 4 ne porte que sur le
  journal d'événements de jeu, jamais sur cet historique ni sur une trace
  GPS complète ;
- **l'état complet, cellule par cellule, de votre carte explorée**
  (le fichier local qui accélère l'affichage du brouillard de guerre) —
  reconstruit et mis en cache localement, jamais transmis tel quel.

Ces données sont stockées dans l'espace de stockage privé de l'application
et supprimées si vous désinstallez RandomWalk (ou via la suppression locale
proposée section 7).

**Ce qui, en revanche, fait partie du journal de jeu synchronisable dès
qu'un compte est configuré** — XP, badges, pièces, énergie, mais aussi les
cellules de carte explorées et les lieux culturels visités — est décrit
sans détour section 4 : ne le cherchez pas ici, cette section ne concerne
que ce qui reste strictement local dans tous les cas.

## 4. Compte et synchronisation (optionnel)

RandomWalk peut fonctionner **sans jamais créer de compte** — c'est le
comportement par défaut, identique à une version de l'app qui n'aurait pas
cette fonctionnalité du tout.

Si vous choisissez de créer un compte (Réglages → Compte, connexion par
code à usage unique envoyé par e-mail — pas de mot de passe), les données
suivantes sont envoyées à notre serveur **Supabase**, hébergé dans l'Union
européenne (région Francfort/UE centrale) :

| Donnée envoyée au serveur | Pourquoi |
|---|---|
| Votre adresse e-mail | Authentification (code de connexion), gérée par le fournisseur d'authentification Supabase |
| Votre pseudo | Affiché sur le classement, synchronisé entre vos appareils |
| Votre distance totale cumulée (km) | Classement, synchronisée entre vos appareils |
| Votre journal d'événements de jeu — XP, badges, pièces, énergie, **cellules de la carte explorées et lieux culturels visités** | Permet de reconstituer et fusionner votre progression (y compris la carte explorée) sur plusieurs appareils |

**Ce que ce journal contient précisément, et ce qu'il ne contient pas** :
chaque « cellule explorée » est une case d'environ 150 m × 150 m de la
grille interne du jeu — une zone approximative, pas une position précise —
et chaque « lieu visité » est référencé par l'identifiant du point d'intérêt
culturel concerné (église, point de vue, tour...) dans notre base
embarquée, pas par des coordonnées. **Ce journal ne contient jamais vos
coordonnées GPS brutes ni le tracé complet d'un trajet** (ces données-là
restent toujours locales, avec ou sans compte — voir section 3). Mais soyez
clair avec vous-même sur ce que cela veut dire : dès qu'un compte est
configuré, le journal envoyé au serveur révèle bel et bien, de façon
approximative, les zones que vous avez explorées et les lieux culturels que
vous avez visités — ce n'est pas rien, même si ce n'est pas un tracé GPS.
**Sans compte configuré, rien de tout cela ne quitte jamais l'appareil.**

Un compte n'a de sens qu'associé à au moins un appareil ; la sécurité des
données est assurée par des règles d'accès strictes côté base de données
(chaque compte ne peut lire/écrire que ses propres données), pas par la
confidentialité d'une clé technique.

Sans compte configuré, aucune de ces données n'est jamais envoyée où que ce
soit — l'app se comporte exactement comme une version entièrement
hors-ligne.

## 5. Classement anonyme (`drive.lmqc.fr`)

Indépendamment d'un compte, RandomWalk peut soumettre votre score à un
classement communautaire simple et anonyme, hébergé sur `drive.lmqc.fr`.
Sont envoyés :

- un **identifiant d'appareil généré aléatoirement** (pas votre e-mail, pas
  d'identifiant publicitaire, pas d'identifiant matériel) ;
- votre **pseudo** (modifiable librement dans les réglages, ne doit pas
  être votre nom réel) ;
- votre **distance totale cumulée** (km), plafonnée à un maximum
  plausible par jour côté serveur pour limiter les scores aberrants.

Aucune coordonnée GPS, aucun tracé de trajet, aucune donnée de localisation
n'est envoyée à ce classement — uniquement un total de distance. Ce
classement fonctionne indépendamment du compte Supabase optionnel décrit
ci-dessus (deux mécanismes distincts, jamais reliés entre eux côté
serveur).

## 6. Export de vos données

Réglages → « Exporter mes données » génère un fichier JSON contenant
l'intégralité de vos données locales (profil, journal de jeu, informations
de compte si connecté) et vous permet de le partager ou de l'enregistrer
via le sélecteur de partage standard d'Android. C'est votre droit d'accès
et de portabilité RGPD, exerçable à tout moment, sans contacter personne.

## 7. Suppression de compte et de vos données locales (droit RGPD à
   l'effacement)

Réglages → Compte → « Supprimer mon compte » :

1. Supprime définitivement, côté serveur, votre compte, votre e-mail
   d'authentification, votre profil (pseudo, distance) et l'intégralité de
   votre journal d'événements synchronisé — irréversible.
2. Vous propose ensuite, séparément, de **purger aussi vos données
   locales** sur cet appareil (journal de jeu, historique des trajets et
   leurs traces, état de la carte explorée) — ou de les conserver
   localement même après suppression du compte, à votre choix.

Désinstaller l'application supprime également toutes les données locales
restantes, immédiatement.

Le classement anonyme (`drive.lmqc.fr`, section 5) n'étant lié à aucune
identité vérifiable (ni e-mail, ni compte), sa suppression se fait en
changeant simplement de pseudo/identifiant d'appareil (réinstallation) ; il
ne conserve aucune donnée permettant de vous identifier personnellement.

## 8. Ce que RandomWalk ne fait pas

- **Pas de publicité**, pas de SDK publicitaire, pas d'identifiant
  publicitaire utilisé.
- **Pas d'outil d'analyse comportementale ou de mesure d'audience tiers**
  (pas de Google Analytics, Firebase Analytics, Crashlytics commercial, ou
  équivalent).
- **Pas de revente ni de partage de données** avec des tiers à des fins
  commerciales.
- **Pas de profilage** au-delà de ce qui est strictement nécessaire au jeu
  lui-même (badges, XP, classement).

## 9. Correspondance avec le formulaire "Sécurité des données" (Google Play)

Voir `release/play-listing.md`, section "Data safety form", pour le mappage
exact case par case de cette politique vers les réponses du formulaire Play
Console — les deux documents doivent toujours être mis à jour ensemble.

## 10. Modifications de cette politique

Toute évolution notable de cette politique (nouvelle donnée collectée,
nouveau service tiers) sera reflétée ici avant la mise à jour de
l'application correspondante, avec une date de mise à jour révisée en haut
de ce document.
