# Building and platform gates

## Pinned foundation toolchain

The approved Phase 8 foundation and Phase 9 Official UI were verified with Flutter 3.47.2 and its bundled Dart 3.13.2. Phase 10 source generation used Dart 3.13.2 and Pigeon 28.0.0. Phase 13 provisioned the same Flutter 3.47.2 plus the Linux native toolchain (g++, clang, CMake, Ninja, GTK 3, libsecret, GLib/GIO) on the build host outside the workspace. Phase 15 provisioned the Android toolchain the same way (OpenJDK 21, SDK command-line tools 19.0, platform-36 plus 37.0, build-tools 36.0.0, NDK 28.2.13676358, platform-tools; CMake side-installs on first build). The workspace requires Flutter 3.47+ and Dart 3.13+.

```sh
flutter --version
flutter pub get
FLUTTER_BIN="$(command -v flutter)" \
DART_BIN="$(command -v dart)" \
./tool/verify.sh
```

The SDK must be checked out as the sibling `../Zagros-VPN-SDK` because the workspace uses a local path dependency during pre-release development.

## Build configuration

Only non-secret product metadata may be supplied through `--dart-define`; see the root README. White-label validation rejects missing identity fields, malformed 32-byte public keys, unsafe identifiers, unsupported locales, and Application API URLs that are not HTTPS or contain user info, query, or fragment components.

## White-label build entry (build-pipeline contract v1)

`tool/white_label_build.py` is the worker-facing entry point the panel
build pipeline invokes. It takes a partner `build_config.json`, validates
it with the same rules the app enforces at runtime (see
`apps/zagros_vpn/lib/src/config/product_configuration.dart`), bakes the
branding as `--dart-define`s, runs the real Flutter release build, and
stages finished files plus `white-label-build-receipt.json` into `--out`:

```sh
python3 tool/white_label_build.py --config build_config.json \
  --platform linux --arch x64 --out /path/to/empty-out-dir
```

`--out` must already exist and be empty; values are never echoed (only
define names). Exit 2 = config/usage error, exit 1 = build failure.
`flutter` must be on `PATH` or pointed to by `FLUTTER_BIN`. Platform/arch
slugs must match the panel/Builder matrix (`android` × 3 ABIs, `ios` arm64,
`linux`/`windows` ×64/arm64, `macos` arm64/x64). `--artifact apk|aab`
(default `apk`) selects the Android artifact kind (`aab` is android-only):
an AAB job always builds the full multi-ABI bundle (no `--target-platform`
flag), staged as `{slug}-{arch}.aab` next to the unchanged receipt shape.

Android builds additionally require `android_application_id` and
`android_application_label`: the script stages them in a generated
`android/zagros-brand.properties` that Gradle reads (deleted
afterwards), so each partner's APK/AAB carries its own package and
launcher label while a plain `flutter build` keeps the defaults.
Release signing is injected the same way via `android/key.properties`
(never committed); without it the Flutter tool signs with debug keys
and a warning.

The script requires the `Zagros-VPN-SDK` checkout as a sibling of the
client checkout (the v2 worker clones the pinned SDK source there) and
refuses with an actionable message when it is absent — a lone app
checkout can never reach `pub get`. Both pubspec path deps must keep
resolving to exactly that sibling (pinned by unit test).

Tests: `python3 -m pytest tool/tests/test_white_label_build.py` (fast,
fixture-based) and the opt-in real build
`ZAGROS_LIVE_BUILD=1 python3 -m pytest tool/tests/` (minutes, needs the
Flutter SDK and ≥4 GB RAM for cold AOT compiles).

## Native prerequisites and unverified gates

| Target | Required build environment | Current native-build status |
|---|---|---|
| Android | Android SDK; Java 17+ (OpenJDK 21 verified) for checksum-pinned Gradle 9.4.1; signing setup | Phase 15: first real white-label APK (`android/arm64-v8a` release with R8, branding verified inside `libapp.so`) built via the contract script and staged with receipt — throwaway test signing only. production signing, installation, and device tunnel remain unrun; standalone adapter `assembleDebug` passed earlier. Phase 17: `--artifact aab` wired end-to-end (panel per-target `artifact` + `?artifact=` worker API + Builder passthrough); 58.5 MB multi-ABI bundle verified live (`jar verified`, test-key cert, brand markers in `base/lib/*/libapp.so`) |
| iOS | macOS, Xcode, CocoaPods, Apple signing/profile | Not available on Linux; not built |
| macOS | macOS, Xcode, Apple signing/profile | Not available on Linux; not built |
| Windows | Windows, Visual Studio C++ desktop tools, ATL, signing | Not available on Linux; not built |
| Linux | clang++, CMake, Ninja, GTK 3 dev files, libsecret dev/runtime, GLib/GIO, NetworkManager, `wg`, keyring | Phase 13: full `flutter build linux --release` with white-label `--dart-define`s passes and stages a working bundle (branding verified inside the compiled AOT library); standalone C++ tests still pass. Running the tunnel (NetworkManager/`wg`/keyring) and launching the GUI remain unrun |

The Android release manifest declares Internet access for subscription retrieval while retaining `usesCleartextTraffic=false`. Sandboxed macOS builds declare network-client, keychain, and Downloads read/write access; Downloads access is used only after the user confirms an Official raw export. White-label policy and composition still make raw export unreachable.

The repository workflow now has debug compile jobs for Android, Linux, Windows, macOS, and the iOS simulator on their matching GitHub-hosted operating systems. They are configuration only: this unborn/unpushed working tree has not run them, and simulator compilation cannot replace signed physical-device VPN evidence. The Android job consumes the vendored digest-checked AAR rather than resolving an unverified engine binary at build time.

Static source configuration is not a substitute for a native build. No target may be marked passing until its build command and platform tests actually run on the required worker.

## Release gates

Before distribution: run clean release builds, inspect effective entitlements/manifests, test secure storage on target devices, produce a complete SBOM and transitive dependency digest/license inventory, satisfy the WireGuard Android GPL/source and trademark decisions recorded in `THIRD_PARTY_NOTICES.md`, scan dependencies/artifacts, inspect final packages for profile/config residue, verify deterministic public configuration, sign/notarize as applicable, and perform authenticated config-delivery → tunnel → routed-traffic → accounting → teardown tests. None of those Phase 10 release gates is currently claimed.
