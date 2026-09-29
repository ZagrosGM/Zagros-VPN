import 'dart:convert';
import 'dart:typed_data';

import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

const int maximumNativeConfigBytes = 256 * 1024;

/// Produces the shortest native-engine input that can be erased after IPC.
///
/// Clean-room protocol translation belonging to the adapter package.
/// Only explicitly supported fields are emitted; script hooks and external file
/// references are never forwarded to a privileged process.
final class NativeRuntimeConfigEncoder {
  NativeRuntimeConfigEncoder();

  /// DNS preset for the CURRENT encode() call. encode() is fully
  /// synchronous, so this transient field can never interleave between
  /// calls on the isolate.
  List<String> _dnsOverride = const <String>[];
  bool _fakeDns = false;

  Uint8List encode(
    NormalizedConfig config, {
    List<String> dnsServers = const <String>[],
    bool fakeDns = false,
  }) {
    _dnsOverride = dnsServers;
    _fakeDns = fakeDns;
    final protocol = config.protocol.toLowerCase();
    final engine = config.engine.toLowerCase();
    final isSingBoxEngine =
        engine == 'singbox' || engine == 'sing-box' || engine.isEmpty;

    final Uint8List bytes;
    try {
      bytes = _encodeFor(config, protocol, engine, isSingBoxEngine);
    } finally {
      _dnsOverride = const <String>[];
      _fakeDns = false;
    }
    if (bytes.isEmpty || bytes.length > maximumNativeConfigBytes) {
      bytes.fillRange(0, bytes.length, 0);
      throw const FormatException('native configuration size is invalid');
    }
    return bytes;
  }

  Uint8List _encodeFor(
    NormalizedConfig config,
    String protocol,
    String engine,
    bool isSingBoxEngine,
  ) {
    return switch (protocol) {
      'wireguard' when config.extensions['outbound'] is Map<String, Object?> =>
        _wrapSingBoxOutbound(
            config.extensions['outbound'] as Map<String, Object?>),
      'wireguard' when engine == 'wireguard' || isSingBoxEngine =>
        _encodeWireGuard(config),
      'vless' => _encodeVless(config),
      'vmess' => _encodeVmess(config),
      'trojan' => _encodeTrojan(config),
      'shadowsocks' || 'ss' => _encodeShadowsocks(config),
      'hysteria2' || 'hy2' => _encodeHysteria2(config),
      'tuic' => _encodeTuic(config),
      'anytls' => _encodeAnyTls(config),
      'ssh' => _encodeSsh(config),
      'openvpn' || 'ovpn' => _encodeOpenVpn(config),
      'softether' || 'sstp' || 'l2tp' || 'l2tp_raw' => _encodeSoftEther(config),
      'ikev2' when engine == 'system' => _encodeAppleOrSystemVpn(config),
      _ => throw UnsupportedError('unsupported native protocol'),
    };
  }

  Uint8List _wrapSingBoxOutbound(
    Map<String, Object?> outbound, {
    bool rejectUdp = false,
  }) {
    // f54 DNS-over-the-tunnel: several client outbounds are TCP-only
    // (ssh), so plain UDP :53 flows die inside the tunnel and the phone
    // cannot resolve anything. Sniffed DNS queries are answered by the
    // built-in resolver over DNS-over-TCP (works over every TCP-capable
    // protocol) using the app's DNS preset as the upstream. Verified live
    // against sing-box 1.12.4 (check + end-to-end UDP DNS through socks5).
    //
    // f56: the DNS upstream dial now carries an explicit `detour` so it is
    // carried through the tunnel outbound itself (proven ssh-only on VPS:
    // resolve + curl with ssh as the ONLY outbound). Without it the resolver
    // dial does not reliably traverse the tunnel on-device. Fake DNS moved
    // to the new-style fakeip server (ranges on the server, no legacy
    // `dns.fakeip` block): the legacy shape answers from a machinery that
    // never maps the fake IP back to the domain, so connections to
    // 198.18/15 were dialed literally through the outbound (observed on
    // device: "Network is unreachable" from the ssh server). With the
    // new-style server, sing-box 1.12.4 restores the domain for mixed
    // inbounds (verified live over ssh outbound).
    final dnsUpstream =
        _dnsOverride.isNotEmpty ? _dnsOverride.first : '1.1.1.1';
    final outboundTag = (outbound['tag'] as String?) ?? 'proxy';
    final routeRules = <Object?>[
      <String, Object?>{
        'protocol': 'dns',
        'action': 'hijack-dns',
      },
      if (rejectUdp)
        <String, Object?>{
          'network': 'udp',
          'action': 'reject',
        },
    ];
    final singBoxConfig = <String, Object?>{
      'log': <String, Object?>{
        'level': 'info',
        'timestamp': true,
      },
      'dns': _buildDnsModule(dnsUpstream, outboundTag),
      'inbounds': <Object?>[
        <String, Object?>{
          'type': 'mixed',
          'tag': 'mixed-in',
          'listen': '127.0.0.1',
          'listen_port': 20808,
          'sniff': true,
        },
      ],
      'outbounds': <Object?>[
        outbound,
        <String, Object?>{
          'type': 'direct',
          'tag': 'direct',
        },
      ],
      'route': <String, Object?>{
        'rules': routeRules,
      },
    };

    return Uint8List.fromList(utf8.encode(jsonEncode(singBoxConfig)));
  }

