# RandomWalk — Guide propriétaire Supabase (≤ 5 min)

Ce guide s'adresse au propriétaire du compte Supabase (pas aux développeurs) : il
n'y a **aucune ligne de commande à taper**, tout se fait dans le dashboard web.
Objectif : créer le projet, appliquer le schéma, activer la connexion par
e-mail, puis récupérer les deux valeurs nécessaires pour compiler
l'application.

> Ce dossier ne contient pas d'instance Supabase réelle — ce guide décrit les
> écrans du dashboard tels qu'ils existaient à la rédaction (2026), à un clic
> près si Supabase a légèrement réorganisé un menu depuis.

## 1. Créer le projet (≈ 1 min)

1. Sur [supabase.com](https://supabase.com), **New project**.
2. Choisir une **organisation** (en créer une si c'est la première fois).
3. **Name** : `randomwalk` (ou ce qui vous convient — le nom n'a aucun impact
   technique).
4. **Database Password** : laisser Supabase en générer un fort et le
   sauvegarder dans un gestionnaire de mots de passe — l'app ne s'en sert
   jamais (elle utilise uniquement les deux valeurs de l'étape 4), mais il
   sert à l'accès direct à la base si un jour c'est nécessaire.
5. **Region** : `Central EU (eu-central-1)` — au plus proche des joueurs
   européens visés par l'app.
6. **Create new project** et patienter (~2 min de provisioning côté
   Supabase — le reste du guide peut être lu pendant ce temps).

## 2. Appliquer le schéma (≈ 1 min)

1. Dans le menu de gauche : **SQL Editor**.
2. **New query**.
3. Ouvrir le fichier [`migrations/0001_init.sql`](migrations/0001_init.sql)
   de ce dépôt, copier tout son contenu, le coller dans l'éditeur.
4. **Run** (bouton en bas à droite, ou `Ctrl+Enter`).
5. Vérifier qu'aucune erreur rouge ne s'affiche ("Success. No rows returned"
   est le résultat attendu).

Ce script crée les tables `game_events` et `profiles`, la sécurité au niveau
ligne (RLS) qui garantit que chaque compte ne voit que ses propres données, et
trois fonctions serveur (`push_events`, `top_profiles`, `delete_account`). Il
ne doit être exécuté qu'**une seule fois**, sur un projet neuf — ce n'est pas
un outil de migration incrémentale.

## 3. Activer la connexion par e-mail (≈ 1 min)

L'app se connecte par **code à usage unique envoyé par e-mail** (OTP à 6
chiffres), pas par mot de passe ni par lien magique — pour éviter toute
confusion, il faut désactiver le lien magique.

1. Menu de gauche : **Authentication** → **Providers** (ou **Sign In /
   Providers** selon la version du dashboard).
2. Cliquer sur **Email**.
3. Vérifier/ajuster ces réglages :
   - **Enable Email provider** : activé.
   - **Confirm email** : peut rester activé (n'affecte pas l'OTP).
   - **Enable Email OTP** (parfois listé comme **"OTP"** ou **"One-Time
     Password"** dans la même section) : **activé**.
   - **Enable Magic Link** (ou **"Passwordless sign-in via magic link"**) :
     **désactivé** — sinon Supabase peut envoyer un lien de connexion au lieu
     du code à 6 chiffres, ce que l'app ne sait pas traiter.
   - **Enable Email Signup** : activé (nécessaire pour qu'un nouvel e-mail
     puisse créer un compte via l'OTP).
4. **Save**.

Si les libellés exacts diffèrent légèrement de ceux ci-dessus (Supabase
réorganise son dashboard de temps en temps), chercher les mots-clés
**"OTP"** et **"Magic Link"** dans la section Email — l'un doit être activé,
l'autre désactivé.

## 4. Récupérer les clés (≈ 30 s)

1. Menu de gauche : **Project Settings** (icône engrenage) → **API** (ou
   **API Keys** selon la version).
2. Noter deux valeurs :
   - **Project URL** (ressemble à `https://xxxxxxxxxxxx.supabase.co`)
   - **anon public** key (une longue chaîne commençant par `eyJ...`) — **pas**
     la `service_role` key, qui ne doit jamais quitter ce dashboard.

> La clé `anon public` n'est pas un secret à proprement parler : Supabase la
> conçoit pour être embarquée dans une app publique (elle transite d'ailleurs
> en clair dans l'APK compilé ci-dessous). C'est la sécurité au niveau ligne
> (RLS), appliquée par le script SQL de l'étape 2, qui protège réellement les
> données — la clé seule ne donne accès à rien qu'un compte ne devrait pas
> voir. Elle reste à ne pas coller dans un dépôt public par prudence générale,
> mais une fuite de cette clé seule n'est pas une brèche de sécurité.

## 5. Compiler l'application

Depuis le dossier `app/` du dépôt, avec les deux valeurs de l'étape 4 :

```
flutter build apk --release --dart-define=SUPABASE_URL=https://xxxxxxxxxxxx.supabase.co --dart-define=SUPABASE_ANON_KEY=eyJ...
```

Sans ces deux `--dart-define`, l'app compile et fonctionne normalement mais
reste en mode local pur (comportement M4 identique, aucun appel réseau vers
Supabase, tuile "Compte" affichant "Synchronisation non configurée") — c'est
le comportement par défaut voulu, pas une erreur de configuration.

### Note pour plus tard : passer ces valeurs à la CI

Le jour où la compilation de l'AAB signé sera automatisée (voir
`docs/release-signing.md` et le job CI optionnel prévu en fin de projet M5),
ces deux valeurs devront être stockées comme **secrets** du dépôt (Settings →
Secrets and variables → Actions sur GitHub) et injectées au job via
`--dart-define=SUPABASE_URL=${{ secrets.SUPABASE_URL }}
--dart-define=SUPABASE_ANON_KEY=${{ secrets.SUPABASE_ANON_KEY }}` — jamais
écrites en clair dans un fichier du dépôt. Cette étape n'est pas encore
câblée ; ce paragraphe est un pense-bête pour la tâche qui l'ajoutera.

## 6. Checklist de vérification

Une fois l'APK ci-dessus installé sur un appareil :

- [ ] Dans l'app, ouvrir **Réglages → Compte**, saisir une adresse e-mail
      valide, demander le code.
- [ ] Un e-mail contenant un code à 6 chiffres arrive (vérifier aussi les
      spams) — recopier le code dans l'app.
- [ ] L'app affiche l'état "connecté" avec cet e-mail.
- [ ] Faire au moins un trajet (ou toute action qui écrit un événement) puis
      déclencher une synchronisation (automatique ou bouton manuel selon ce
      qui est livré).
- [ ] Dans le dashboard Supabase, **Table Editor** → table `profiles` :
      une ligne existe pour ce compte, avec le bon pseudo.
- [ ] **Table Editor** → table `game_events` : des lignes existent pour ce
      compte (une par événement du journal local synchronisé).
- [ ] **Authentication → Users** : le compte apparaît dans la liste, avec
      l'e-mail utilisé.

Si ces sept points sont vérifiés, la synchronisation Supabase est
opérationnelle de bout en bout.
