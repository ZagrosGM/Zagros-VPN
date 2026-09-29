import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_interface/tunnel_interface.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

const _key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

NormalizedConfig wireGuardConfig() => parseWireGuard('''
[Interface]
PrivateKey = $_key
Address = 10.0.0.2/32
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = $_key
PresharedKey = $_key
Endpoint = 192.0.2.1:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
''');

NormalizedConfig wireGuardConfigWithEngine(String engine) {
  final source = wireGuardConfig();
  return NormalizedConfig(
    protocol: source.protocol,
    engine: engine,
    displayName: source.displayName,
    sourceFormat: source.sourceFormat,
    endpoints: source.endpoints,
    credentials: source.credentials,
    options: source.options,
    extensions: source.extensions,
    warnings: source.warnings,
  );
}

final class RecordingGateway implements NativeTunnelGateway {
  NativeTunnelCapabilities nativeCapabilities = NativeTunnelCapabilities(
    platform: 'android',
    protocols: <String>['wireguard'],
    canProtectEntireDevice: true,
    canReportTraffic: true,
    unavailableReasons: <String, String>{
      'openvpn': 'A reviewed native engine is not packaged.',
    },
  );
  NativeTunnelRequest? request;
  final List<String> connectedIds = <String>[];
  Completer<void>? connectGate;
  int connectCalls = 0;
  int disconnectCalls = 0;
  String? disconnectReason;
  Object? connectError;
  NativeTunnelStatus status = NativeTunnelStatus(
    state: NativeTunnelState.disconnected,
    sequence: 0,
    uplinkBytes: 0,
    downlinkBytes: 0,
  );

  @override
  Future<NativeTunnelCapabilities> getCapabilities() async =>
      nativeCapabilities;

  @override
  Future<NativeTunnelStatus> getStatus() async => status;

  @override
  Future<NativeTunnelStatus> connect(NativeTunnelRequest request) async {
    connectCalls += 1;
    connectedIds.add(request.connectionId);
    this.request = request;
    final gate = connectGate;
    if (gate != null) {
      connectGate = null;
      await gate.future;
    }
    final error = connectError;
    if (error != null) throw error;
    status = NativeTunnelStatus(
      state: NativeTunnelState.connecting,
      sequence: status.sequence + 1,
      uplinkBytes: 0,
      downlinkBytes: 0,
      connectionId: request.connectionId,
      protocol: request.protocol,
    );
    return status;
  }

  @override
  Future<NativeTunnelStatus> disconnect(String reason) async {
    disconnectCalls += 1;
    disconnectReason = reason;
    status = NativeTunnelStatus(
      state: NativeTunnelState.disconnected,
      sequence: status.sequence + 1,
      uplinkBytes: 0,
      downlinkBytes: 0,
    );
    return status;
  }
}

