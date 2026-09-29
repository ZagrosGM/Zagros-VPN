# Client architecture and ownership

## Dependency direction

```text
Flutter UI/orchestration ──> Zagros-VPN-SDK
          │                         │
          └──> tunnel_interface <───┘
                         │
        Android / Apple / Windows / Linux adapters
```

`apps/zagros_vpn` owns presentation, localization, composition, and orchestration. `Zagros-VPN-SDK` owns models, parsers, API/authentication, cryptography, config acquisition, renewal, and `ClientPolicy`. `tunnel_interface` owns typed capabilities, lifecycle snapshots, bounded runtime connection encoding, hardened Pigeon IPC, and platform-native transport adapters.

The Flutter application must not reimplement SDK domain behavior. Native platform packages must not define product policy. Adapters translate an SDK `NormalizedConfig` into a native engine's runtime form and must not display, log, return, or create application files containing secret fields. Required OS-managed transient profile state is documented as an unresolved policy/distribution gate rather than hidden.

## One source, policy-composed products

`ProductConfiguration` validates non-secret compile-time metadata and selects exactly one SDK policy at the composition root. Shared navigation is derived from that policy. Official and White-label do not have separate application trees, screens, state machines, models, or tunnel adapters.

White-label requires Application login and denies:

- subscription import;
- manual config entry;
- raw-config display;
- raw-config export;
- raw-config clipboard access; and
- raw-config persistence.

Source guards and tests enforce the current boundary. Future Official features that add a sink such as clipboard export must prove an SDK capability check on every path and preserve denial tests for White-label.

## Runtime config flow

```text
SDK list → caller selects descriptor → SDK immediate consume/decrypt
    → in-memory NormalizedConfig → TunnelConnectRequest
    → Pigeon runtime payload → privileged native adapter
```

There must be no second list request between selection and consume. White-label plaintext must not enter widget state or any persistence/exfiltration sink. Buffers should be kept for the shortest practical time and disposed or overwritten where the owning API supports it. Garbage-collected runtimes cannot promise deterministic erasure.

## Tunnel truthfulness

The interface exposes `disconnected`, `preparing`, `connecting`, `connected`, `disconnecting`, and `failed`. A platform adapter may emit `connected` only after authoritative OS/engine confirmation. Capability discovery must report unsupported protocols and reasons honestly. No no-op or timer-based implementation may be delivered as a tunnel.

Phase 10 composes one `NativeTunnelAdapter` for both products and contains native Android, Apple, Windows, and Linux source. Runtime capabilities expose only the transport engines actually packaged or provided by the OS. Shipping builds, licensing approval, signing, authenticated establishment, routed traffic, accounting, and teardown remain unpassed host/device gates; source presence is not acceptance.

## Phase boundaries

- Phase 8: shared shell, configuration/policy composition, secure-store bridge, localization, tunnel interface.
- Phase 9: Official subscription/manual CRUD and connection UX, still delegating domain behavior to the SDK.
- Phase 10: real native adapters and real routed-traffic tests.
- Phase 11: complete White-label login/activation and no-plaintext-persistence acceptance.

PPTP/L2TP must not be represented as fully cross-platform. OpenVPN static-auth remains omitted from Application-mode listing because it cannot receive a device-scoped lease.
