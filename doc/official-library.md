# Official profile library UI

The Library destination is part of the shared Flutter shell but is reachable only when injected SDK policy permits subscription import or manual configuration. White-label navigation omits it, the composition root does not create an Official repository or raw-action service, and the SDK repository/store independently deny White-label calls.

Flutter owns widgets, transient loading/error/busy state, localized user intent, and `TunnelAdapter` orchestration. It does not parse subscriptions/configurations, validate subscription transport, encode persistence, create Official device identity, or define capability rules. Those operations are delegated to the sibling `Zagros-VPN-SDK`.

## Workflows

- Add, edit, refresh, and delete an HTTPS subscription.
- Add, edit, and delete a supported manual configuration.
- List SDK-normalized configurations and show protocol warnings.
- Show subscription host, quota usage, expiry, update interval, and last refresh when available.
- Display raw configuration only under `rawConfigDisplay` policy.
- Copy only under `rawConfigClipboard` policy.
- Export only under `rawConfigExport` policy and after warning that the result is a plaintext credential file.
- Select a normalized configuration for `TunnelAdapter`.

Raw copy/export platform actions repeat the SDK policy check immediately before invoking clipboard/file services. Persistent catalog bytes go only to the existing OS-secure storage bridge; there is no Flutter preferences, database, or plaintext catalog fallback.

## Phase 10 tunnel state

The composition root injects one `NativeTunnelAdapter` for Official and White-label modes. The Library queries runtime capabilities, passes only the SDK-normalized model to the adapter, observes native lifecycle events, and displays connecting/connected/failed state. It reports immediate success only when the adapter returns `TunnelState.connected`; `preparing`/`connecting` remain a request-in-progress result. Replacing a connection first awaits teardown of the previous native tunnel.

A non-null adapter does not imply a supported protocol. Native capability sets and bounded unavailable reasons are authoritative. If discovery fails or the selected protocol is absent, connection controls fail closed. No platform or product-specific parser/state machine is present in the UI.

## Limitations

PPTP is shown with a legacy/insecure warning and is not represented as fully cross-platform. L2TP is shown with an operating-system-dependent warning, including modern iOS/Android limitations. A device owner controlling the OS or runtime may extract in-memory or explicitly exported material; the client does not claim otherwise.
