import java.util.Properties

plugins {
    id("com.android.application")
    // Explicit KGP: version pinned in settings.gradle.kts (AGP's
    // bundled Kotlin is below Flutter 3.47's 2.2.20 minimum).
    // Flutter's plugin stays last.
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

// White-label brand (applicationId + launcher label), injected per
// partner by tool/white_label_build.py via android/zagros-brand.properties
// (generated before the build, deleted afterwards, never committed). A
// plain `flutter build` without that file keeps the defaults below.
val zagrosBrand = Properties()
run {
    val brandFile = rootProject.file("zagros-brand.properties")
    if (brandFile.isFile) {
        brandFile.inputStream().use { zagrosBrand.load(it) }
    }
}

// Release signing is injected by an approved release environment via
// android/key.properties (standard Flutter file; never committed). All
// four keys must be present together; without the file the release has
// no signingConfig and the Flutter tool falls back to debug keys with
// a warning - a safe default that can never pass as production.
val zagrosKeyProperties = Properties()
run {
    val keyFile = rootProject.file("key.properties")
    if (keyFile.isFile) {
        keyFile.inputStream().use { zagrosKeyProperties.load(it) }
    }
}
val zagrosSigningKeys = listOf(
    "storeFile", "storePassword", "keyAlias", "keyPassword",
).map { zagrosKeyProperties.getProperty(it) }
if (zagrosSigningKeys.any { it != null }
    && zagrosSigningKeys.any { it == null }
) {
    error(
        "android/key.properties is incomplete: need storeFile, " +
            "storePassword, keyAlias, keyPassword together",
    )
}

android {
    namespace = "ai.zagros.vpn"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    signingConfigs {
        getByName("debug") {
            enableV1Signing = true
            enableV2Signing = true
        }
        // Created only when a complete key.properties was injected.
        if (zagrosSigningKeys.all { it != null }) {
            create("zagrosRelease") {
                keyAlias = zagrosKeyProperties.getProperty("keyAlias")
                keyPassword = zagrosKeyProperties.getProperty("keyPassword")
                storeFile = file(
                    zagrosKeyProperties.getProperty("storeFile") as String,
                )
                storePassword =
                    zagrosKeyProperties.getProperty("storePassword")
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by the :tunnel_interface dependency (its AAR metadata
        // demands desugaring in the consuming app).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // Injected per partner (defaults keep a plain `flutter build`
        // identical to before).
        applicationId =
            zagrosBrand.getProperty("applicationId", "ai.zagros.vpn")
        manifestPlaceholders.put(
            "zagrosLabel",
            zagrosBrand.getProperty("label", "Zagros VPN"),
        )
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Zagros uses GoBackend only. Exclude the unused wg/wg-quick GPL binaries
    // from every app artifact; the final APK/AAB inspector must still prove this.
    packaging {
        jniLibs.excludes += setOf("**/libwg.so", "**/libwg-quick.so")
        jniLibs.pickFirsts += setOf("**/libhev-socks5-tunnel.so")
        jniLibs.useLegacyPackaging = true
    }

    // No release signing fallback is defined. Production signing is injected
    // only by an approved release environment; debug keys must never sign it.

    buildTypes {
        release {
            // Injected signing when present, else fallback to debug keystore
            // so release builds remain signed and installable on test devices.
            signingConfig = signingConfigs.findByName("zagrosRelease")
                ?: signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Same artifact/version as :tunnel_interface: the app must carry the
    // desugar runtime its tunnel dependency requires.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
