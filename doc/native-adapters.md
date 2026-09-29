# Native tunnel adapters (Phase 10 work in progress)

## Security boundary

`NativeTunnelAdapter` is the sole Flutter orchestration facade for both Official and White-label products. It encodes an SDK `NormalizedConfig` into a bounded mutable payload, calls the generated asynchronous Pigeon API, and clears that payload in `finally`. Native hosts validate protocol, identifiers, size, and syntax again. Unknown generated exceptions are serialized as a fixed `native_failure`; request diagnostics are redacted.

This is best-effort handling, not deterministic erasure. Dart, platform codecs, JSON parsers, OS APIs, and garbage-collected runtimes may copy data. A device owner who controls the OS or process may inspect runtime material.

No adapter may infer connected status from a process, listener, timer, or successful API invocation alone. `connected` requires the platform transport's authoritative established state; WireGuard additionally requires a nonzero handshake generated after the current connection attempt.

## Runtime support matrix

| Platform | Advertised now by native source | Authoritative establishment signal | Traffic accounting | Explicitly unavailable |
|---|---|---|---|---|
| Android | WireGuard, only if the pinned Go backend loads | Backend `UP` plus a current-attempt peer handshake | WireGuard backend RX/TX | OpenVPN, Xray, sing-box, SoftEther, SSH, PPTP, L2TP, IKEv2 |
| iOS | Built-in IKEv2 | `NEVPNStatus.connected` | Not claimed | WireGuard until WireGuardKit + extension exists; OpenVPN, Xray, sing-box, SoftEther, SSH, PPTP, embedded L2TP |
| macOS | Built-in IKEv2 | `NEVPNStatus.connected` | Not claimed | Same packaged-engine exclusions as iOS; PPTP is not supported |
| Windows | Built-in RAS IKEv2 | `RASCS_Connected` delivered/queryable through RAS | Monotonic accumulation of RAS byte counters | WireGuard service, OpenVPN, Xray, sing-box, SoftEther, SSH, PPTP, L2TP |
| Linux | NetworkManager WireGuard, only when NetworkManager owns its D-Bus name and `wg` is installed | Active connection state plus a current-attempt `wg latest-handshakes` timestamp | `wg show … transfer` | OpenVPN, Xray, sing-box, SoftEther, SSH, PPTP, L2TP, IKEv2 |

“Unavailable” is intentional. A protocol is not advertised merely because an SDK parser recognizes it. Runtime capability discovery is the UI's authority. The table describes native source capability; Apple and Windows IKEv2 are additionally filtered and natively rejected in White-label mode until their structured OS-profile persistence receives explicit approval.

## Platform behavior

### Android

The plugin uses `com.wireguard.android:tunnel:1.0.20260102` and `GoBackend`. It requests Android VPN consent, resolves all endpoints before entering an upstream diagnostic path that could print a failed hostname, parses configuration in memory, and clears mutable request bytes. Backend `UP` is reported as `connecting` until handshake evidence exists. A 20-second missing-handshake limit tears the backend down and reports `handshake_timeout`. Backend state and statistics remain the authority.

The exact upstream AAR is hash-verified and reproducibly stripped before vendoring, so the consumed derivative retains only `libwg-go.so`; its locked SHA-256 is rechecked by the Android build. The unmodified AAR's unused GPL `libwg.so` and `libwg-quick.so` are neither vendored nor consumed. App packaging excludes those names again as defense in depth, and the package inspector has no GPL bypass. The derivative has been reproduced and inspected locally, but no real final Gradle APK/AAB has been built here. Retained source, reproducibility, transitive legal, and packaging gates remain documented in `THIRD_PARTY_NOTICES.md` and `third_party/native-engine-lock.json`.

### Apple