  /// DNS module: upstream over DNS-over-TCP, explicitly `detour`ed through
  /// the tunnel outbound (otherwise the resolver dial does not reliably
  /// traverse the tunnel on-device), plus an optional Fake DNS pool using
  /// the new-style fakeip server (ranges on the server itself — verified
  /// live against sing-box 1.12.4: the legacy `dns.fakeip` block answers
  /// queries but never maps the fake IP back to the domain for mixed
  /// inbounds). Sniffed DNS is hijacked via the first route rule (see
  /// _wrapSingBoxOutbound).
  Map<String, Object?> _buildDnsModule(String upstream, String detourTag) {
    final servers = <Object?>[
      <String, Object?>{
        'type': 'tcp',
        'tag': 'dns-upstream',
        'server': upstream,
        'detour': detourTag,
      },
    ];
    final module = <String, Object?>{'servers': servers};
    if (_fakeDns) {
      servers.add(<String, Object?>{
        'type': 'fakeip',
        'tag': 'dns-fakeip',
        'inet4_range': '198.18.0.0/15',
        'inet6_range': 'fc00::/18',
      });
      module['rules'] = <Object?>[
        <String, Object?>{
          'query_type': <Object?>['A', 'AAAA'],
          'server': 'dns-fakeip',
        },
      ];
    }
    return module;
  }

  Uint8List _encodeVless(NormalizedConfig config) {
    if (config.extensions['outbound'] is Map<String, Object?>) {
      return _wrapSingBoxOutbound(
        config.extensions['outbound'] as Map<String, Object?>,
      );
    }
    final endpoint = _singleEndpoint(config, 'VLESS');
    final uuid = _optionalCredential(config.credentials, 'id') ??
        _optionalCredential(config.credentials, 'uuid');
    if (uuid == null || !_safeUuid(uuid)) {
      throw const FormatException('VLESS UUID is invalid');
    }

    final options = config.options;
    final flow = _safeOption(options, 'flow');

    final outbound = <String, Object?>{
      'type': 'vless',
      'tag': 'proxy',
      'server': endpoint.host,
      'server_port': endpoint.port,
      'uuid': uuid,
    };

    if (flow != null && flow.isNotEmpty) {
      outbound['flow'] = flow;
    }

    _applyTransport(outbound, config, endpoint);
    _applyTls(outbound, config, endpoint);

    return _wrapSingBoxOutbound(outbound);
  }

  Uint8List _encodeVmess(NormalizedConfig config) {
    if (config.extensions['outbound'] is Map<String, Object?>) {
      return _wrapSingBoxOutbound(
        config.extensions['outbound'] as Map<String, Object?>,
      );
    }
    final endpoint = _singleEndpoint(config, 'VMess');
    final uuid = _optionalCredential(config.credentials, 'id') ??
        _optionalCredential(config.credentials, 'uuid');
    if (uuid == null || !_safeUuid(uuid)) {
      throw const FormatException('VMess UUID is invalid');
    }

    final options = config.options;
    final rawSecurity = _safeOption(options, 'security') ??
        _safeOption(options, 'scy') ??
        'auto';
    final security = rawSecurity.toLowerCase();

    final rawAlterId = options['aid'] ?? options['alterId'] ?? 0;
    final alterId = int.tryParse(rawAlterId.toString()) ?? 0;

    final outbound = <String, Object?>{
      'type': 'vmess',
      'tag': 'proxy',
      'server': endpoint.host,
      'server_port': endpoint.port,
      'uuid': uuid,
      'security': security,
      'alter_id': alterId,
      'authenticated_length': true,
    };

    _applyTransport(outbound, config, endpoint);
    _applyTls(outbound, config, endpoint);

    return _wrapSingBoxOutbound(outbound);
  }

