# Security policy

## Current support state

The repository is pre-release client-foundation source. It has no implemented native tunnel adapter and makes no connectivity claim. Security acceptance for platform tunnels and White-label authenticated config delivery remains gated by later phases and real-device testing.

## Reporting a vulnerability

When the public repository is available, use its private GitHub Security Advisory channel. Do not place credentials, activation tickets, tokens, private keys, raw VPN configurations, personal data, or exploit details in a public issue. If no private channel is available, request one without including sensitive details.

## Core invariants

- One shared client source; SDK policy is authoritative for product capabilities.
- White-label denies subscription/manual import and raw-config display, export, clipboard, and persistence.
- White-label runtime config may exist only in memory for immediate handoff to the privileged tunnel adapter.
- Application access requires server-validated application/device cryptographic identity in addition to user credentials. Credentials alone do not authorize config access.
- OS secure storage failures are terminal; there is no plaintext fallback.
- Logs, analytics, diagnostics, exceptions, crash reports, screenshots, preferences, databases, caches, and temporary files must not contain White-label raw config.
- A native adapter must not report `connected` until the OS or engine confirms tunnel establishment. Process or listener existence is insufficient.
- Server/node device, IP, traffic, expiry, and status enforcement is authoritative and must not be bypassed by the client.

## Threat-model limits

OS-backed secure storage reduces accidental disclosure and protects data at rest under the platform's guarantees. It does not make secrets impossible to extract. A device owner or attacker controlling the OS, runtime, debugger, accessibility stack, process memory, or privileged account may recover runtime material. Rooted/jailbroken devices and compromised build/signing systems are outside a guarantee of confidentiality.

Compile-time configuration is public metadata. Never embed universal static secrets, passwords, activation tickets, private keys, access/refresh tokens, signing keys, or shared per-product decryption secrets in the app.

## Dependency and distribution gate

Dependencies are locked for reproducibility, but every release still requires vulnerability review, license/notice generation, platform signing review, and real platform builds. Protocol engines are not vendored or distributed in this phase; each engine requires its own pinned-version license and store-policy decision before integration.
