import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_interface/tunnel_interface.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

void main() {
  test('capabilities are immutable and protocol-specific', () {
    final source = <String>{'wireguard'};
    final capabilities = TunnelCapabilities(
      platform: 'linux',
      protocols: source,
      canProtectEntireDevice: true,
      canReportTraffic: true,
    );
    source.add('pptp');
    expect(capabilities.supports('wireguard'), isTrue);
    expect(capabilities.supports('pptp'), isFalse);
    expect(() => capabilities.protocols.add('openvpn'), throwsUnsupportedError);
  });

  test('snapshots, requests, and failures redact runtime config', () {
    const secret = 'synthetic-password-not-a-real-credential';
    final config = NormalizedConfig(
      protocol: 'vless',
      engine: 'xray',
      displayName: 'Test',
      sourceFormat: ConfigSourceFormat.fields,
      endpoints: const <VpnEndpoint>[
        VpnEndpoint(host: 'vpn.example.test', port: 443),
      ],
      credentials: const <String, Object?>{'password': secret},
      options: const <String, Object?>{},
      extensions: const <String, Object?>{},
      warnings: const <String>[],
    );
    final request = TunnelConnectRequest(
      requestId: 'request-1',
      connectionId: 'connection-1',
      config: config,
      productMode: ClientProductMode.whiteLabel,
    );
    const failure = TunnelFailure(code: 'native_error', safeMessage: secret);
    const snapshot = TunnelSnapshot(
      state: TunnelState.connected,
      sequence: 2,
      connectionId: 'connection-1',
      protocol: 'vless',
      failure: failure,
    );

    expect(snapshot.isActive, isTrue);
    for (final diagnostic in <String>[
      request.toString(),
      snapshot.toString(),
      failure.toString(),
    ]) {
      expect(diagnostic, isNot(contains(secret)));
    }
    expect(request.toString(), contains('**redacted**'));
    expect(snapshot.toString(), contains('**redacted**'));
  });
}
