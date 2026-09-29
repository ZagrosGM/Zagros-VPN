# Pigeon and the WireGuard backend are referenced directly. Keep the nested
# VpnService entry point because Android instantiates it from the merged manifest.
-keep class com.wireguard.android.backend.GoBackend$VpnService { *; }
-keep class ai.zagros.tunnel.ZagrosVpnService { *; }
-keep class ai.zagros.tunnel.ZagrosCoreDaemon { *; }
