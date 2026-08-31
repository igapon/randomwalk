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
