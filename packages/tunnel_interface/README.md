# tunnel_interface

Typed, runtime-only boundary between the shared Zagros Flutter orchestrator and privileged platform tunnel adapters.

The package contains lifecycle/capability models, bounded native config encoders, generated asynchronous Pigeon bindings, deterministic diagnostic hardening, and native source for Android WireGuard, Apple IKEv2, Windows RAS IKEv2, and Linux NetworkManager WireGuard. Unsupported protocols remain absent from runtime capability sets with explicit reasons.

A platform adapter must consume config from memory, avoid application persistence/logging of secret fields, attempt mutable-buffer clearing, and report `connected` only after authoritative OS/engine establishment evidence. Garbage-collected runtimes, IPC codecs, OS services, and a device owner controlling the runtime may still copy or inspect material.

The native source is not shipping-platform validated. See [`../../doc/native-adapters.md`](../../doc/native-adapters.md) and [`../../THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md) for exact gates.
