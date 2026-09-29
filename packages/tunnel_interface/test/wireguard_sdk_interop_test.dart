import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_interface/tunnel_interface.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

// Same shape the panel serves from /sub/file/<token>/wireguard/<tag>.
const _wgConf = '''[Interface]
PrivateKey = AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=
Address = 10.9.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = Hx4dHBsaGRgXFhUUExIREA8ODQwLCgkIBwYFBAMCAQA=
Endpoint = 203.0.113.7:51820
AllowedIPs = 0.0.0.0/0
''';

void main() {
  test('native encoder accepts an SDK-parsed WireGuard file', () {
    final parsed = parseWireGuard(_wgConf, displayName: 'WireGuard · wg0');
    final bytes = const NativeRuntimeConfigEncoder().encode(parsed);
    final text = utf8.decode(bytes);
    expect(text, contains('[Interface]'));
    expect(text, contains('PrivateKey = '));
    expect(text, contains('[Peer]'));
    expect(text, contains('Endpoint = 203.0.113.7:51820'));
  });

  test('native encoder rejects unsupported protocols', () {
    final parsed = parseShareUri('pptp://alice:secret@example:1723#one');
    expect(
      () => const NativeRuntimeConfigEncoder().encode(parsed),
      throwsUnsupportedError,
    );
  });
}
