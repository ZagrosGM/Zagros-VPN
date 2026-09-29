import java.security.MessageDigest

plugins {
    id("com.android.library")
}

group = "ai.zagros.tunnel"
version = "0.2.0"

android {
    namespace = "ai.zagros.tunnel"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
        externalNativeBuild {
            cmake {
                arguments("-DENABLE_LIBRARY=ON")
            }
        }
        ndk {
            abiFilters.addAll(listOf("arm64-v8a", "armeabi-v7a", "x86_64", "x86"))
        }
    }

    externalNativeBuild {
        cmake {
            path = file("CMakeLists.txt")
        }
    }

    packaging {
        jniLibs {
            pickFirsts.add("**/libhev-socks5-tunnel.so")
            pickFirsts.add("**/libovpnexec.so")
            pickFirsts.add("**/libopenvpn.so")
            pickFirsts.add("**/libovpnutil.so")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }
}

val wireguardAar = rootProject.file(
    "../../../third_party/maven/ai/zagros/thirdparty/wireguard-tunnel-go-only/" +
        "1.0.20260102/wireguard-tunnel-go-only-1.0.20260102.aar",
)
val wireguardSha256 = "b8a8c73b701b4f6bd6baf99ae4251f8c90973ccf5b1c6201725f59b39c603931"
check(wireguardAar.isFile) { "Pinned WireGuard Android AAR is missing" }
val actualWireguardSha256 = MessageDigest.getInstance("SHA-256")
    .digest(wireguardAar.readBytes())
    .joinToString("") { "%02x".format(it) }
check(actualWireguardSha256 == wireguardSha256) {
    "Pinned WireGuard Android AAR digest mismatch"
}

// The embedded SSTP engine sources (kittoku/osc/**) are pinned by digest in
// third_party/sstp-client/lock.json (upstream Open SSTP Client, MIT). Every
// compiled copy must byte-match the locked digest or the build fails.
val sstpLockFile = rootProject.file("../../../third_party/sstp-client/lock.json")
check(sstpLockFile.isFile) { "Pinned SSTP engine lock file is missing" }
val sstpBaseDir = file("src/main/kotlin")
run {
    val slurper = groovy.json.JsonSlurper()
    @Suppress("UNCHECKED_CAST")
    val lock = slurper.parse(sstpLockFile) as Map<String, Any>
    @Suppress("UNCHECKED_CAST")
    val files = lock["files"] as Map<String, Map<String, String>>
    check(files.isNotEmpty()) { "Pinned SSTP engine lock file has no entries" }
    val digest = MessageDigest.getInstance("SHA-256")
    files.forEach { (rel, entry) ->
        val compiled = File(sstpBaseDir, rel)
        check(compiled.isFile) { "Pinned SSTP engine source is missing: $rel" }
        val actual = digest.digest(compiled.readBytes()).joinToString("") { "%02x".format(it) }
        val expected = entry["vendored_sha256"] ?: error("lock entry without digest: $rel")
        check(actual == expected) { "Pinned SSTP engine source digest mismatch: $rel" }
    }
}

dependencies {
    // The host Flutter build supplies embedding classes. A pinned compile-only
    // embedding is enabled only by the standalone native-source CI compile.
    if (providers.gradleProperty("zagrosStandaloneCompile").orNull == "true") {
        compileOnly(
            "io.flutter:flutter_embedding_debug:" +
                "1.0.0-a804b261645ef8c13eb3d5c44a5c2fb0340c5539",
        )
    }
    // Official reusable userspace/kernel WireGuard backend. The exact release,
    // artifact digest, source revision, and distribution blocks are recorded in
    // third_party/native-engine-lock.json.
    // Resolve as a hash-checked external Maven module rather than a direct local
    // AAR file dependency, which Android library modules cannot safely bundle.
    implementation("ai.zagros.thirdparty:wireguard-tunnel-go-only:1.0.20260102")
    implementation("androidx.annotation:annotation:1.9.1")
    implementation("androidx.collection:collection:1.5.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
