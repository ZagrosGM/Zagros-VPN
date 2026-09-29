# Third-party notices and unresolved distribution gates

This file records native components reviewed during Phase 10. It is **not** a statement that a Zagros client binary is approved for distribution. No release artifact has been built or approved.

## WireGuard Android tunnel library

- Component: `com.wireguard.android:tunnel:1.0.20260102`
- Upstream: <https://git.zx2c4.com/wireguard-android/>
- Tagged source: <https://git.zx2c4.com/wireguard-android/snapshot/wireguard-android-1.0.20260102.tar.xz>
- Tag object: `3831cab2da844319291459308a6e535d36dde4b3`
- Tagged commit: `09b75c2bd37f749e2a8c85876394854113c74be7`
- Upstream Maven artifact SHA-256: `2b9c16db026496123e4db695d26d03d1958a201096c7c4c89b21077dc70f3119`
- Vendored GoBackend-only Maven derivative: `ai.zagros.thirdparty:wireguard-tunnel-go-only:1.0.20260102` under `third_party/maven/`
- Vendored derivative SHA-256: `b8a8c73b701b4f6bd6baf99ae4251f8c90973ccf5b1c6201725f59b39c603931` (the Gradle build recomputes this digest)
- Declared Maven license: Apache License 2.0
- License copy: [`third_party/wireguard-android/LICENSE-APACHE-2.0`](third_party/wireguard-android/LICENSE-APACHE-2.0)

## sing-box universal core daemon (Out-of-Process)

- Component: `sing-box:1.11.15`
- Upstream: <https://github.com/SagerNet/sing-box>
- Tag: `v1.11.15`
- Tagged revision: `bc35aca01704497c179da1a03e45ad8e32f1a51b`
- License: GNU General Public License Version 3 or later (`GPL-3.0-or-later`) with upstream trademark clause.
- Architecture: Out-of-Process daemon executable (`libsingbox.so` / `sing-box`) communicating with the host client exclusively via local IPC / Unix domain socket.
- Per-ABI pinned binary SHA-256 digests (locked in `third_party/singbox/lock.json`):
  - `arm64-v8a`: `075a8e5486f002e8118cf38e2dad62606090eec57f7a2919ee775350ccef55fc`
  - `armeabi-v7a`: `db80b42224ee52a0005d3ab5c4b25b6a8811d11182e3e71e597afa104ffffd84`
  - `x86_64`: `a6af22e0a99924c95171c55be06f3b0178e63683f1d23c1180c93a6fac5f82bc`
  - `linux-amd64`: `a85f1a825a1efeee378b6eae08e299b4142d6217c41d7e16b266a1d79262ab81`
- Trademark notice: The name “sing-box” is not used in product branding, UI labels, or marketing. Protocols are presented under their generic standard protocol names (e.g. VLESS, VMess, Trojan, Shadowsocks, Hysteria 2, TUIC, SSH).
- Corresponding source offer: A written offer for the exact upstream corresponding source archive is included in the application legal notices.

## hev-socks5-tunnel bridge daemon

- Component: `hev-socks5-tunnel:2.17.1`
- Upstream: <https://github.com/heiher/hev-socks5-tunnel>
- Tag: `2.17.1`
- Pinned commit: `9a06bc6e7989da54e3d32ff701ef7a7ce4995d3a`
- License: MIT License (`third_party/hev-socks5-tunnel/LICENSE-MIT`).
- Architecture: High-performance Layer-3 TUN to SOCKS5 bridge daemon converting raw system IP packets from Android `VpnService` to local sing-box mixed/SOCKS5 proxy port.
- Per-ABI pinned binary SHA-256 digests (locked in `third_party/hev-socks5-tunnel/lock.json`):
  - `arm64-v8a`: `b481e0c78c45587b6a4c0a68c5b3b923f33a4864700242ab77b04436b00409f0`
  - `armeabi-v7a`: `b02663886f071dce11c44cb6eb991cc69b9045eb727801ba55fd2df06334192f`
  - `x86_64`: `2d080c3fa5045b26176f6778c308c7c773da5056a60c31e225a34f29e308d070`
  - `x86`: `4f91bec14ab59711c71787659b82ab749f94f054961384cf327976eac5dfce43`

Copyright © 2017–2025 WireGuard LLC. All Rights Reserved.

