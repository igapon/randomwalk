# Release signing (Android upload key)

RandomWalk's Android release build signs with a real upload keystore when
one is configured locally, and transparently falls back to the Flutter
debug keystore otherwise — see `app/android/app/build.gradle.kts`. This
means:

- **CI never has a keystore and stays green.** The `apk` and `integration`
  jobs build `--debug`, and even the Gradle *configuration* phase (which
  evaluates the `release` buildType's `signingConfig` regardless of which
  variant is actually assembled) resolves to the debug signing config
  whenever `app/android/key.properties` is absent. Nothing in CI needs to
  know this keystore exists.
- **A real release build needs `key.properties` populated locally** (see
  below) on whichever machine produces the upload artifact for the Play
  Console.

## What was generated

A local upload keystore was generated once with the JDK 17 `keytool`:

```
keytool -genkeypair -v \
  -keystore %USERPROFILE%\randomwalk-upload.jks \
  -alias upload \
  -keyalg RSA -keysize 2048 -validity 10000
```

- **Location:** `%USERPROFILE%\randomwalk-upload.jks` — deliberately
  *outside* the repository, in the operator's home directory, so it can
  never be accidentally committed regardless of `.gitignore` state.
- **Alias:** `upload`
- **Algorithm / size / validity:** RSA 2048, 10000 days (~27 years) — this
  is the *upload* key Google Play re-signs behind (Play App Signing), not
  the certificate end users ultimately see, so its own longevity mostly
  just needs to outlast this project's active development.
- **Password:** a freshly generated, random, strong password — **not
  written anywhere in this repository or in any report**. It lives only in
  `app/android/key.properties` (below) and in whatever password manager /
  secret store the operator who generated it chooses to keep it in. If
  that copy is lost, the fix is generating a *new* upload keystore and
  re-registering it as this app's upload key in the Play Console (Google
  Play App Signing supports upload-key resets); it is not stored anywhere
  else, by design — do not "recover" it by weakening this setup.

## `app/android/key.properties`

Read by `build.gradle.kts` at Gradle configuration time. **Never
committed** — `app/android/.gitignore` already excludes `key.properties`,
`**/*.keystore` and `**/*.jks` (this predates task 8; nothing needed
changing there). Format:

```properties
storePassword=<the generated password>
keyPassword=<the same password>
keyAlias=upload
storeFile=C:/Users/<you>/randomwalk-upload.jks
```

Notes on the format:

- `storeFile` uses forward slashes even on Windows. Java's `Properties`
  parser treats backslash as an escape character, so a literal Windows
  backslash path needs doubling (`\\`) to round-trip correctly — forward
  slashes sidestep that entirely and Gradle's `file(...)` resolves them
  fine on Windows.
- Both passwords are the same here (store and key), which is the common
  case for a single-purpose upload keystore; they are independent settings
  and could differ.

To build a real signed release once `key.properties` is in place:

```
flutter build appbundle --release
```

## Setting this up on a new machine

1. Obtain the existing `randomwalk-upload.jks` from wherever it is
   privately kept (do not generate a *new* one for an app already
   published — see the password-loss note above) and place it at
   `%USERPROFILE%\randomwalk-upload.jks` (or any path — just update
   `storeFile` accordingly).
2. Recreate `app/android/key.properties` with the four fields above.
3. `flutter build appbundle --release` should now sign with the upload key
   — verify with `keytool -printcert -jarfile build/app/outputs/.../*.aab`
   or `apksigner verify --print-certs`, and confirm the SHA-256
   fingerprint matches what the Play Console has on file for this app's
   upload key.

No `key.properties`? The release build still succeeds, signed with the
debug keystore — safe for local testing, but **not** installable as an
update over a Play-distributed build and **not** what should ever be
uploaded to the Play Console.

## Optional CI job: `aab` (workflow_dispatch only)

`.github/workflows/ci.yml` has a fifth job, `aab`, that builds a release
Android App Bundle (`.aab` — the format the Play Console requires, not the
`.apk` the other jobs build). It never runs on `push`/`pull_request` — only
when triggered by hand from the GitHub Actions tab ("Run workflow") — so it
can never turn the ordinary push-triggered CI gate red.

It reuses the exact same fallback logic described above: if the four
`ANDROID_*` repository secrets below are configured, it reconstructs
`key.properties` and a keystore file from them before building, producing a
real upload-signed AAB; if they are absent, it skips that step entirely and
`build.gradle.kts`'s own existing fallback signs with the debug keystore
instead, with the same loud `println` warning — so the job always succeeds,
but only a real-secrets run produces something installable as a Play
Console update.

To configure real signing secrets (GitHub repo → **Settings** → **Secrets
and variables** → **Actions** → **New repository secret**):

| Secret name | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | The upload keystore file, base64-encoded (see command below) |
| `ANDROID_STORE_PASSWORD` | The `storePassword` from `key.properties` |
| `ANDROID_KEY_PASSWORD` | The `keyPassword` from `key.properties` (same value here, see the note above) |
| `ANDROID_KEY_ALIAS` | `upload` |

Encoding the keystore for the `ANDROID_KEYSTORE_BASE64` secret:

```
# Windows (PowerShell)
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\randomwalk-upload.jks")) | Set-Clipboard

# Linux/macOS
base64 -w0 ~/randomwalk-upload.jks
```

Paste the resulting single-line string as the secret's value.

Two more secrets are optional and independent of signing —
`SUPABASE_URL`/`SUPABASE_ANON_KEY` (see `supabase/README.md`): if set, the
AAB is built with sync/leaderboard-via-Supabase enabled; if unset, the build
falls back to the same unconfigured, M4-identical local-only behavior every
other CI job already produces. Never store the Supabase **service role**
key anywhere — only the `anon` public key belongs here, exactly as in a
local build.

The built AAB is uploaded as a workflow artifact (`randomwalk-aab`),
downloadable from the completed run's summary page — that is the file to
hand to the Play Console (see `docs/owner-handoff.md`).
