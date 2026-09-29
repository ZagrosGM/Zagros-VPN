# zagros_vpn application

Shared Flutter UI and orchestration package for both Zagros Official and White-label products. It is not a standalone domain implementation; use the repository-root documentation for configuration, architecture, security, verification, and platform build gates.

The Phase 10 composition root injects the same `NativeTunnelAdapter` for both products and relies on runtime native capabilities. Platform-native source exists but has not been built or traffic-tested on shipping hosts/devices; no connectivity or distribution claim is made.