The shared Swift plugin uses `NEVPNManager` and IKEv2. The shared encoder and both Apple/Windows hosts reject custom IKE ports because these OS transports negotiate standard IKEv2/NAT-T rather than honoring an arbitrary endpoint port. Password/shared-secret values are placed in this-device-only Keychain items and referenced by the VPN profile. Startup advertises no protocol until it has removed an owned stale profile and verified deletion of all adapter-owned Keychain items; an unrecognized application VPN profile is an ownership conflict and is never overwritten. Explicit disconnect, timeout, failure, and externally observed disconnect all require bounded stop/profile/secret cleanup. A cleanup failure remains a failed state with owned identity so teardown can be retried. Controlled operations suppress intermediate `NEVPNStatus` notifications; otherwise those notifications drive lifecycle events. Traffic counters are deliberately not claimed.

`NEVPNManager` requires a structured preference profile while active. That is OS-managed persistence—not a plaintext raw-config file—but it has not received the explicit security/legal approval required by White-label runtime-only policy. Production composition therefore removes Apple IKEv2 from White-label capabilities, and native Swift independently rejects a White-label request before profile mutation. Official-mode acceptance still requires policy review. A crash may leave the transient preference until the next fail-closed startup ownership cleanup. Personal VPN entitlement, provisioning, signing, and physical-device validation remain mandatory.

### Windows

The plugin creates one fixed, structurally ownership-checked RAS phone-book entry, supplies EAP username/password directly to `RasDialW`, and never calls a credential-persistence API. Capability stays false while startup finds, hangs up, and deletes a stale owned connection/profile; a foreign or unreadable same-name entry is not touched. RAS is asynchronous: `RasDialW` receives the required `0xFFFFFFFF` window-notifier type and a message-only window receives the registered `RASDIALEVENT`; timers bound connection and teardown waits without sleeping on Flutter's platform thread. Profile deletion failure is a failed residue state rather than a false disconnected result. External disconnect is monitored, and mutable credential structures are securely cleared.

The phone-book entry contains the server while active and may remain after abrupt process termination until the next successful startup cleanup. Because this has not received explicit runtime-only policy approval, production composition removes Windows IKEv2 from White-label capabilities and native C++ independently rejects White-label requests before profile mutation. Official-mode residue tests and policy approval are still required before distribution.

### Linux

The plugin creates a private system-bus connection, submits complete NetworkManager settings using `AddAndActivateConnection2`, and sets `persist=volatile` plus `bind-activation=dbus-client`. Keeping that private D-Bus connection alive is part of tunnel ownership; closing it is a fail-safe deactivation boundary. Disconnect explicitly deactivates, deletes the settings object, and closes the bus.

A registration-time worker performs the NetworkManager/`wg` capability probe without blocking GTK; only absolute `/usr/bin/wg` or `/bin/wg` paths are trusted. It recognizes one fixed adapter-owned profile only when its ID, stable UUID marker, type, and interface all match, refuses to touch it while active, deletes inactive startup residue, and withholds capability if ownership inspection or cleanup fails. A background monitor checks both NetworkManager active state and `wg` handshake/transfer evidence so the GTK platform thread does not perform those blocking calls. Three status failures or a 30-second handshake timeout trigger fail-closed teardown. NetworkManager settings give tunnel DNS a negative priority, and the parser rejects scripts, unknown directives, malformed keys, oversized payloads, duplicate directives, and excessive peers/values. Parser-owned mutable key material is cleared immediately after the immutable D-Bus settings value is built.

## Shared lifecycle

1. Query native capabilities.
2. Reject protocols absent from the native capability set and show the bounded unavailable reason.
3. Encode in runtime memory only.
4. Submit one asynchronous `connect` request.
5. Accept only monotonic status sequences and counters for the expected connection ID.
6. Treat `preparing` and `connecting` as non-established.
7. Enter `connected` only from authoritative native evidence.
8. On failure, timeout, explicit user disconnect, detached application lifecycle, or an awaited desktop exit request, request native teardown and clear mutable payloads. Native/OS startup ownership cleanup remains the crash fallback.
9. Treat device/OS inspection of runtime material as possible; never promise client-side secrecy against the device owner.

