# White-label account (Application login, configs, usage, connect)

The Application account destination is the only authenticated surface of a
White-label build. It replaces the former static placeholder: enrollment,
username/password login, server-provided config list, usage, native
connect/disconnect, and logout are all real, SDK-backed, and widget-tested.

## Composition

`main.dart` builds `WhiteLabelService` only when SDK policy allows
`ClientCapability.applicationLogin`, mirroring the Official guards:

- transport: `HttpApiTransport` over the build-time HTTPS application API
  origin (loopback HTTP is accepted only for development servers);
- device identity: `DeviceIdentityManager` over OS-protected storage
  (X25519, created once per installation);
- executor/API/auth: the real `SignedRequestExecutor`, `ApplicationApi`,
  and `ApplicationAuthController` — every request is signed with the
  installation device key and the build's public Application identity.

Any composition failure (missing identity, unavailable secure storage)
yields a null service, and the account destination renders an unavailable
state. A login form is never shown when it could not authenticate.

## Flows and states

`WhiteLabelController` (a `ChangeNotifier`) owns one state machine:

1. `initializing` — `start()` restores enrollment and tokens, validates the
   session with one `accessToken()` call, then loads profile, configs, and
   usage. No tokens means `needsLogin` without an error; dead tokens mean
   `needsLogin` with a session-expired message; no enrollment means
   `needsEnrollment`.
2. `needsEnrollment` — username + password + activation code
   (`zgat1.…`, single-use, expiring, issued out-of-band by the panel).
   Success stores the device ID and tokens, then loads account data.
   A wrong password reports invalid credentials; a bad ticket reports an
   invalid ticket; both stay on the form.
3. `needsLogin` — username + password. A server-side unknown device drops
   back to enrollment with a fail-closed message (local enrollment is
   forgotten so a stale device ID can never be reused silently).
4. `ready` — usage card, config list, connect/disconnect, refresh, logout.
   Background read failures keep the phase and show a safe banner, except
   authentication failures (drop to login) and unknown-device failures
   (drop to enrollment).

`reEnroll()` tears down the active connection, forgets local enrollment,
and returns to the enrollment form. `logout()` disconnects first, attempts
the best-effort server logout, then always clears local tokens.

## Connect path and runtime-only handling

`connect(selector)` is ordered deliberately:

1. Reject when another connection is active (`alreadyConnected`).
2. Reject without any network or crypto when no native adapter is
   installed (`adapterUnavailable`).
3. Ask native `capabilities()` and reject unsupported protocols
   (`protocolUnavailable`) before touching acquisition.
4. Only then run `ConfigAcquisition.acquire` with a chooser pinned to the
   tapped selector. Acquisition re-lists and validates the same
   `config_id`, decrypts the envelope inside the SDK, and starts lease
   renewal.
5. Submit the opaque `NormalizedConfig` to the native adapter. `connected`
   is reported only on a native `connected` snapshot; anything else is
   `requestAccepted`, and a `failed` snapshot releases the lease.

Every terminal path stops the server lease (best effort) and wipes runtime
config bytes via `disposeRuntimeConfig()`. An externally observed native
teardown also releases the lease. `dispose()` performs no network: it
detaches renewal and wipes bytes. The account layer never parses, never
opens envelopes, and never reads plaintext bytes; source guards enforce
this (`parseApplicationPayload(`, `ConfigParser(`,
`CryptographicConfigEnvelopeOpener(`, `jsonDecode(` are banned in
`lib/src/account/`).

## What is never shown or stored

- No subscription URL, no raw config, no clipboard, no export, no file.
- Only `displayName`, `protocol`/`engine` labels, and connectable status
  are rendered from server selectors.
- Password and ticket fields are cleared on every submit; only the
  username is kept. Tokens live only in OS-protected storage.
- Errors are fixed localized strings per `WhiteLabelError`; server
  messages are never rendered. Authorization failures never distinguish
  revoked/expired/quota/limited accounts.

## Tests

- `test/white_label_account_test.dart` (10 widget tests) drives the REAL
  SDK stack (real signing, real parsing, real session, real secure-store
  adapters over a memory backend) with a fake `ApiTransport`. It covers
  enroll, ticket/password errors, expired-session recovery, honest
  null-adapter and unsupported-protocol paths (asserting no
  start/consume call reaches the network), logout token clearing,
  re-enroll, null-service unavailability, and Persian RTL.
- `test/white_label_controller_test.dart` (9 unit tests) covers the
  connect wiring with a stub acquisition: connected-only-on-confirmation,
  requestAccepted, failed-snapshot and native-error lease release with
  byte wiping, the already-connected guard, disconnect, external
  teardown, and dispose-without-network.

## Explicit non-goals of this slice

- Device list / device revoke UI (SDK + panel APIs exist; no screen yet).
- Usage history charts (SDK `usageHistory` exists; only the summary card
  is rendered).
- Biometric / OS-credential unlock gating before login submit.
- Platform display-name/version reporting at enrollment (currently null;
  `dart:io` is banned in app sources, so this needs a platform plugin).
- Any claim about real tunnels, traffic, or device runs: connect success
  here means the native adapter confirmed it; routed-traffic acceptance
  still requires device E2E (spec §35).
