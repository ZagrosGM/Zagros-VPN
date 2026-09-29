## 0.2.0 (unreleased)

- Add one shared `NativeTunnelAdapter` and bounded runtime config encoders.
- Add asynchronous Pigeon bindings for Android, Apple, Windows, and Linux with deterministic diagnostic sanitization and drift verification.
- Add unvalidated Android WireGuard, Apple IKEv2, Windows RAS IKEv2, and Linux NetworkManager WireGuard native source.
- Add fail-closed handshake/lifecycle monitoring, teardown, traffic-accounting boundaries, and Linux native parser/settings tests.

## 0.1.0

- Define the typed tunnel lifecycle, capability, request, and failure boundary.
- Add generated Dart Pigeon runtime contract for future native adapters.
- Add redaction and immutability tests.