  Uint8List _encodeTrojan(NormalizedConfig config) {
    if (config.extensions['outbound'] is Map<String, Object?>) {
      return _wrapSingBoxOutbound(
        config.extensions['outbound'] as Map<String, Object?>,
      );
    }
    final endpoint = _singleEndpoint(config, 'Trojan');
    final password = _optionalCredential(config.credentials, 'password') ??
        _optionalCredential(config.credentials, 'token');
    if (password == null || password.isEmpty) {
      throw const FormatException('Trojan password is required');
    }

    final outbound = <String, Object?>{
      'type': 'trojan',
      'tag': 'proxy',
      'server': endpoint.host,
      'server_port': endpoint.port,
      'password': password,
    };

    _applyTransport(outbound, config, endpoint);
    _applyTls(outbound, config, endpoint, defaultTls: true);

    return _wrapSingBoxOutbound(outbound);
  }

  Uint8List _encodeShadowsocks(NormalizedConfig config) {
    if (config.extensions['outbound'] is Map<String, Object?>) {
      return _wrapSingBoxOutbound(
        config.extensions['outbound'] as Map<String, Object?>,
      );
    }
    final endpoint = _singleEndpoint(config, 'Shadowsocks');
    final method = _optionalCredential(config.credentials, 'method') ??
        _safeOption(config.options, 'method') ??
        'aes-256-gcm';
    final password = _optionalCredential(config.credentials, 'password');
    if (password == null || password.isEmpty) {
      throw const FormatException('Shadowsocks password is required');
    }

    final outbound = <String, Object?>{
      'type': 'shadowsocks',
      'tag': 'proxy',
      'server': endpoint.host,
      'server_port': endpoint.port,
      'method': method,
      'password': password,
    };

    final plugin = _safeOption(config.options, 'plugin');
    final pluginOpts = _safeOption(config.options, 'plugin_opts') ??
        _safeOption(config.options, 'plugin-opts');
    if (plugin != null && plugin.isNotEmpty) {
      outbound['plugin'] = plugin;
      if (pluginOpts != null && pluginOpts.isNotEmpty) {
        outbound['plugin_opts'] = pluginOpts;
      }
    }

    return _wrapSingBoxOutbound(outbound);
  }

  Uint8List _encodeHysteria2(NormalizedConfig config) {
    if (config.extensions['outbound'] is Map<String, Object?>) {
      return _wrapSingBoxOutbound(
        config.extensions['outbound'] as Map<String, Object?>,
      );
    }
    final endpoint = _singleEndpoint(config, 'Hysteria 2');
    final password = _optionalCredential(config.credentials, 'password') ??
        _optionalCredential(config.credentials, 'auth') ??
        _optionalCredential(config.credentials, 'token');
    if (password == null || password.isEmpty) {
      throw const FormatException('Hysteria 2 auth password is required');
    }

    final outbound = <String, Object?>{
      'type': 'hysteria2',
      'tag': 'proxy',
      'server': endpoint.host,
      'server_port': endpoint.port,
      'password': password,
    };

    final options = config.options;
    final upMbps = options['upmbps'] ?? options['up_mbps'] ?? options['up'];
    if (upMbps != null) {
      final parsed = int.tryParse(upMbps.toString());
      if (parsed != null && parsed > 0) outbound['up_mbps'] = parsed;
    }
    final downMbps =
        options['downmbps'] ?? options['down_mbps'] ?? options['down'];
    if (downMbps != null) {
      final parsed = int.tryParse(downMbps.toString());
      if (parsed != null && parsed > 0) outbound['down_mbps'] = parsed;
    }

    final obfsType = _safeOption(options, 'obfs') ??
        _safeOption(options, 'obfs-type') ??
        _safeOption(options, 'obfs_type');
    final obfsPassword = _safeOption(options, 'obfs-password') ??
        _safeOption(options, 'obfs_password') ??
        _safeOption(options, 'obfs_param');
    if (obfsType != null && obfsType.isNotEmpty && obfsPassword != null) {
      outbound['obfs'] = <String, Object?>{
        'type': obfsType,
        'password': obfsPassword,
      };
    }

    _applyTls(outbound, config, endpoint, defaultTls: true);

    return _wrapSingBoxOutbound(outbound);
  }