The published upstream AAR also contains `libwg.so` and `libwg-quick.so`, built from the [`wireguard-tools`](https://git.zx2c4.com/wireguard-tools/) submodule at revision `e2ecaaa` under GPL-2.0. Zagros neither invokes nor vendors those binaries. [`tool/prepare_wireguard_android.py`](tool/prepare_wireguard_android.py) verifies the exact upstream AAR, removes only those two native members, emits the byte-for-byte reproducible vendored derivative, verifies its digest, and asserts that `libwg-go.so` is the only retained native-library name. The unmodified upstream AAR must not be committed or distributed from this repository. A GPL-2.0 reference copy remains at [`third_party/wireguard-tools/COPYING-GPL-2.0`](third_party/wireguard-tools/COPYING-GPL-2.0).

The retained Go backend's pinned module is `golang.zx2c4.com/wireguard` revision `f333402bd9cb` (`v0.0.0-20250521234502-f333402bd9cb`) under MIT; its license is copied at [`third_party/wireguard-go/LICENSE-MIT`](third_party/wireguard-go/LICENSE-MIT). The upstream Go module/checksum set is locked in [`third_party/wireguard-go/module-lock.json`](third_party/wireguard-go/module-lock.json). All eight module zips were downloaded from the Go proxy, verified against those exact `h1` sums, and recorded with source ZIP SHA-256/size plus hash-captured module-level license, PATENTS, and notice members in [`third_party/wireguard-go/source-license-lock.json`](third_party/wireguard-go/source-license-lock.json). The six exact tagged Android build-glue inputs (`Makefile`, JNI/CGo sources, `go.mod`, `go.sum`, and Go-runtime patch) are separately URL/hash captured in [`third_party/wireguard-go/android-build-source/lock.json`](third_party/wireguard-go/android-build-source/lock.json). The full parent-tag snapshot from the official GitHub mirror is vendored at SHA-256 `0d12c37fabf73fe88983e779c077aaad55ff62ea5749bad89ec1a27c60d7ade3`; the mirror's verified tag object `3831cab2da844319291459308a6e535d36dde4b3` resolves to the same pinned commit. The upstream Makefile pins Go `1.24.3` for the Linux/Android build at SHA-256 `3333f6ea53afa971e9078895eaa4ac7204a8c6b5c68c10e6bc9a33e8e391bdd8`; all 33 license/PATENTS members in that exact toolchain tarball are captured and hash-locked under [`third_party/wireguard-go/go-toolchain-licenses/`](third_party/wireguard-go/go-toolchain-licenses/). Every retained ABI ELF identifies Android NDK `27.0.12077973` (API 24, Clang 18.0.1); the exact 663,957,918-byte Linux archive is locked at SHA-256 `2f17eb8bcbfdc40201c0b36e9a70826fcd2524ab7a2a235e2c71186c302da1dc` and its metadata/license/notice members are captured under [`third_party/wireguard-go/android-ndk-r27-notices/`](third_party/wireguard-go/android-ndk-r27-notices/). The four-ABI Android-tagged report contains 135 reachable packages and only four external modules (`x/crypto`, `x/net`, `x/sys`, and `wireguard`), all at their locked versions and `h1` sums with captured notices. Using the exact source snapshot, Go 1.24.3 runtime patch, NDK, generated CMake target flags, and NDK strip step, all four retained ELFs were rebuilt byte-for-byte at their packaged SHA-256 values. The reports are [`android-reachable-packages.json`](third_party/wireguard-go/android-reachable-packages.json) and [`native-reproduction.json`](third_party/wireguard-go/native-reproduction.json).

`tool/inspect_android_artifact.py` compares packaged WireGuard members with the locked per-ABI digest manifest and has no GPL bypass. Android packaging separately excludes the two unused upstream names as defense in depth, and CI runs the fail-closed inspector. The derivative was reproduced locally from the pinned upstream bytes and passed inspection; the configured final packaging has **not** been proven in a real Gradle APK/AAB on this host.

## Open SSTP Client engine (embedded SSTP/PPP core)

- Component: `kittoku/Open-SSTP-Client` core (branch `main`)
- Upstream: <https://github.com/kittoku/Open-SSTP-Client>
- Pinned commit: `5f97511c3afff7dcf76b763882e0e29207ad1a36` (2026-08-14)
- Upstream tarball SHA-256: `5fc26380fa5c396327d2dc2a1c126e3ae3b1d8d0e90bb8d76ddabd7fc4b04a88`
- License: MIT License ([`third_party/sstp-client/LICENSE`](third_party/sstp-client/LICENSE)), Copyright (c) 2019 KOBAYASHI Ittoku
- Architecture: In-process Kotlin engine implementing MS-SSTP plus a userspace PPP stack (LCP, MS-CHAPv2, IPCP) — no kernel PPP device, no pppd. Driven by `ai/zagros/tunnel/ZagrosSstpEngine.kt`; every vendored/adapted source file is digest-pinned in [`third_party/sstp-client/lock.json`](third_party/sstp-client/lock.json) and the Gradle build fails on mismatch.
- Zagros adaptations (documented in the lock file): host-interface decoupling, SHA-256 server-certificate pinning, byte counters, removal of upstream settings UI.

## Android adapter runtime graph

The standalone Android adapter's `releaseRuntimeClasspath` and `coreLibraryDesugaring` configurations were resolved with Gradle 9.3.1 and AGP 9.1.0. The exact report is captured in [`third_party/android-runtime-dependencies.txt`](third_party/android-runtime-dependencies.txt) and [`third_party/android-desugaring-dependencies.txt`](third_party/android-desugaring-dependencies.txt). The 22 selected artifact/metadata files are remotely checksum verified in [`third_party/android-runtime/lock.json`](third_party/android-runtime/lock.json), and the 13-component relationship graph is represented in [`third_party/android-runtime/android-runtime-sbom.cdx.json`](third_party/android-runtime/android-runtime-sbom.cdx.json). Gradle dependency verification additionally locks the standalone build/plugin supply chain. The standalone Android adapter also passed `assembleDebug` (including Kotlin compilation) against the pinned Flutter embedding and GoBackend derivative; current-source hashes, output identity, and the successful log are retained in [`third_party/android-standalone-build-evidence.json`](third_party/android-standalone-build-evidence.json). This is not a complete Flutter APK/AAB build.

The resolved runtime includes AndroidX Annotation/Collection, Kotlin stdlib 2.2.10, JetBrains annotations 23.0.0, kotlinx-coroutines 1.10.2, and the reviewed local WireGuard derivative. Those components' Apache-2.0 notices are captured. Core-library desugaring uses `com.android.tools:desugar_jdk_libs:2.1.5` under GPL-2.0-only with the Classpath Exception and its configuration artifact under BSD-3-Clause. Their license texts, `ADDITIONAL_LICENSE_INFO`, and `ASSEMBLY_EXCEPTION` are captured. A source snapshot at the unsigned version-bump commit `73170c345e6a762fc6a1f0301bb15218850023ef`, whose `VERSION_JDK11.txt` says `2.1.5`, is vendored as a **candidate** corresponding source; reproducible artifact-to-source mapping has not been demonstrated, so source-offer acceptance remains blocked.

**Distribution block:** inspect every final APK/AAB. Either excluded GPL WireGuard-tools member in any package is a release failure. Go reachability and native-byte reproduction now pass, but the final Flutter app graph/package SBOM, desugar corresponding-source proof, signing, trademark/legal approval, and device routed-traffic evidence remain required.

## Platform-provided transports

The Apple IKEv2 adapter calls `NetworkExtension`; the Windows IKEv2 adapter calls Windows RAS; and the Linux adapter calls the target system's NetworkManager and `wg`. These system components are not copied into this source repository. Their platform/distribution terms still apply.

Apple and Windows create an OS-managed structured VPN/profile entry while connecting and remove the owned entry during teardown. They are disabled in White-label mode in both Dart capability policy and the native hosts until explicit persistence approval. Linux submits a `persist=volatile`, client-lifetime NetworkManager profile over a private D-Bus connection. Security/legal approval and device residue evidence for these mechanisms remain distribution gates.

## Trademarks and affiliation

“WireGuard” and the “WireGuard” logo are registered trademarks of Jason A. Donenfeld. Zagros is not created, approved, sponsored, or endorsed by WireGuard, Jason A. Donenfeld, ZX2C4, or Edge Security LLC. No WireGuard logo is included. Commercial product text and protocol naming require final review against <https://www.wireguard.com/trademark-policy/> and permission where required.

Apple, macOS, and iOS are trademarks of Apple Inc. Microsoft and Windows are trademarks of the Microsoft group of companies. Linux is the registered trademark of Linus Torvalds. Such names identify target platforms only and do not imply endorsement.

## Generator

Pigeon 28.0.0 generates the platform channel bindings. Zagros applies deterministic diagnostic redaction and best-effort mutable-buffer clearing with `tool/harden_pigeon.py`; `tool/verify_pigeon_generated.sh` is the regeneration drift gate. Generated-code notices from the upstream Flutter packages remain subject to the Flutter/Pigeon license inventory produced by the final build.
