import 'package:pigeon/pigeon.dart';

// Runtime-only IPC contract. Native implementations must not persist, log,
// display, or return configPayload. Connection methods are asynchronous because
// operating-system consent and real engine establishment can take time.
enum NativeTunnelState {
  disconnected,
  preparing,
  connecting,
  connected,
  disconnecting,
  failed,
}

class NativeTunnelRequest {
  NativeTunnelRequest({
    required this.requestId,
    required this.connectionId,
    required this.protocol,
    required this.engine,
    required this.configPayload,
    required this.whiteLabel,
    this.dnsServers,
    this.perAppMode,
    this.perAppPackages,
  });

  String requestId;
  String connectionId;
  String protocol;
  String engine;
  Uint8List configPayload;
  bool whiteLabel;

  /// App-chosen DNS servers for the device tun (settings DNS preset).
  /// Null/empty = platform defaults. Never persisted natively.
  List<String>? dnsServers;

  /// Per-app proxy: "off" | "allow" (only listed apps use the VPN) |
  /// "deny" (listed apps bypass the VPN). Null = off.
  String? perAppMode;

  /// Package names for perAppMode. Never persisted natively.
  List<String>? perAppPackages;
}

class NativeTunnelStatus {
  NativeTunnelStatus({
    required this.state,
    required this.sequence,
    required this.uplinkBytes,
    required this.downlinkBytes,
    this.connectionId,
    this.protocol,
    this.connectedAtEpochMs,
    this.failureCode,
    this.safeFailureMessage,
  });

  NativeTunnelState state;
  int sequence;
  int uplinkBytes;
  int downlinkBytes;
  String? connectionId;
  String? protocol;
  int? connectedAtEpochMs;
  String? failureCode;
  String? safeFailureMessage;
}

class NativeTunnelCapabilities {
  NativeTunnelCapabilities({
    required this.platform,
    required this.protocols,
    required this.canProtectEntireDevice,
    required this.canReportTraffic,
    required this.unavailableReasons,
  });

  String platform;
  List<String> protocols;
  bool canProtectEntireDevice;
  bool canReportTraffic;
  Map<String, String> unavailableReasons;
}

@HostApi()
abstract class NativeTunnelHostApi {
  NativeTunnelCapabilities getCapabilities();

  NativeTunnelStatus getStatus();

  @async
  NativeTunnelStatus connect(NativeTunnelRequest request);

  @async
  NativeTunnelStatus disconnect(String reason);
}

@FlutterApi()
abstract class NativeTunnelFlutterApi {
  void onStatusChanged(NativeTunnelStatus status);
}
