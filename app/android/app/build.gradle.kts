import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Upload keystore credentials (see docs/release-signing.md). key.properties is
// gitignored and never committed — CI (and any fresh checkout) simply has no
// file here, which the null-safe reads below turn into a clean fallback to
// debug signing rather than a build failure. This mirrors the standard
// `flutter create` template for release signing, just spelled out instead of
// left as a TODO — see the release buildType below.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "fr.lmqc.randomwalk"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications' own Android module compiles with this
        // on (see its android/build.gradle) — minSdk 24 here is below API 26,
        // where java.time/java.util.concurrent's newer surface only exists
        // via desugaring, and AGP requires the *consuming* app module to opt
        // in too, not just the library that needs it.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "fr.lmqc.randomwalk"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Real upload signing when key.properties is present (a developer
            // machine with the keystore set up — see docs/release-signing.md);
            // falls back to the debug keys otherwise so `flutter build apk
            // --release`/`flutter run --release` keep working with no secret
            // configured, in particular in CI, which never has one.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // Item 6: this fallback is silent-by-default and produces an
                // APK that installs and runs fine, which is exactly what
                // makes it dangerous — a debug-signed "release" build handed
                // to a real device (or, worse, uploaded somewhere) looks
                // indistinguishable from the real thing until the Play Store
                // (or `apksigner verify`) rejects the mismatched signature.
                // `println` (not `logger.warn`, which most `./gradlew`
                // invocations swallow below `--info`) so the fallback is
                // impossible to miss in ordinary build output — every
                // `flutter build apk --release`/`flutter run --release` in
                // CI hits this branch too, and that is expected: CI never
                // has key.properties (see above), so it should keep saying so
                // on every run, not just the first one a developer forgets.
                println(
                    "WARNING: no key.properties found — release build is " +
                        "signed with the DEBUG keystore, not an upload key. " +
                        "See docs/release-signing.md."
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("io.github.rallista:valhalla-mobile:0.6.3")
    // Version matched to flutter_local_notifications-22.3.0's own module —
    // see the compileOptions comment above for why the app module needs it
    // too.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // M5 Task 2d (low-power mode): MotionChannel.kt's Activity Recognition
    // Transition API (ActivityRecognitionClient, ActivityTransition,
    // DetectedActivity, ...). geolocator_android already pulls this in as
    // an `implementation` dependency of its own Gradle module, which Gradle
    // does not expose to this app module's compile classpath — declared
    // here too, pinned to the exact version geolocator_android-5.0.3 itself
    // uses (see its android/build.gradle) to avoid two different resolved
    // versions of the same artifact.
    implementation("com.google.android.gms:play-services-location:21.2.0")
}

flutter {
    source = "../.."
}