void main() {
  test('encoder emits bounded WireGuard input without script directives', () {
    final encoded = const NativeRuntimeConfigEncoder().encode(
      wireGuardConfig(),
    );
    final text = utf8.decode(encoded);

    expect(text, contains('[Interface]'));
    expect(text, contains('PrivateKey = $_key'));
    expect(text, contains('AllowedIPs = 0.0.0.0/0, ::/0'));
    expect(text, isNot(contains('PreUp')));
    encoded.fillRange(0, encoded.length, 0);
  });

  test('encoder rejects a protocol-engine mismatch', () {
    expect(
      () => const NativeRuntimeConfigEncoder().encode(
        wireGuardConfigWithEngine('system'),
      ),
      throwsUnsupportedError,
    );
  });

  test('encoder emits valid sing-box JSON for VLESS Reality', () {
    final config = NormalizedConfig(
      protocol: 'vless',
      engine: 'singbox',
      displayName: 'VLESS Reality Node',
      sourceFormat: ConfigSourceFormat.uri,
      endpoints: const <VpnEndpoint>[
        VpnEndpoint(host: '109.248.161.249', port: 443, transport: 'tcp'),
      ],
      credentials: const <String, Object?>{
        'id': 'a0000000-0000-0000-0000-000000000001',
      },
      options: const <String, Object?>{
        'security': 'reality',
        'sni': 'example.com',
        'fp': 'chrome',
        'pbk': 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE',
        'sid': '1234',
        'flow': 'xtls-rprx-vision',
      },
      extensions: const <String, Object?>{},
      warnings: const <String>[],
    );

    final encoded = const NativeRuntimeConfigEncoder().encode(config);
    final json = jsonDecode(utf8.decode(encoded)) as Map<String, Object?>;
    expect(json['inbounds'], isA<List<Object?>>());
    final outbounds = json['outbounds']! as List<Object?>;
    expect(outbounds.first, isA<Map<String, Object?>>());
    final proxy = outbounds.first! as Map<String, Object?>;
    expect(proxy['type'], 'vless');
    expect(proxy['server'], '109.248.161.249');
    expect(proxy['server_port'], 443);
    expect(proxy['uuid'], 'a0000000-0000-0000-0000-000000000001');
    expect(proxy['flow'], 'xtls-rprx-vision');
    final tls = proxy['tls']! as Map<String, Object?>;
    expect(tls['enabled'], isTrue);
    final reality = tls['reality']! as Map<String, Object?>;
    expect(reality['enabled'], isTrue);
    expect(reality['public_key'], 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE');
    encoded.fillRange(0, encoded.length, 0);
  });

  test('encoder accepts application-mode sing-box outbound extension directly', () {
    final config = NormalizedConfig(
      protocol: 'vless',
      engine: 'sing-box',
      displayName: 'Zagros VLESS',
      sourceFormat: ConfigSourceFormat.singBoxJson,
      endpoints: const <VpnEndpoint>[
        VpnEndpoint(host: '109.248.161.249', port: 443),
      ],
      credentials: const <String, Object?>{
        'uuid': '43924c53-b40b-4dc8-a831-c4d32a9e2db3',
      },
      options: const <String, Object?>{},
      extensions: const <String, Object?>{
        'outbound': <String, Object?>{
          'type': 'vless',
          'tag': 'proxy',
          'server': '109.248.161.249',
          'server_port': 443,
          'uuid': '43924c53-b40b-4dc8-a831-c4d32a9e2db3',
          'tls': <String, Object?>{
            'enabled': true,
            'server_name': 'example.com',
          },
        },
      },
      warnings: const <String>[],
    );

    final encoded = const NativeRuntimeConfigEncoder().encode(config);
    final json = jsonDecode(utf8.decode(encoded)) as Map<String, Object?>;
    final outbounds = json['outbounds']! as List<Object?>;
    final proxy = outbounds.first! as Map<String, Object?>;
    expect(proxy['type'], 'vless');
    expect(proxy['server'], '109.248.161.249');
    expect(proxy['uuid'], '43924c53-b40b-4dc8-a831-c4d32a9e2db3');
    encoded.fillRange(0, encoded.length, 0);
  });

  test('encoder rejects VLESS with missing Reality public key', () {
    final config = NormalizedConfig(
      protocol: 'vless',
      engine: 'singbox',
      displayName: 'VLESS Missing PBK',
      sourceFormat: ConfigSourceFormat.uri,
      endpoints: const <VpnEndpoint>[
        VpnEndpoint(host: '109.248.161.249', port: 443),
      ],
      credentials: const <String, Object?>{
        'id': 'a0000000-0000-0000-0000-000000000001',
      },
      options: const <String, Object?>{
        'security': 'reality',
      },
      extensions: const <String, Object?>{},
      warnings: const <String>[],
    );

    expect(
      () => const NativeRuntimeConfigEncoder().encode(config),
      throwsFormatException,
    );
  });

  test('encoder encodes VLESS WebSocket and gRPC transports correctly', () {
    final wsConfig = NormalizedConfig(
      protocol: 'vless',
      engine: 'singbox',
      displayName: 'VLESS WS',
      sourceFormat: ConfigSourceFormat.uri,
      endpoints: const <VpnEndpoint>[
        VpnEndpoint(host: 'ws.example.com', port: 443),
      ],
      credentials: const <String, Object?>{
        'id': 'a0000000-0000-0000-0000-000000000001',
      },
      options: const <String, Object?>{
        'type': 'ws',
        'path': '/ws-path',
        'host': 'ws.example.com',
        'security': 'tls',
      },
      extensions: const <String, Object?>{},
      warnings: const <String>[],
    );
    final wsEncoded = const NativeRuntimeConfigEncoder().encode(wsConfig);
    final wsJson = jsonDecode(utf8.decode(wsEncoded)) as Map<String, Object?>;
    final wsOutbound = (wsJson['outbounds']! as List<Object?>).first! as Map<String, Object?>;
    final wsTransport = wsOutbound['transport']! as Map<String, Object?>;
    expect(wsTransport['type'], 'ws');
    expect(wsTransport['path'], '/ws-path');

    final grpcConfig = NormalizedConfig(
      protocol: 'vless',
      engine: 'singbox',
      displayName: 'VLESS gRPC',
      sourceFormat: ConfigSourceFormat.uri,
      endpoints: const <VpnEndpoint>[
        VpnEndpoint(host: 'grpc.example.com', port: 443),
      ],
      credentials: const <String, Object?>{
        'id': 'a0000000-0000-0000-0000-000000000001',
      },
      options: const <String, Object?>{
        'type': 'grpc',
        'serviceName': 'grpc-service',
        'security': 'tls',
      },
      extensions: const <String, Object?>{},
      warnings: const <String>[],
    );
    final grpcEncoded = const NativeRuntimeConfigEncoder().encode(grpcConfig);
    final grpcJson = jsonDecode(utf8.decode(grpcEncoded)) as Map<String, Object?>;
    final grpcOutbound = (grpcJson['outbounds']! as List<Object?>).first! as Map<String, Object?>;
    final grpcTransport = grpcOutbound['transport']! as Map<String, Object?>;
    expect(grpcTransport['type'], 'grpc');
    expect(grpcTransport['service_name'], 'grpc-service');
  });

  test('encoder emits valid sing-box JSON for VMess WS TLS', () {
    final config = NormalizedConfig(
      protocol: 'vmess',
      engine: 'singbox',
      displayName: 'VMess Node',
      sourceFormat: ConfigSourceFormat.vmessJson,
      endpoints: const <VpnEndpoint>[
        VpnEndpoint(host: 'vmess.example.com', port: 443),
      ],
      credentials: const <String, Object?>{
        'id': 'b0000000-0000-0000-0000-000000000002',
      },
      options: const <String, Object?>{
        'net': 'ws',
        'path': '/vmess-ws',
        'host': 'vmess.example.com',
        'tls': 'tls',
      },
      extensions: const <String, Object?>{},
      warnings: const <String>[],
    );
    final encoded = const NativeRuntimeConfigEncoder().encode(config);
    final json = jsonDecode(utf8.decode(encoded)) as Map<String, Object?>;
    final outbound = (json['outbounds']! as List<Object?>).first! as Map<String, Object?>;
    expect(outbound['type'], 'vmess');
    expect(outbound['server'], 'vmess.example.com');
    expect(outbound['server_port'], 443);
    expect(outbound['uuid'], 'b0000000-0000-0000-0000-000000000002');
    expect(outbound['security'], 'auto');
    expect((outbound['transport'] as Map<String, Object?>)['type'], 'ws');
    expect((outbound['tls'] as Map<String, Object?>)['enabled'], isTrue);
  });

  test('encoder emits valid sing-box JSON for Trojan gRPC TLS', () {
    final config = NormalizedConfig(
      protocol: 'trojan',
      engine: 'singbox',
      displayName: 'Trojan Node',
      sourceFormat: ConfigSourceFormat.uri,
      endpoints: const <VpnEndpoint>[
        VpnEndpoint(host: 'trojan.example.com', port: 443),
      ],
      credentials: const <String, Object?>{
        'password': 'trojan-secret-password',
      },
      options: const <String, Object?>{
        'type': 'grpc',
        'serviceName': 'trojan-grpc-service',
        'sni': 'trojan.example.com',
      },
      extensions: const <String, Object?>{},
      warnings: const <String>[],
    );
    final encoded = const NativeRuntimeConfigEncoder().encode(config);
    final json = jsonDecode(utf8.decode(encoded)) as Map<String, Object?>;
    final outbound = (json['outbounds']! as List<Object?>).first! as Map<String, Object?>;
    expect(outbound['type'], 'trojan');
    expect(outbound['server'], 'trojan.example.com');
    expect(outbound['password'], 'trojan-secret-password');
    expect((outbound['transport'] as Map<String, Object?>)['type'], 'grpc');
    expect((outbound['tls'] as Map<String, Object?>)['enabled'], isTrue);
  });

  test('encoder emits valid sing-box JSON for Shadowsocks', () {
    final config = NormalizedConfig(
      protocol: 'shadowsocks',
      engine: 'singbox',
      displayName: 'SS Node',
      sourceFormat: ConfigSourceFormat.uri,
      endpoints: const <VpnEndpoint>[
        VpnEndpoint(host: 'ss.example.com', port: 8388),
      ],
      credentials: const <String, Object?>{
        'method': 'aes-256-gcm',
        'password': 'ss-password',
      },
      options: const <String, Object?>{},
      extensions: const <String, Object?>{},
      warnings: const <String>[],
    );
    final encoded = const NativeRuntimeConfigEncoder().encode(config);
    final json = jsonDecode(utf8.decode(encoded)) as Map<String, Object?>;
    final outbound = (json['outbounds']! as List<Object?>).first! as Map<String, Object?>;
    expect(outbound['type'], 'shadowsocks');
    expect(outbound['server'], 'ss.example.com');
    expect(outbound['server_port'], 8388);
    expect(outbound['method'], 'aes-256-gcm');
    expect(outbound['password'], 'ss-password');
  });

  test('encoder emits valid sing-box JSON for Hysteria 2 with Obfs', () {
    final config = NormalizedConfig(
      protocol: 'hysteria2',
      engine: 'singbox',
      displayName: 'Hy2 Node',
      sourceFormat: ConfigSourceFormat.uri,
      endpoints: const <VpnEndpoint>[
        VpnEndpoint(host: 'hy2.example.com', port: 443),
      ],
      credentials: const <String, Object?>{
        'password': 'hy2-secret-auth',
      },
      options: const <String, Object?>{
        'obfs': 'salamander',
        'obfs-password': 'salamander-secret',
        'upmbps': '50',
        'downmbps': '100',
      },
      extensions: const <String, Object?>{},
      warnings: const <String>[],
    );
    final encoded = const NativeRuntimeConfigEncoder().encode(config);
    final json = jsonDecode(utf8.decode(encoded)) as Map<String, Object?>;
    final outbound = (json['outbounds']! as List<Object?>).first! as Map<String, Object?>;
    expect(outbound['type'], 'hysteria2');
    expect(outbound['password'], 'hy2-secret-auth');
    expect(outbound['up_mbps'], 50);
    expect(outbound['down_mbps'], 100);
    final obfs = outbound['obfs'] as Map<String, Object?>;
    expect(obfs['type'], 'salamander');
    expect(obfs['password'], 'salamander-secret');
    expect((outbound['tls'] as Map<String, Object?>)['enabled'], isTrue);
  });

  test('encoder emits valid sing-box JSON for TUIC', () {
    final config = NormalizedConfig(
      protocol: 'tuic',
      engine: 'singbox',
      displayName: 'TUIC Node',
      sourceFormat: ConfigSourceFormat.uri,
      endpoints: const <VpnEndpoint>[
        VpnEndpoint(host: 'tuic.example.com', port: 8443),
      ],
      credentials: const <String, Object?>{
        'uuid': 'c0000000-0000-0000-0000-000000000003',
        'password': 'tuic-password',
      },
      options: const <String, Object?>{
        'congestion_control': 'bbr',
        'udp_relay_mode': 'native',
      },
      extensions: const <String, Object?>{},
      warnings: const <String>[],
    );
    final encoded = const NativeRuntimeConfigEncoder().encode(config);
    final json = jsonDecode(utf8.decode(encoded)) as Map<String, Object?>;
    final outbound = (json['outbounds']! as List<Object?>).first! as Map<String, Object?>;
    expect(outbound['type'], 'tuic');
    expect(outbound['uuid'], 'c0000000-0000-0000-0000-000000000003');
    expect(outbound['password'], 'tuic-password');
    expect(outbound['congestion_control'], 'bbr');
    expect(outbound['udp_relay_mode'], 'native');
    expect((outbound['tls'] as Map<String, Object?>)['enabled'], isTrue);
  });

  test('encoder rejects configs with missing required credentials', () {
    final noPwTrojan = NormalizedConfig(
      protocol: 'trojan',
      engine: 'singbox',
      displayName: 'Trojan Invalid',
      sourceFormat: ConfigSourceFormat.uri,
      endpoints: const <VpnEndpoint>[
        VpnEndpoint(host: 'trojan.example.com', port: 443),
      ],
      credentials: const <String, Object?>{},
      options: const <String, Object?>{},
      extensions: const <String, Object?>{},
      warnings: const <String>[],
    );
    expect(
      () => const NativeRuntimeConfigEncoder().encode(noPwTrojan),
      throwsFormatException,
    );

    final noPwSS = NormalizedConfig(
      protocol: 'shadowsocks',
      engine: 'singbox',
      displayName: 'SS Invalid',
      sourceFormat: ConfigSourceFormat.uri,
      endpoints: const <VpnEndpoint>[
        VpnEndpoint(host: 'ss.example.com', port: 8388),
      ],
      credentials: const <String, Object?>{},
      options: const <String, Object?>{},
      extensions: const <String, Object?>{},
      warnings: const <String>[],
    );
    expect(
      () => const NativeRuntimeConfigEncoder().encode(noPwSS),
      throwsFormatException,
    );

    final noUuidTuic = NormalizedConfig(
      protocol: 'tuic',
      engine: 'singbox',
      displayName: 'TUIC Invalid',
      sourceFormat: ConfigSourceFormat.uri,
      endpoints: const <VpnEndpoint>[
        VpnEndpoint(host: 'tuic.example.com', port: 8443),
      ],
      credentials: const <String, Object?>{
        'password': 'tuic-password',
      },
      options: const <String, Object?>{},
      extensions: const <String, Object?>{},
      warnings: const <String>[],
    );
    expect(
      () => const NativeRuntimeConfigEncoder().encode(noUuidTuic),
      throwsFormatException,
    );
  });

  test(
    'facade rejects a protocol-engine mismatch before native transfer',
    () async {
      final gateway = RecordingGateway();
      final adapter = NativeTunnelAdapter(
        gateway: gateway,
        registerNativeCallbacks: false,
      );

      await expectLater(
        adapter.connect(
          TunnelConnectRequest(
            requestId: 'request-mismatch',
            connectionId: 'connection-mismatch',
            config: wireGuardConfigWithEngine('system'),
            productMode: ClientProductMode.whiteLabel,
          ),
        ),
        throwsA(
          isA<TunnelFailure>().having(
            (failure) => failure.code,
            'code',
            'protocol_engine_mismatch',
          ),
        ),
      );
      expect(gateway.connectCalls, 0);
      expect(gateway.request, isNull);
      await adapter.dispose();
    },
  );

  test(
    'system IKEv2 encoder emits only the bounded allowlisted JSON fields',
    () {
      final config = NormalizedConfig(
        protocol: 'ikev2',
        engine: 'system',
        displayName: 'IKEv2',
        sourceFormat: ConfigSourceFormat.fields,
        endpoints: const <VpnEndpoint>[
          VpnEndpoint(host: 'vpn.example.test', port: 500),
        ],
        credentials: const <String, Object?>{
          'username': 'alice',
          'password': 'runtime-secret',
        },
        options: const <String, Object?>{
          'remote_identifier': 'vpn.example.test',
        },
        extensions: const <String, Object?>{
          'untrusted_extra': 'must-not-cross-native-boundary',
        },
        warnings: const <String>[],
      );

      final encoded = const NativeRuntimeConfigEncoder().encode(config);
      final json = jsonDecode(utf8.decode(encoded)) as Map<String, Object?>;
      expect(json.keys.toSet(), <String>{
        'version',
        'server',
        'port',
        'username',
        'password',
        'remote_identifier',
      });
      expect(json['password'], 'runtime-secret');
      expect(json.values, isNot(contains('must-not-cross-native-boundary')));
      encoded.fillRange(0, encoded.length, 0);
    },
  );

  test('system IKEv2 encoder rejects unsupported custom ports', () {
    final config = NormalizedConfig(
      protocol: 'ikev2',
      engine: 'system',
      displayName: 'IKEv2 custom port',
      sourceFormat: ConfigSourceFormat.fields,
      endpoints: const <VpnEndpoint>[
        VpnEndpoint(host: 'vpn.example.test', port: 8443),
      ],
      credentials: const <String, Object?>{
        'username': 'alice',
        'password': 'runtime-secret',
      },
      options: const <String, Object?>{},
      extensions: const <String, Object?>{},
      warnings: const <String>[],
    );

    expect(
      () => const NativeRuntimeConfigEncoder().encode(config),
      throwsFormatException,
    );
  });

  test('encoder rejects privileged WireGuard script hooks', () {
    final config = NormalizedConfig(
      protocol: 'wireguard',
      engine: 'wireguard',
      displayName: 'unsafe',
      sourceFormat: ConfigSourceFormat.wireGuardIni,
      endpoints: const <VpnEndpoint>[
        VpnEndpoint(host: '192.0.2.1', port: 51820),
      ],
      credentials: const <String, Object?>{'private_key': _key},
      options: const <String, Object?>{},
      extensions: <String, Object?>{
        'interface': <String, Object?>{
          'privatekey': _key,
          'preup': 'touch /tmp/not-allowed',
        },
        'peers': <Object?>[
          <String, Object?>{
            'publickey': _key,
            'endpoint': '192.0.2.1:51820',
            'allowedips': '0.0.0.0/0',
          },
        ],
      },
      warnings: const <String>[],
    );

    expect(
      () => const NativeRuntimeConfigEncoder().encode(config),
      throwsFormatException,
    );
  });

  test('capabilities preserve protocol-specific unavailable reasons', () async {
    final gateway = RecordingGateway();
    final adapter = NativeTunnelAdapter(
      gateway: gateway,
      registerNativeCallbacks: false,
    );

    final capabilities = await adapter.capabilities();

    expect(capabilities.platform, 'android');
    expect(capabilities.supports('WireGuard'), isTrue);
    expect(capabilities.supports('openvpn'), isFalse);
    expect(
      capabilities.unavailableReasons['openvpn'],
      contains('not packaged'),
    );
    await adapter.dispose();
  });

  test(
    'runtime-only policy removes structured OS-profile capabilities',
    () async {
      final gateway = RecordingGateway()
        ..nativeCapabilities = NativeTunnelCapabilities(
          platform: 'macos',
          protocols: <String>['ikev2'],
          canProtectEntireDevice: true,
          canReportTraffic: false,
          unavailableReasons: <String, String>{},
        );
      final adapter = NativeTunnelAdapter(
        gateway: gateway,
        allowStructuredOsProfiles: false,
        registerNativeCallbacks: false,
      );

      final capabilities = await adapter.capabilities();
      expect(capabilities.protocols, isEmpty);
      expect(capabilities.canProtectEntireDevice, isFalse);
      expect(capabilities.unavailableReasons['ikev2'], contains('OS-managed'));
      await adapter.dispose();
    },
  );

  test(
    'connect forwards runtime bytes then erases the mutable payload',
    () async {
      final gateway = RecordingGateway();
      final adapter = NativeTunnelAdapter(
        gateway: gateway,
        registerNativeCallbacks: false,
      );

      final snapshot = await adapter.connect(
        TunnelConnectRequest(
          requestId: 'request-1',
          connectionId: 'connection-1',
          config: wireGuardConfig(),
          productMode: ClientProductMode.whiteLabel,
        ),
      );

      expect(snapshot.state, TunnelState.connecting);
      expect(gateway.request?.whiteLabel, isTrue);
      expect(gateway.request?.configPayload, everyElement(0));
      await adapter.dispose();
    },
  );

  test(
    'adapter never invents connected state before a native confirmation',
    () async {
      final gateway = RecordingGateway();
      final adapter = NativeTunnelAdapter(
        gateway: gateway,
        registerNativeCallbacks: false,
      );
      await adapter.connect(
        TunnelConnectRequest(
          requestId: 'request-2',
          connectionId: 'connection-2',
          config: wireGuardConfig(),
          productMode: ClientProductMode.official,
        ),
      );

      final connectedAt = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch,
        isUtc: true,
      );
      final nextSnapshot = adapter.snapshots.first;
      adapter.onStatusChanged(
        NativeTunnelStatus(
          state: NativeTunnelState.connected,
          sequence: 2,
          uplinkBytes: 42,
          downlinkBytes: 84,
          connectionId: 'connection-2',
          protocol: 'wireguard',
          connectedAtEpochMs: connectedAt.millisecondsSinceEpoch,
        ),
      );

      final current = await nextSnapshot;
      expect(current.state, TunnelState.connected);
      expect(current.connectedAt, connectedAt);
      expect(current.uplinkBytes, 42);
      await adapter.dispose();
    },
  );

  test('malformed native connected event is dropped fail-closed', () async {
    final gateway = RecordingGateway();
    final adapter = NativeTunnelAdapter(
      gateway: gateway,
      registerNativeCallbacks: false,
    );
    await adapter.connect(
      TunnelConnectRequest(
        requestId: 'request-3',
        connectionId: 'connection-3',
        config: wireGuardConfig(),
        productMode: ClientProductMode.official,
      ),
    );

    final emitted = <TunnelSnapshot>[];
    final subscription = adapter.snapshots.listen(emitted.add);
    adapter.onStatusChanged(
      NativeTunnelStatus(
        state: NativeTunnelState.connected,
        sequence: 2,
        uplinkBytes: 0,
        downlinkBytes: 0,
        connectionId: 'wrong-connection',
        protocol: 'wireguard',
        connectedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    expect(await adapter.current(), isA<TunnelSnapshot>());
    expect(emitted, isEmpty);
    await subscription.cancel();
    await adapter.dispose();
  });

  test('platform exceptions are reduced to fixed safe failures', () async {
    final gateway = RecordingGateway()
      ..connectError = PlatformException(
        code: 'ENGINE-FAILED',
        message: 'secret-bearing native exception',
      );
    final adapter = NativeTunnelAdapter(
      gateway: gateway,
      registerNativeCallbacks: false,
    );

    await expectLater(
      adapter.connect(
        TunnelConnectRequest(
          requestId: 'request-4',
          connectionId: 'connection-4',
          config: wireGuardConfig(),
          productMode: ClientProductMode.official,
        ),
      ),
      throwsA(
        isA<TunnelFailure>()
            .having((error) => error.code, 'code', 'engine_failed')
            .having(
              (error) => error.safeMessage,
              'message',
              isNot(contains('secret-bearing')),
            ),
      ),
    );
    expect(gateway.request?.configPayload, everyElement(0));
    await adapter.dispose();
  });

  test(
    'native validation rejection does not leave a synthetic active tunnel',
    () async {
      final gateway = RecordingGateway()
        ..connectError = PlatformException(
          code: 'invalid_config',
          message: 'untrusted detail',
        );
      final adapter = NativeTunnelAdapter(
        gateway: gateway,
        registerNativeCallbacks: false,
      );

      await expectLater(
        adapter.connect(
          TunnelConnectRequest(
            requestId: 'request-rejected',
            connectionId: 'connection-rejected',
            config: wireGuardConfig(),
            productMode: ClientProductMode.whiteLabel,
          ),
        ),
        throwsA(
          isA<TunnelFailure>().having(
            (failure) => failure.code,
            'code',
            'invalid_config',
          ),
        ),
      );
      await adapter.dispose();
      expect(gateway.disconnectCalls, 0);
    },
  );

  test(
    'unsupported protocol is rejected before config reaches native code',
    () async {
      final gateway = RecordingGateway()
        ..nativeCapabilities = NativeTunnelCapabilities(
          platform: 'android',
          protocols: <String>[],
          canProtectEntireDevice: false,
          canReportTraffic: false,
          unavailableReasons: <String, String>{
            'wireguard': 'WireGuard is unavailable on this device.',
          },
        );
      final adapter = NativeTunnelAdapter(
        gateway: gateway,
        registerNativeCallbacks: false,
      );

      await expectLater(
        adapter.connect(
          TunnelConnectRequest(
            requestId: 'request-5',
            connectionId: 'connection-5',
            config: wireGuardConfig(),
            productMode: ClientProductMode.whiteLabel,
          ),
        ),
        throwsA(
          isA<TunnelFailure>().having(
            (error) => error.code,
            'code',
            'protocol_unavailable',
          ),
        ),
      );
      expect(gateway.connectCalls, 0);
      expect(gateway.request, isNull);
      await adapter.dispose();
    },
  );

  test('stale and decreasing-counter native events are dropped', () async {
    final gateway = RecordingGateway();
    final adapter = NativeTunnelAdapter(
      gateway: gateway,
      registerNativeCallbacks: false,
    );
    await adapter.connect(
      TunnelConnectRequest(
        requestId: 'request-6',
        connectionId: 'connection-6',
        config: wireGuardConfig(),
        productMode: ClientProductMode.official,
      ),
    );
    final connectedAt = DateTime.now().toUtc().millisecondsSinceEpoch;
    adapter.onStatusChanged(
      NativeTunnelStatus(
        state: NativeTunnelState.connected,
        sequence: 3,
        uplinkBytes: 100,
        downlinkBytes: 200,
        connectionId: 'connection-6',
        protocol: 'wireguard',
        connectedAtEpochMs: connectedAt,
      ),
    );
    final emitted = <TunnelSnapshot>[];
    final subscription = adapter.snapshots.listen(emitted.add);

    adapter.onStatusChanged(
      NativeTunnelStatus(
        state: NativeTunnelState.connected,
        sequence: 2,
        uplinkBytes: 101,
        downlinkBytes: 201,
        connectionId: 'connection-6',
        protocol: 'wireguard',
        connectedAtEpochMs: connectedAt,
      ),
    );
    adapter.onStatusChanged(
      NativeTunnelStatus(
        state: NativeTunnelState.connected,
        sequence: 4,
        uplinkBytes: 99,
        downlinkBytes: 201,
        connectionId: 'connection-6',
        protocol: 'wireguard',
        connectedAtEpochMs: connectedAt,
      ),
    );

    expect(emitted, isEmpty);
    await subscription.cancel();
    await adapter.dispose();
  });

  test(
    'replacement connect tears the previous native tunnel down first',
    () async {
      final gateway = RecordingGateway();
      final adapter = NativeTunnelAdapter(
        gateway: gateway,
        registerNativeCallbacks: false,
      );
      await adapter.connect(
        TunnelConnectRequest(
          requestId: 'request-replace-1',
          connectionId: 'connection-replace-1',
          config: wireGuardConfig(),
          productMode: ClientProductMode.official,
        ),
      );
      await adapter.connect(
        TunnelConnectRequest(
          requestId: 'request-replace-2',
          connectionId: 'connection-replace-2',
          config: wireGuardConfig(),
          productMode: ClientProductMode.whiteLabel,
        ),
      );

      expect(gateway.connectCalls, 2);
      expect(gateway.disconnectCalls, 1);
      expect(gateway.disconnectReason, 'replace_connection');
      expect(gateway.request?.connectionId, 'connection-replace-2');
      await adapter.dispose();
    },
  );

  test(
    'concurrent connects are serialized before replacement state mutates',
    () async {
      final gateway = RecordingGateway();
      final gate = Completer<void>();
      gateway.connectGate = gate;
      final adapter = NativeTunnelAdapter(
        gateway: gateway,
        registerNativeCallbacks: false,
      );
      final first = adapter.connect(
        TunnelConnectRequest(
          requestId: 'request-serialized-1',
          connectionId: 'connection-serialized-1',
          config: wireGuardConfig(),
          productMode: ClientProductMode.official,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final second = adapter.connect(
        TunnelConnectRequest(
          requestId: 'request-serialized-2',
          connectionId: 'connection-serialized-2',
          config: wireGuardConfig(),
          productMode: ClientProductMode.whiteLabel,
        ),
      );

      expect(gateway.connectCalls, 1);
      gate.complete();
      await first;
      await second;

      expect(gateway.connectedIds, <String>[
        'connection-serialized-1',
        'connection-serialized-2',
      ]);
      expect(gateway.disconnectCalls, 1);
      expect(gateway.disconnectReason, 'replace_connection');
      await adapter.dispose();
    },
  );

  test(
    'disconnect is delegated and adapter disposal tears active state down',
    () async {
      final gateway = RecordingGateway();
      final adapter = NativeTunnelAdapter(
        gateway: gateway,
        registerNativeCallbacks: false,
      );
      await adapter.connect(
        TunnelConnectRequest(
          requestId: 'request-7',
          connectionId: 'connection-7',
          config: wireGuardConfig(),
          productMode: ClientProductMode.official,
        ),
      );

      final disconnected = await adapter.disconnect(reason: 'User requested');
      expect(disconnected.state, TunnelState.disconnected);
      expect(gateway.disconnectReason, 'user_requested');
      expect(gateway.disconnectCalls, 1);

      await adapter.connect(
        TunnelConnectRequest(
          requestId: 'request-8',
          connectionId: 'connection-8',
          config: wireGuardConfig(),
          productMode: ClientProductMode.official,
        ),
      );
      await adapter.dispose();
      expect(gateway.disconnectReason, 'adapter_disposed');
      expect(gateway.disconnectCalls, 2);
    },
  );
}
