# Guide de remise au propriétaire — publication RandomWalk 1.0.0

Ce document est **la** liste exacte des actions restant à faire par le
propriétaire du projet pour publier RandomWalk — tout le reste (code,
tests, CI, textes) est déjà livré. Trois actions, dans cet ordre logique
(la 1 doit précéder la 2 si la synchronisation doit être active dans la
version publiée ; la 3 peut se faire en parallèle des deux autres, sur les
builds déjà produits par la CI).

---

## Action 1 — Configurer Supabase (≈ 5 minutes, aucune ligne de commande)

Guide détaillé, écran par écran : **`supabase/README.md`**. Résumé des
étapes :

1. Créer le projet Supabase (région **Central EU / eu-central-1**).
2. Appliquer le schéma SQL : coller tout le contenu de
   `supabase/migrations/0001_init.sql` dans le **SQL Editor** du dashboard
   et l'exécuter une fois (crée les tables `game_events`/`profiles`, la
   sécurité au niveau ligne, et les fonctions `push_events`/`top_profiles`/
   `delete_account`).
3. Activer la connexion par e-mail : **Authentication → Providers → Email**
   — activer **Email OTP**, désactiver **Magic Link**.
4. Récupérer les deux valeurs dans **Project Settings → API** :
   - `Project URL`
   - `anon public` key (**pas** la `service_role` key)

Ces deux valeurs alimentent le build de l'app via `--dart-define` :

```
flutter build appbundle --release ^
  --dart-define=SUPABASE_URL=https://xxxxxxxxxxxx.supabase.co ^
  --dart-define=SUPABASE_ANON_KEY=eyJ...
```