  Uint8List _encodeTuic(NormalizedConfig config) {
    if (config.extensions['outbound'] is Map<String, Object?>) {
      return _wrapSingBoxOutbound(
        config.extensions['outbound'] as Map<String, Object?>,
      );
    }
    final endpoint = _singleEndpoint(config, 'TUIC');
    final uuid = _optionalCredential(config.credentials, 'uuid') ??
        _optionalCredential(config.credentials, 'id') ??
        _optionalCredential(config.credentials, 'username');
    final password = _optionalCredential(config.credentials, 'password') ??
        _optionalCredential(config.credentials, 'token');
    if (uuid == null || !_safeUuid(uuid)) {
      throw const FormatException('TUIC UUID is invalid');
    }
    if (password == null || password.isEmpty) {
      throw const FormatException('TUIC password is required');
    }

    final options = config.options;
    final cc = _safeOption(options, 'congestion_control') ??
        _safeOption(options, 'congestion_controller') ??
        _safeOption(options, 'cc') ??
        'bbr';
    final udpMode = _safeOption(options, 'udp_relay_mode') ??
        _safeOption(options, 'udp_mode') ??
        'native';
    final zeroRtt = options['zero_rtt_handshake'] == true ||
        options['allow_insecure'] == true ||
        options['0rtt'] == '1';

    final outbound = <String, Object?>{
      'type': 'tuic',
      'tag': 'proxy',
      'server': endpoint.host,
      'server_port': endpoint.port,
      'uuid': uuid,
      'password': password,
      'congestion_control': cc,
      'udp_relay_mode': udpMode,
      'zero_rtt_handshake': zeroRtt,
    };

    _applyTls(outbound, config, endpoint, defaultTls: true);

    return _wrapSingBoxOutbound(outbound);
  }

  Uint8List _encodeAnyTls(NormalizedConfig config) {
    if (config.extensions['outbound'] is Map<String, Object?>) {
      return _wrapSingBoxOutbound(
        config.extensions['outbound'] as Map<String, Object?>,
      );
    }
    final endpoint = _singleEndpoint(config, 'AnyTLS');
    final password = _optionalCredential(config.credentials, 'password') ??
        _optionalCredential(config.credentials, 'token') ??
        _optionalCredential(config.credentials, 'auth');
    if (password == null || password.isEmpty) {
      throw const FormatException('AnyTLS password is required');
    }

    final outbound = <String, Object?>{
      'type': 'anytls',
      'tag': 'proxy',
      'server': endpoint.host,
      'server_port': endpoint.port,
      'password': password,
    };

    _applyTls(outbound, config, endpoint, defaultTls: true);

    return _wrapSingBoxOutbound(outbound);
  }

  Uint8List _encodeSsh(NormalizedConfig config) {
    if (config.extensions['outbound'] is Map<String, Object?>) {
      return _wrapSingBoxOutbound(
        config.extensions['outbound'] as Map<String, Object?>,
        rejectUdp: true,
      );
    }
    final endpoint = _singleEndpoint(config, 'SSH');
    final username = _optionalCredential(config.credentials, 'user') ??
        _optionalCredential(config.credentials, 'username') ??
        'root';
    final password = _optionalCredential(config.credentials, 'password') ?? '';

    final outbound = <String, Object?>{
      'type': 'ssh',
      'tag': 'proxy',
      'server': endpoint.host,
      'server_port': endpoint.port,
      'user': username,
      if (password.isNotEmpty) 'password': password,
    };

    return _wrapSingBoxOutbound(outbound, rejectUdp: true);
  }

