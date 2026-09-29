# Zagros VPN

One Flutter source tree for the Official and White-label Zagros VPN clients.

> **Current status — Phase 10 native adapters are implemented and partially host-compiled, not distribution-approved.** The shared composition root now uses one runtime-only `NativeTunnelAdapter`. Android WireGuard, Apple IKEv2, Windows RAS IKEv2, and Linux NetworkManager WireGuard host source exists with fail-closed lifecycle/accounting rules. The Android adapter assembled successfully in its standalone AGP harness against the pinned GoBackend derivative and Flutter embedding; strict standalone Linux parser and NetworkManager settings-construction tests also passed. The complete Flutter application, Apple/Windows/Linux Flutter plugins, signed packages, authenticated tunnels, and routed traffic have not yet passed their required gates.

## Repository shape

- `apps/zagros_vpn/` — shared Flutter UI and orchestration for Android, iOS, Windows, macOS, and Linux.
- `packages/tunnel_interface/` — typed runtime-only boundary and platform-native adapter implementations.
- `tool/verify.sh` — deterministic generation, format, analysis, source-boundary, and test checks.
- `doc/` — architecture, security, build, and lifecycle decisions.

The pure-Dart `Zagros-VPN-SDK` is an independent sibling repository and owns domain models, Official subscription transport/identity/protected catalog/CRUD, parsing, API/authentication, cryptography, config acquisition, lease renewal, and authoritative product capabilities. A development checkout must therefore use this layout:

```text
parent/
├── Zagros-VPN/
└── Zagros-VPN-SDK/
```

## Products from one source

| Capability | Official | White-label |
|---|---:|---:|
| Application login required | No | Yes |
| Subscription import | Yes | Denied |
| Manual config | Yes | Denied |
| Raw config display/export/clipboard/persistence | Allowed by policy | Denied |

These semantics come from SDK `ClientPolicy` injected at the app composition root. There are no flavor-specific screen, model, state-machine, or adapter forks.

## Non-secret build configuration

Official is the fail-safe default:

```sh
flutter run --dart-define=ZAGROS_PRODUCT_MODE=official
```

White-label builds require an HTTPS Application API URL and a complete **public** Application identity:

```sh
flutter run \
  --dart-define=ZAGROS_PRODUCT_MODE=white-label \
  --dart-define=ZAGROS_APP_NAME='Partner VPN' \
  --dart-define=ZAGROS_DEFAULT_LOCALE=fa \
  --dart-define=ZAGROS_APPLICATION_API_BASE_URL='https://panel.example/api/application/v1' \
  --dart-define=ZAGROS_APPLICATION_ID='<public-application-id>' \
  --dart-define=ZAGROS_APPLICATION_NAME='Partner' \
  --dart-define=ZAGROS_APPLICATION_STATUS=active \
  --dart-define=ZAGROS_CONFIG_KEY_ID='<public-key-id>' \
  --dart-define=ZAGROS_CONFIG_PUBLIC_KEY='<32-byte-base64url-public-key>' \
  --dart-define=ZAGROS_SIGNING_KEY_ID='<public-key-id>' \
  --dart-define=ZAGROS_SIGNING_PUBLIC_KEY='<32-byte-base64url-public-key>'
```

Never pass passwords, activation tickets, access/refresh tokens, private keys, signing credentials, or reseller signing material through `--dart-define`; compile-time values are extractable from a client binary and may appear in build logs.

## Verification

With Flutter 3.47.2 and Dart 3.13.2 installed:

```sh
FLUTTER_BIN=/path/to/flutter/bin/flutter \
DART_BIN=/path/to/flutter/bin/dart \
./tool/verify.sh
```

The script resolves the workspace, generates localization, regenerates every Pigeon target into a temporary tree, applies deterministic redaction, checks drift, compiles the two host-available Linux native tests with strict warnings, formats, runs source guards, analyzes both packages, and executes all unit/widget tests. It does not replace platform/device validation. Platform builds have additional prerequisites and gates in [Building](doc/building.md).

## Security and architecture

- [Architecture and ownership](doc/architecture.md)
- [Official profile library UI](doc/official-library.md)
- [Mandatory connection lifecycle](doc/connection-lifecycle.md)
- [Secure storage and platform packaging](doc/secure-storage.md)
- [Building and platform gates](doc/building.md)
- [Native adapters, capabilities, and validation status](doc/native-adapters.md)
- [Third-party notices and unresolved distribution gates](THIRD_PARTY_NOTICES.md)
- [Security policy and limitations](SECURITY.md)

## License

Copyright © 2026 Zagros contributors & Project Authors. Proprietary and confidential. All rights reserved. See [LICENSE](LICENSE).