*(`^` = continuation de ligne Windows `cmd.exe` ; en PowerShell utiliser
`` ` `` en fin de ligne, ou tout mettre sur une seule ligne.)*

**Si cette étape est sautée ou repoussée** : l'app se compile et fonctionne
normalement sans elle — comportement 100% local, identique à la version M4,
tuile "Compte" affichant "Synchronisation non configurée". Rien n'empêche de
publier une première version 1.0.0 sans compte/sync configuré, puis
d'ajouter Supabase plus tard via une mise à jour (aucune migration de
données nécessaire : les joueurs déjà installés gagneront simplement l'écran
Compte à la mise à jour suivante).

**Checklist de vérification** une fois configuré : section 6 de
`supabase/README.md` (créer un compte de test dans l'app, vérifier les
lignes dans `profiles`/`game_events`/`Authentication → Users`).

---

## Action 2 — Publier sur Google Play

### 2a. Compte développeur

Si ce n'est pas déjà fait : créer un compte développeur Google Play
(console.play.google.com), frais unique de 25 USD, vérification d'identité
qui peut prendre quelques jours — **à démarrer tôt**, indépendamment du
reste, si le compte n'existe pas encore.

### 2b. Obtenir un AAB signé

Deux façons d'obtenir le fichier `.aab` (Android App Bundle) à uploader :

**Option A — build local**, une fois `app/android/key.properties` en place
(voir `docs/release-signing.md` pour la génération/l'emplacement du
keystore, déjà fait une fois pour ce projet) :

```
flutter build appbundle --release ^
  --dart-define=SUPABASE_URL=https://xxxxxxxxxxxx.supabase.co ^
  --dart-define=SUPABASE_ANON_KEY=eyJ...
```

Fichier produit : `app/build/app/outputs/bundle/release/app-release.aab`.

**Option B — job CI `aab`** (`.github/workflows/ci.yml`) : déclenché à la
main depuis l'onglet **Actions** du dépôt GitHub ("Run workflow") — ne
tourne jamais automatiquement sur un push. Produit un AAB signé si les
secrets `ANDROID_KEYSTORE_BASE64`/`ANDROID_STORE_PASSWORD`/
`ANDROID_KEY_PASSWORD`/`ANDROID_KEY_ALIAS` et `SUPABASE_URL`/
`SUPABASE_ANON_KEY` sont configurés (Settings → Secrets and variables →
Actions) — voir `docs/release-signing.md`, section "Optional CI job: aab",
pour la procédure complète (y compris comment encoder le keystore en
base64). Le fichier `.aab` produit est téléchargeable comme artefact du run
(`randomwalk-aab`) depuis la page de résumé du run terminé.

**Vérifier la signature avant upload** (les deux options) :
```
apksigner verify --print-certs app-release.aab
```
et comparer l'empreinte SHA-256 avec celle enregistrée dans Play App
Signing pour cette app (si c'est la toute première publication, cette
vérification n'a rien à comparer — elle sert surtout pour les mises à jour
suivantes).

### 2c. Remplir la fiche store

Tous les textes sont prêts dans **`release/play-listing.md`** — copier tel
quel dans la Play Console (**Grow → Store presence → Main store listing**) :
titre, description courte, description complète, suggestion de catégorie.

### 2d. Questionnaire de classification par âge + déclaration localisation
    arrière-plan

Voir `release/play-listing.md`, sections dédiées — en particulier :
répondre **"oui"** à toute question sur la localisation dans le
questionnaire de classification (App content → Content ratings), et remplir
le formulaire séparé et obligatoire "Background location" (App content →
Permissions déclarations) en expliquant que le suivi de trajet doit
continuer écran éteint (justification déjà rédigée dans
`release/play-listing.md`).

### 2e. Formulaire "Sécurité des données" (Data safety)

Table de correspondance exacte, ligne par ligne, dans
`release/play-listing.md` — section "Formulaire Sécurité des données". Ne
pas remplir ce formulaire de mémoire : chaque ligne y est déjà mappée à la
politique de confidentialité pour éviter tout écart entre les deux (un écart
est un motif fréquent de rejet à la revue Play).

### 2f. URL de la politique de confidentialité

La Play Console exige une URL HTTPS publique. Le fichier prêt à publier est
**`docs/privacy-policy.html`** (autonome, ne dépend d'aucune ressource
externe). Deux options simples pour l'héberger :

- **`drive.lmqc.fr`** (infrastructure déjà utilisée par le projet pour le
  classement anonyme) : déposer le fichier tel quel, ex.
  `https://drive.lmqc.fr/randomwalk/privacy-policy.html`.
- **GitHub Pages** sur ce dépôt : activer Pages sur la branche
  souhaitée/dossier `docs/`, l'URL devient alors quelque chose comme
  `https://igapon.github.io/randomwalk/privacy-policy.html`.

Coller l'URL choisie dans **App content → Privacy policy** et dans le champ
correspondant de la fiche store.

- [ ] **Remplacer l'adresse de contact avant publication.** Le champ
  "Contact" en haut de `docs/privacy-policy.md` **et** de
  `docs/privacy-policy.html` (les deux fichiers, pas un seul — le `.html`
  porte aujourd'hui un bandeau TODO visible juste au-dessus de l'adresse
  pour qu'il soit impossible de le publier tel quel par inadvertance)
  contient actuellement un placeholder, `contact@lmqc.fr` — à confirmer ou
  remplacer par l'adresse de contact réelle choisie par le propriétaire, et
  le bandeau TODO à retirer du `.html` une fois fait.

### 2g. Envoyer en revue

Uploader l'AAB dans une piste de test interne ou fermée d'abord (recommandé
pour une première publication), vérifier l'installation sur un appareil
réel, puis promouvoir vers la production.

---

## Action 3 — QA sur appareil réel

Checklist complète et déjà à jour : **`docs/qa-device-checklist.md`** (8
sections : navigation écran éteint, TTS, planification, aventure/jeu,
permissions, marqueurs logcat, bannières GPS/couverture, compte et
synchronisation). Tout ce qui dépend d'un vrai GPS, d'un comportement
OS/OEM réel, ou d'un vrai projet Supabase (section 8 — impossible à tester
en CI) doit être vérifié là, sur un téléphone Android physique, avant la
promotion en production.

La section 8 ("Compte et synchronisation") ne peut être cochée qu'**après**
l'action 1 ci-dessus (il faut un vrai projet Supabase pour la vérifier).

---

## Backlog technique reporté — M6

Éléments identifiés pendant M5 mais volontairement **non traités** dans ce
jalon (jugés soit non triviaux, soit hors scope d'une tâche donnée) :

1. **Diff des symboles de carte par identifiant** (repère ledger M4 :
   "symbols diff par id si trivial, sinon documenté") — les couches de
   marqueurs sur la carte (points d'intérêt, repères de jeu) sont
   aujourd'hui recréées en bloc à chaque rafraîchissement plutôt que
   diffées symbole par symbole (ajout/suppression uniquement de ce qui a
   changé, par id) — même famille de problème que le bug de "repères
   fantômes" corrigé en tâche 2e pour les lignes de route
   (`updateLine` en place plutôt que suppression+recréation). **Non
   trivial** : nécessite le harnais de test ci-dessous (item 2) pour être
   fait sans régression silencieuse — reporté, pas traité "à l'aveugle".
2. **Harnais de test `MapLibreMapController` factice** — lacune
   transversale identifiée dès la tâche 2e (confirmée en 2j) : aucun faux
   contrôleur de carte n'existe pour tester en isolation les mises à jour
   de couches (lignes, symboles, sources) sans dépendre d'un vrai widget
   carte. Bloque proprement l'item 1 ci-dessus et tout futur test
   d'idempotence de rafraîchissement de couche.
3. **Test adverse pour la simplification Douglas-Peucker** — l'algorithme
   de simplification d'affichage du tracé de route
   (`app/lib/nav/` — introduit/optimisé en tâche 2l pour le gel au
   démarrage/replanification) est O(n²) dans le pire cas sur l'isolate UI ;
   aucun test n'existe avec une entrée pathologique construite pour
   maximiser ce coût. À date, seules des traces réelles ont été mesurées.
4. **Synchronisation de l'historique des trajets** — `TripHistoryStore`
   (historique détaillé introduit en tâche 2f, avant la conception de la
   synchronisation) n'est **pas** synchronisé par le moteur de sync M5 (qui
   ne couvre que le journal d'événements de jeu) : l'historique des trajets
   reste local à chaque appareil, jamais fusionné entre plusieurs appareils
   d'un même compte.
5. **Nouvelle source de pièces (coins)** — la tâche 2k a retiré la seule
   source existante de pièces (visites de POI banque/distributeur, POIs
   désormais recentrés sur le patrimoine culturel) ; le HUD masque la pastille
   pièces tant qu'aucune source n'existe, mais les réducteurs et l'état
   restent en place (identité de rejeu M4 préservée). Une décision produit
   reste à prendre sur la prochaine source de pièces, le cas échéant.
6. **Taille du checkpoint d'état de jeu en O(cellules)** — le fichier
   `game_state_checkpoint.json` (tâche 5) grossit linéairement avec le
   nombre de cellules de carte explorées, sans compression ni pagination ;
   acceptable aux volumes actuels, à surveiller si l'exploration cumulée
   d'un joueur de longue date devient significative.

Ces six points sont candidats pour la planification M6 ; aucun n'est
bloquant pour la publication 1.0.0.