  Uint8List _encodeOpenVpn(NormalizedConfig config) {
    String profile = '';
    if (config.extensions['profile'] is String &&
        (config.extensions['profile'] as String).trim().isNotEmpty) {
      profile = config.extensions['profile'] as String;
    } else {
      final sb = StringBuffer();
      sb.writeln('client');
      sb.writeln('dev tun');
      for (final endpoint in config.endpoints) {
        final proto = endpoint.transport ?? 'udp';
        sb.writeln('remote ${endpoint.host} ${endpoint.port} $proto');
      }
      for (final entry in config.options.entries) {
        if (entry.value is bool && entry.value == true) {
          sb.writeln(entry.key);
        } else if (entry.value is List) {
          for (final item in entry.value as List) {
            sb.writeln('${entry.key} $item');
          }
        } else if (entry.value != null && entry.value != false) {
          sb.writeln('${entry.key} ${entry.value}');
        }
      }
      final inlines = config.extensions['inline_blocks'];
      if (inlines is Map) {
        for (final entry in inlines.entries) {
          sb.writeln('<${entry.key}>');
          sb.write(entry.value);
          if (!entry.value.toString().endsWith('\n')) {
            sb.writeln();
          }
          sb.writeln('</${entry.key}>');
        }
      }
      profile = sb.toString();
    }

    final username = _optionalCredential(config.credentials, 'username') ?? '';
    final password = _optionalCredential(config.credentials, 'password') ?? '';
    final payload = <String, Object?>{
      'protocol': 'openvpn',
      'profile': profile,
      'username': username,
      'password': password,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(payload)));
  }

  Uint8List _encodeSoftEther(NormalizedConfig config) {
    final endpoint =
        config.endpoints.isNotEmpty ? config.endpoints.first : null;
    final username = _optionalCredential(config.credentials, 'username') ?? '';
    final password = _optionalCredential(config.credentials, 'password') ?? '';
    final payload = <String, Object?>{
      'protocol': 'softether',
      'server': endpoint?.host ?? '',
      'port': endpoint?.port ?? 443,
      'username': username,
      'password': password,
      ...config.options,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(payload)));
  }

  void _applyTransport(
    Map<String, Object?> outbound,
    NormalizedConfig config,
    VpnEndpoint endpoint,
  ) {
    final options = config.options;
    final transportType = (_safeOption(options, 'type') ??
            _safeOption(options, 'net') ??
            _safeOption(options, 'transport') ??
            endpoint.transport ??
            'tcp')
        .toLowerCase();

    if (transportType == 'ws' || transportType == 'websocket') {
      final wsPath = _safeOption(options, 'path') ?? '/';
      final wsHost = _safeOption(options, 'host') ??
          _safeOption(options, 'sni') ??
          endpoint.host;
      outbound['transport'] = <String, Object?>{
        'type': 'ws',
        'path': wsPath,
        'headers': <String, String>{'Host': wsHost},
      };
    } else if (transportType == 'grpc') {
      final serviceName = _safeOption(options, 'serviceName') ??
          _safeOption(options, 'service_name') ??
          '';
      outbound['transport'] = <String, Object?>{
        'type': 'grpc',
        'service_name': serviceName,
      };
    } else if (transportType == 'httpupgrade') {
      final huPath = _safeOption(options, 'path') ?? '/';
      final huHost = _safeOption(options, 'host') ??
          _safeOption(options, 'sni') ??
          endpoint.host;
      outbound['transport'] = <String, Object?>{
        'type': 'httpupgrade',
        'path': huPath,
        'host': huHost,
      };
    }
  }

  void _applyTls(
    Map<String, Object?> outbound,
    NormalizedConfig config,
    VpnEndpoint endpoint, {
    bool defaultTls = false,
  }) {
    final options = config.options;
    final rawSecurity = _safeOption(options, 'security') ??
        _safeOption(options, 'tls') ??
        (defaultTls ? 'tls' : 'none');
    final security = rawSecurity.toLowerCase();

    if (security == 'reality') {
      final sni = _safeOption(options, 'sni') ??
          _safeOption(options, 'server_name') ??
          endpoint.host;
      final fp = _safeOption(options, 'fp') ?? 'chrome';
      final rawPbk =
          _safeOption(options, 'pbk') ?? _safeOption(options, 'public_key');
      final sid =
          _safeOption(options, 'sid') ?? _safeOption(options, 'short_id') ?? '';
      if (rawPbk == null || rawPbk.isEmpty) {
        throw const FormatException('Reality public key is missing');
      }
      // Sing-box reality requires unpadded base64url format (RawURLEncoding)
      final pbk =
          rawPbk.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
      outbound['tls'] = <String, Object?>{
        'enabled': true,
        'server_name': sni,
        'utls': <String, Object?>{
          'enabled': true,
          'fingerprint': fp,
        },
        'reality': <String, Object?>{
          'enabled': true,
          'public_key': pbk,
          'short_id': sid,
        },
      };
    } else if (security == 'tls' || defaultTls) {
      final sni = _safeOption(options, 'sni') ??
          _safeOption(options, 'server_name') ??
          _safeOption(options, 'host') ??
          endpoint.host;
      final fp = _safeOption(options, 'fp') ?? 'chrome';
      final alpn = _safeOption(options, 'alpn');
      final insecure = options['allowInsecure'] == '1' ||
          options['allow_insecure'] == true ||
          options['insecure'] == true;

      outbound['tls'] = <String, Object?>{
        'enabled': true,
        'server_name': sni,
        'insecure': insecure,
        'utls': <String, Object?>{
          'enabled': true,
          'fingerprint': fp,
        },
        if (alpn != null && alpn.isNotEmpty) 'alpn': alpn.split(','),
      };
    }
  }

  VpnEndpoint _singleEndpoint(NormalizedConfig config, String protocolName) {
    if (config.endpoints.length != 1) {
      throw FormatException('$protocolName requires exactly one endpoint');
    }
    final endpoint = config.endpoints.single;
    _safeScalar(endpoint.host, '$protocolName server');
    if (endpoint.host.isEmpty || endpoint.port < 1 || endpoint.port > 65535) {
      throw FormatException('$protocolName endpoint is invalid');
    }
    return endpoint;
  }

  bool _safeUuid(String value) =>
      RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
          .hasMatch(value) ||
      RegExp(r'^[0-9a-zA-Z_-]{16,64}$').hasMatch(value);

  Uint8List _encodeWireGuard(NormalizedConfig config) {
    final interface = _stringMap(config.extensions['interface'], 'interface');
    final peerValues = config.extensions['peers'];
    if (peerValues is! List<Object?> ||
        peerValues.isEmpty ||
        peerValues.length > 64) {
      throw const FormatException('WireGuard peers are invalid');
    }
    _rejectUnknown(
        interface,
        const <String>{
          'privatekey',
          'address',
          'dns',
          'listenport',
          'mtu',
        },
        'WireGuard Interface');
    final privateKey = _single(interface, 'privatekey', required: true)!;
    _requireKey(privateKey, 'WireGuard private key');

    final output = StringBuffer()
      ..writeln('[Interface]')
      ..writeln('PrivateKey = $privateKey');
    _writeMany(output, 'Address', interface['address']);
    _writeMany(output, 'DNS', interface['dns']);
    _writeOptionalInteger(
      output,
      'ListenPort',
      interface['listenport'],
      1,
      65535,
    );
    _writeOptionalInteger(output, 'MTU', interface['mtu'], 576, 65535);

    for (final peerValue in peerValues) {
      final peer = _stringMap(peerValue, 'peer');
      _rejectUnknown(
          peer,
          const <String>{
            'publickey',
            'presharedkey',
            'allowedips',
            'endpoint',
            'persistentkeepalive',
          },
          'WireGuard Peer');
      final publicKey = _single(peer, 'publickey', required: true)!;
      _requireKey(publicKey, 'WireGuard peer public key');
      final allowedIps = _values(peer['allowedips']);
      if (allowedIps.isEmpty) {
        throw const FormatException('WireGuard AllowedIPs are required');
      }
      output
        ..writeln()
        ..writeln('[Peer]')
        ..writeln('PublicKey = $publicKey');
      final presharedKey = _single(peer, 'presharedkey');
      if (presharedKey != null) {
        _requireKey(presharedKey, 'WireGuard preshared key');
        output.writeln('PresharedKey = $presharedKey');
      }
      _writeMany(output, 'AllowedIPs', peer['allowedips']);
      final endpoint = _single(peer, 'endpoint', required: true)!;
      _safeScalar(endpoint, 'WireGuard endpoint');
      output.writeln('Endpoint = $endpoint');
      _writeOptionalInteger(
        output,
        'PersistentKeepalive',
        peer['persistentkeepalive'],
        0,
        65535,
      );
    }
    return Uint8List.fromList(utf8.encode(output.toString()));
  }

  Uint8List _encodeAppleOrSystemVpn(NormalizedConfig config) {
    if (config.endpoints.length != 1) {
      throw const FormatException('system VPN requires exactly one endpoint');
    }
    final endpoint = config.endpoints.single;
    _safeScalar(endpoint.host, 'VPN endpoint');
    if (endpoint.host.isEmpty ||
        utf8.encode(endpoint.host).length > 253 ||
        endpoint.port != 500) {
      throw const FormatException(
        'system IKEv2 requires the standard port; NAT-T is negotiated by the OS',
      );
    }
    final credentials = config.credentials;
    final username = _optionalCredential(credentials, 'username') ??
        _optionalCredential(credentials, 'account');
    final password = _optionalCredential(credentials, 'password');
    final sharedSecret = _optionalCredential(credentials, 'preshared_key') ??
        _optionalCredential(credentials, 'shared_secret');
    if ((username == null) != (password == null)) {
      throw const FormatException(
        'system VPN username/password must be paired',
      );
    }
    if (password == null && sharedSecret == null) {
      throw const FormatException('system VPN credentials are missing');
    }
    final localIdentifier = _safeOption(config.options, 'local_identifier');
    final payload = <String, Object?>{
      'version': 1,
      'server': endpoint.host,
      'port': endpoint.port,
      if (username != null) 'username': username,
      if (password != null) 'password': password,
      if (sharedSecret != null) 'shared_secret': sharedSecret,
      'remote_identifier':
          _safeOption(config.options, 'remote_identifier') ?? endpoint.host,
      if (localIdentifier != null) 'local_identifier': localIdentifier,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(payload)));
  }

  String? _optionalCredential(Map<String, Object?> values, String key) {
    final value = values[key];
    if (value == null) return null;
    if (value is! String || value.isEmpty || value.length > 4096) {
      throw FormatException('$key is invalid');
    }
    _safeScalar(value, key);
    return value;
  }

  String? _safeOption(Map<String, Object?> values, String key) {
    final value = values[key];
    if (value == null) return null;
    if (value is! String || value.isEmpty || value.length > 1024) {
      throw FormatException('$key is invalid');
    }
    _safeScalar(value, key);
    return value;
  }

  Map<String, Object?> _stringMap(Object? value, String name) {
    if (value is! Map<Object?, Object?>) {
      throw FormatException('WireGuard $name is invalid');
    }
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw FormatException('WireGuard $name key is invalid');
      }
      result[(entry.key! as String).toLowerCase()] = entry.value;
    }
    return result;
  }

  void _rejectUnknown(
    Map<String, Object?> values,
    Set<String> allowed,
    String section,
  ) {
    final unknown = values.keys.where((key) => !allowed.contains(key));
    if (unknown.isNotEmpty) {
      throw FormatException('$section contains an unsupported directive');
    }
  }

  String? _single(
    Map<String, Object?> values,
    String key, {
    bool required = false,
  }) {
    final items = _values(values[key]);
    if (items.isEmpty) {
      if (required) throw FormatException('WireGuard $key is required');
      return null;
    }
    if (items.length != 1) {
      throw FormatException('WireGuard $key must occur once');
    }
    return items.single;
  }

  List<String> _values(Object? value) {
    if (value == null) return const <String>[];
    final source = value is List<Object?> ? value : <Object?>[value];
    if (source.isEmpty || source.length > 128) {
      throw const FormatException('WireGuard value count is invalid');
    }
    final output = <String>[];
    for (final item in source) {
      if (item is! String || item.isEmpty || item.length > 4096) {
        throw const FormatException('WireGuard value is invalid');
      }
      for (final part in item.split(',')) {
        final trimmed = part.trim();
        if (trimmed.isEmpty) {
          throw const FormatException('WireGuard value is empty');
        }
        _safeScalar(trimmed, 'WireGuard value');
        output.add(trimmed);
      }
    }
    return output;
  }

  void _writeMany(StringBuffer output, String name, Object? value) {
    final items = _values(value);
    if (items.isNotEmpty) output.writeln('$name = ${items.join(', ')}');
  }

  void _writeOptionalInteger(
    StringBuffer output,
    String name,
    Object? value,
    int minimum,
    int maximum,
  ) {
    if (value == null) return;
    final text = value.toString();
    final parsed = int.tryParse(text);
    if (parsed == null || parsed < minimum || parsed > maximum) {
      throw FormatException('WireGuard $name is invalid');
    }
    output.writeln('$name = $parsed');
  }

  void _requireKey(String value, String name) {
    Uint8List? decoded;
    try {
      decoded = base64.decode(value);
      if (decoded.length != 32) throw const FormatException();
    } on FormatException {
      throw FormatException('$name is invalid');
    } finally {
      final toClear = decoded;
      if (toClear != null) toClear.fillRange(0, toClear.length, 0);
    }
  }

  void _safeScalar(String value, String name) {
    if (value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw FormatException('$name contains control characters');
    }
  }
}
