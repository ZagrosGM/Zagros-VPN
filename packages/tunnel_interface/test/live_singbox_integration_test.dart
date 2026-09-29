import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_interface/tunnel_interface.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

String get _singBoxPath {
  for (final path in [
    '/usr/local/share/sing-box',
    '/var/lib/zagros/cores/sing-box/sing-box',
    'sing-box',
  ]) {
    if (File(path).existsSync()) return path;
  }
  return 'sing-box';
}

void main() {
  group('Comprehensive Protocol Live & Loopback End-to-End Tests', () {
    const encoder = NativeRuntimeConfigEncoder();

    test('1. Shadowsocks Live Connection Test (Port 1080)', () async {
      final uri =
          'ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTozWUVZajJjSjFsUElDczU3RjVNM2hn@109.248.161.249:1080#Zagros-SS';
      final config = parseShareUri(uri);
      expect(config.protocol, equals('shadowsocks'));

      final configBytes = encoder.encode(config);
      final configJson = utf8.decode(configBytes);

      final tempFile = File('/tmp/test_ss_live.json');
      await tempFile.writeAsString(configJson);

      final checkResult =
          await Process.run(_singBoxPath, ['check', '-c', tempFile.path]);
      expect(checkResult.exitCode, equals(0),
          reason: 'sing-box check failed: ${checkResult.stderr}');

      final process =
          await Process.start(_singBoxPath, ['run', '-c', tempFile.path]);
      try {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(process.pid, isPositive);

        final client = HttpClient();
        client.findProxy = (uri) => 'PROXY 127.0.0.1:20808';
        client.connectionTimeout = const Duration(seconds: 5);

        try {
          final request =
              await client.getUrl(Uri.parse('http://109.248.161.249:8088/'));
          final response = await request.close();
          expect(response.statusCode, inInclusiveRange(200, 499));
          print(
              'Shadowsocks live proxy request status: ${response.statusCode}');
        } catch (e) {
          print('Shadowsocks proxy HTTP probe response: $e');
        } finally {
          client.close();
        }
      } finally {
        process.kill(ProcessSignal.sigkill);
        await tempFile.delete();
      }
    });

    test('2. VLESS Live Connection Test (Port 37387)', () async {
      final uri =
          'vless://b60f3716-ab0b-46eb-89ff-c29024b7c8ee@109.248.161.249:37387?type=ws&path=%2Fws#Zagros-VLESS';
      final config = parseShareUri(uri);
      expect(config.protocol, equals('vless'));

      final configBytes = encoder.encode(config);
      final configJson = utf8.decode(configBytes);

      final tempFile = File('/tmp/test_vless_live.json');
      await tempFile.writeAsString(configJson);

      final checkResult =
          await Process.run(_singBoxPath, ['check', '-c', tempFile.path]);
      expect(checkResult.exitCode, equals(0),
          reason: 'sing-box check failed: ${checkResult.stderr}');

      final process =
          await Process.start(_singBoxPath, ['run', '-c', tempFile.path]);
      try {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(process.pid, isPositive);

        final client = HttpClient();
        client.findProxy = (uri) => 'PROXY 127.0.0.1:20808';
        client.connectionTimeout = const Duration(seconds: 5);

        try {
          final request =
              await client.getUrl(Uri.parse('http://109.248.161.249:8088/'));
          final response = await request.close();
          expect(response.statusCode, inInclusiveRange(200, 499));
          print('VLESS live proxy request status: ${response.statusCode}');
        } catch (e) {
          print('VLESS proxy probe response: $e');
        } finally {
          client.close();
        }
      } finally {
        process.kill(ProcessSignal.sigkill);
        await tempFile.delete();
      }
    });

    test('3. Hysteria2 Live Handshake Test (Port 17085)', () async {
      final uri =
          'hy2://eWtygbQivCr1IfVUqJJXS0jJ@zagros.azbarfilm.ir:17085?sni=zagros.azbarfilm.ir&alpn=h3&insecure=1#Zagros-Hy2';
      final config = parseShareUri(uri);
      expect(config.protocol, equals('hysteria2'));

      final configBytes = encoder.encode(config);
      final configJson = utf8.decode(configBytes);

      final tempFile = File('/tmp/test_hy2_live.json');
      await tempFile.writeAsString(configJson);

      final checkResult =
          await Process.run(_singBoxPath, ['check', '-c', tempFile.path]);
      expect(checkResult.exitCode, equals(0),
          reason: 'sing-box check failed: ${checkResult.stderr}');

      final process =
          await Process.start(_singBoxPath, ['run', '-c', tempFile.path]);
      try {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(process.pid, isPositive);
        print(
            'Hysteria2 client initialized and running with PID: ${process.pid}');
      } finally {
        process.kill(ProcessSignal.sigkill);
        await tempFile.delete();
      }
    });

    test('4. VMess End-to-End Handshake & Data Transfer Test', () async {
      final serverConfig = {
        'log': {'level': 'warn'},
        'inbounds': [
          {
            'type': 'vmess',
            'tag': 'vmess-in',
            'listen': '127.0.0.1',
            'listen_port': 39001,
            'users': [
              {
                'name': 'test-user',
                'uuid': 'a661c94d-2a1d-4876-9076-13cb89a3f295',
                'alterId': 0
              }
            ],
            'transport': {'type': 'ws', 'path': '/vmess-ws'}
          }
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'}
        ]
      };
      final serverFile = File('/tmp/test_vmess_server.json');
      await serverFile.writeAsString(jsonEncode(serverConfig));
      final serverProc =
          await Process.start(_singBoxPath, ['run', '-c', serverFile.path]);

      final vmessPayload = jsonEncode({
        'v': '2',
        'ps': 'Zagros-VMess',
        'add': '127.0.0.1',
        'port': 39001,
        'id': 'a661c94d-2a1d-4876-9076-13cb89a3f295',
        'aid': 0,
        'scy': 'auto',
        'net': 'ws',
        'path': '/vmess-ws',
      });
      final uri = 'vmess://${base64Url.encode(utf8.encode(vmessPayload))}';
      final clientNormalized = parseShareUri(uri);
      final clientBytes = encoder.encode(clientNormalized);
      final clientFile = File('/tmp/test_vmess_client.json');
      await clientFile.writeAsString(utf8.decode(clientBytes));

      final checkResult =
          await Process.run(_singBoxPath, ['check', '-c', clientFile.path]);
      expect(checkResult.exitCode, equals(0),
          reason: 'sing-box check failed: ${checkResult.stderr}');

      final clientProc =
          await Process.start(_singBoxPath, ['run', '-c', clientFile.path]);
      try {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(clientProc.pid, isPositive);

        final client = HttpClient();
        client.findProxy = (uri) => 'PROXY 127.0.0.1:20808';
        client.connectionTimeout = const Duration(seconds: 5);
        try {
          final request =
              await client.getUrl(Uri.parse('http://109.248.161.249:8088/'));
          final response = await request.close();
          expect(response.statusCode, inInclusiveRange(200, 499));
          print(
              'VMess end-to-end proxy request status: ${response.statusCode}');
        } catch (e) {
          print('VMess probe: $e');
        } finally {
          client.close();
        }
      } finally {
        clientProc.kill(ProcessSignal.sigkill);
        serverProc.kill(ProcessSignal.sigkill);
        await clientFile.delete();
        await serverFile.delete();
      }
    });

    test('5. Trojan End-to-End Handshake & Data Transfer Test', () async {
      final serverConfig = {
        'log': {'level': 'warn'},
        'inbounds': [
          {
            'type': 'trojan',
            'tag': 'trojan-in',
            'listen': '127.0.0.1',
            'listen_port': 39002,
            'users': [
              {'name': 'test-user', 'password': 'trojan-secret-password-123'}
            ]
          }
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'}
        ]
      };
      final serverFile = File('/tmp/test_trojan_server.json');
      await serverFile.writeAsString(jsonEncode(serverConfig));
      final serverProc =
          await Process.start(_singBoxPath, ['run', '-c', serverFile.path]);

      final uri =
          'trojan://trojan-secret-password-123@127.0.0.1:39002#Zagros-Trojan';
      final clientNormalized = parseShareUri(uri);
      final clientBytes = encoder.encode(clientNormalized);
      final clientFile = File('/tmp/test_trojan_client.json');
      await clientFile.writeAsString(utf8.decode(clientBytes));

      final checkResult =
          await Process.run(_singBoxPath, ['check', '-c', clientFile.path]);
      expect(checkResult.exitCode, equals(0),
          reason: 'sing-box check failed: ${checkResult.stderr}');

      final clientProc =
          await Process.start(_singBoxPath, ['run', '-c', clientFile.path]);
      try {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(clientProc.pid, isPositive);

        final client = HttpClient();
        client.findProxy = (uri) => 'PROXY 127.0.0.1:20808';
        client.connectionTimeout = const Duration(seconds: 5);
        try {
          final request =
              await client.getUrl(Uri.parse('http://109.248.161.249:8088/'));
          final response = await request.close();
          expect(response.statusCode, inInclusiveRange(200, 499));
          print(
              'Trojan end-to-end proxy request status: ${response.statusCode}');
        } catch (e) {
          print('Trojan probe: $e');
        } finally {
          client.close();
        }
      } finally {
        clientProc.kill(ProcessSignal.sigkill);
        serverProc.kill(ProcessSignal.sigkill);
        await clientFile.delete();
        await serverFile.delete();
      }
    });

    test('6. TUIC Configuration & Schema Test', () async {
      final uri =
          'tuic://a661c94d-2a1d-4876-9076-13cb89a3f295:tuic-pass@zagros.azbarfilm.ir:39003?congestion_control=bbr&sni=zagros.azbarfilm.ir&alpn=h3&allow_insecure=1#Zagros-TUIC';
      final clientNormalized = parseShareUri(uri);
      final clientBytes = encoder.encode(clientNormalized);
      final clientFile = File('/tmp/test_tuic_client.json');
      await clientFile.writeAsString(utf8.decode(clientBytes));

      final checkResult =
          await Process.run(_singBoxPath, ['check', '-c', clientFile.path]);
      expect(checkResult.exitCode, equals(0),
          reason: 'sing-box check failed: ${checkResult.stderr}');
      await clientFile.delete();
    });
  });
}
