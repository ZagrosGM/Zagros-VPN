# WireGuard Android pinned artifact

The local Maven module `ai.zagros.thirdparty:wireguard-tunnel-go-only:1.0.20260102` under `third_party/maven/` contains a reproducible, narrowly stripped derivative of the official WireGuard Android tunnel library at:

`https://repo1.maven.org/maven2/com/wireguard/android/tunnel/1.0.20260102/tunnel-1.0.20260102.aar`

Upstream expected size: `5,830,762` bytes  
Upstream expected SHA-256: `2b9c16db026496123e4db695d26d03d1958a201096c7c4c89b21077dc70f3119`

Vendored derivative expected size: `13,421,589` bytes  
Vendored derivative SHA-256: `b8a8c73b701b4f6bd6baf99ae4251f8c90973ccf5b1c6201725f59b39c603931`

The upstream AAR contains `libwg.so` and `libwg-quick.so` from GPL-2.0 wireguard-tools. Zagros does not invoke, vendor, or package those libraries. `tool/prepare_wireguard_android.py` verifies the exact upstream bytes, removes only those native members, emits retained entries without zlib compression for cross-version reproducibility, verifies the derived digest, and asserts that `libwg-go.so` is its only native library name. The unmodified upstream AAR must not be committed or distributed from this repository.

The Android Gradle plugin resolves the derivative as an external module from an exclusive local-Maven group, avoiding Android library modules' unsafe direct-local-AAR packaging path, and recomputes the AAR digest during configuration. `embedded-native-sha256.json` locks every retained ABI/native-library member for comparison with final APK/AAB contents. Android app packaging also excludes the two unused names as defense in depth. Final Gradle package inspection remains required.

The matching Maven POM, Gradle module metadata, and Java/Kotlin sources JAR are retained at the hashes in `native-engine-lock.json`. The upstream metadata still names the original Maven artifact and is provenance input, not the artifact consumed by Gradle. The sources JAR is not complete source for the retained Go binary. The lock records the matching upstream tag/commit, embedded-native review, and unresolved source, dependency-license, reproducibility, and distribution gates.

The Java/Kotlin tunnel library is Apache-2.0; its license is copied here. The retained `wireguard-go` backend is MIT; its license, module-source notices, exact Android build glue, Go 1.24.3 toolchain notices, and ELF-identified Android NDK 27.0.12077973 notices are hash-locked under `third_party/wireguard-go/`. The official mirror parent-tag archive and signed tag identity are also locked. Four-ABI Android-tagged reachability found only the four expected external modules, and all four retained binaries were rebuilt and stripped byte-for-byte to the packaged hashes; the reports are under `third_party/wireguard-go/`. Final package and legal gates still apply.

The standalone Android adapter runtime/desugaring graph, artifact hashes, license evidence, and CycloneDX SBOM are under `third_party/android-runtime/`. This does not replace final Flutter APK/AAB dependency resolution and inspection. In particular, the vendored desugar 2.1.5 source snapshot remains only a version-matching candidate until reproducible artifact-to-source correspondence is proven.
