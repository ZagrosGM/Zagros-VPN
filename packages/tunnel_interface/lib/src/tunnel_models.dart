import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

enum TunnelState {
  disconnected,
  preparing,
  connecting,
  connected,
  disconnecting,
  failed,
}

class TunnelCapabilities {
  TunnelCapabilities({
    required this.platform,
    required Set<String> protocols,
    required this.canProtectEntireDevice,
    required this.canReportTraffic,
    Map<String, String> unavailableReasons = const <String, String>{},
  }) : protocols = Set<String>.unmodifiable(protocols),
       unavailableReasons = Map<String, String>.unmodifiable(
         unavailableReasons,
       );

  final String platform;
  final Set<String> protocols;
  final bool canProtectEntireDevice;
  final bool canReportTraffic;
  final Map<String, String> unavailableReasons;

  bool supports(String protocol) => protocols.contains(protocol.toLowerCase());
}

class TunnelFailure implements Exception {
  const TunnelFailure({
    required this.code,
    required this.safeMessage,
    this.terminal = true,
  });

  final String code;
  final String safeMessage;
  final bool terminal;

  @override
  String toString() => 'TunnelFailure(code: $code, terminal: $terminal)';
}

class TunnelSnapshot {
  const TunnelSnapshot({
    required this.state,
    required this.sequence,
    this.connectionId,
    this.protocol,
    this.connectedAt,
    this.uplinkBytes = 0,
    this.downlinkBytes = 0,
    this.failure,
  });

  const TunnelSnapshot.disconnected()
    : this(state: TunnelState.disconnected, sequence: 0);

  final TunnelState state;
  final int sequence;
  final String? connectionId;
  final String? protocol;
  final DateTime? connectedAt;
  final int uplinkBytes;
  final int downlinkBytes;
  final TunnelFailure? failure;

  bool get isActive => switch (state) {
    TunnelState.preparing ||
    TunnelState.connecting ||
    TunnelState.connected ||
    TunnelState.disconnecting => true,
    TunnelState.disconnected || TunnelState.failed => false,
  };

  @override
  String toString() =>
      'TunnelSnapshot(state: $state, sequence: $sequence, config: **redacted**)';
}

class TunnelConnectRequest {
  const TunnelConnectRequest({
    required this.requestId,
    required this.connectionId,
    required this.config,
    required this.productMode,
    this.dnsServers = const <String>[],
    this.fakeDns = false,
    this.perAppMode = 'off',
    this.perAppPackages = const <String>[],
  });

  final String requestId;
  final String connectionId;
  final NormalizedConfig config;
  final ClientProductMode productMode;

  /// App settings DNS preset resolution for the device tun. Empty = defaults.
  final List<String> dnsServers;

  /// Fake DNS (sing-box fakeip): domains answer from a synthetic pool; the
  /// real destination is restored inside the tunnel.
  final bool fakeDns;

  /// Per-app proxy: "off" | "allow" (only listed apps use the VPN) |
  /// "deny" (listed apps bypass the VPN).
  final String perAppMode;

  /// Package names for [perAppMode]. The app itself is always handled
  /// natively (its own traffic must bypass the tun for engine transport).
  final List<String> perAppPackages;

  @override
  String toString() =>
      'TunnelConnectRequest(requestId: $requestId, config: **redacted**)';
}