Application auth/config retrieval remains governed by the SDK lifecycle: immediate `list → select → consume`, bounded transparent refresh after an expired envelope/grant, and proactive renewal of 60–300-second leases (default 120 seconds).

## Validation status — 2026-09-08

Actually run on the current Linux workspace:

- Strict C++17 WireGuard parser test (`-Wall -Wextra -Werror -pedantic`): passed.
- Strict C++17 NetworkManager settings-construction test with GLib/GIO 2.84.4: passed.
- Full all-language Pigeon regeneration into a temporary tree, deterministic hardening, Dart formatting, and tracked-output comparison with Dart 3.13.2/Pigeon 28.0.0: passed.
- Remote download/hash verification and byte-for-byte reproduction of the vendored GoBackend-only AAR derivative: passed. Its per-ABI manifest inspection passed with only `libwg-go.so`; a synthetic forbidden `libwg.so` member was denied without a bypass. This is not final Gradle APK/AAB evidence.
- All eight Go module zips matched their locked `h1` sums; tagged Android build glue, parent-tag source snapshot, Go 1.24.3 notices, and Android NDK 27.0.12077973 notices were remotely captured and locally hash verified.
- All four retained `libwg-go.so` ELFs matched the locked Go/NDK/Clang/API identity and depended only on `liblog.so`, `libdl.so`, and `libc.so`.
- Four-ABI Android-tagged `go list -deps` reachability passed: 135 packages were reachable and the only external modules were the four expected locked modules, all with captured notices.
- Native reproduction passed for every ABI: after the exact upstream source, patched Go 1.24.3, Android NDK 27.0.12077973 CMake target flags, and NDK strip step, every rebuilt `libwg-go.so` was byte-for-byte identical to its packaged member.
- The standalone Android adapter `releaseRuntimeClasspath` and `coreLibraryDesugaring` graphs resolved successfully under Gradle 9.3.1/AGP 9.1.0. Their selected artifacts, licenses, dependency reports, and 13-component CycloneDX SBOM are captured; the SBOM passed the official CycloneDX 1.6 JSON schema. This is not the final Flutter application graph.
- AGP 9.1 rejected the obsolete external Kotlin Android plugin during the real resolution run. The app/plugin builds now use AGP built-in Kotlin; standalone plugin version/repository resolution and the Gradle Kotlin DSL digest import were corrected.
- Android `assembleDebug` passed in the standalone plugin harness with Java 17.0.20.1, Gradle 9.3.1, AGP 9.1.0, Android platform/build tools 36, the pinned Flutter engine embedding, and the digest-checked GoBackend derivative; this includes successful Kotlin compilation and produced a 77,734-byte debug plugin AAR. The current-source/input hashes, output identity, and successful log are retained in `third_party/android-standalone-build-evidence.json`. This is not a complete Flutter application build.

Not available and therefore **not passed**:

- Flutter analysis/tests on any Dart toolchain other than 3.13.2 (only Dart 3.13.2 is installed on this host, so the 3.4.4 SDK gate was not re-run).
- Complete Flutter Android compile, emulator/device VPN, routed traffic, final packaging, and signing. The standalone Kotlin adapter compile passed, but no complete Flutter Android build or device run has occurred.
- iOS/macOS compile, signing, entitlement, simulator/device, and routed traffic (no Xcode host).
- Windows compile, RAS lifecycle, residue, accounting, and routed traffic (no Windows host).
- Linux Flutter plugin compile and a privileged NetworkManager tunnel (Flutter Linux/GTK toolchain and an isolated VPN endpoint are unavailable).
- Any authenticated end-to-end config delivery → tunnel → routed traffic → accounting → teardown acceptance run.

No complete shipping-target build or authenticated routed-traffic run has passed. The standalone compile/test evidence above is narrower and makes no distribution, release, security, or compatibility claim.
