import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:tunnel_interface/tunnel_interface.dart';
import 'package:zagros_vpn/src/account/white_label_service.dart';
import 'package:zagros_vpn/src/config/product_configuration.dart';
import 'package:zagros_vpn/src/storage/secure_storage.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import 'fixtures.dart';

Map<String, Object?> testTokens({
  String access = 'test-access-token',
  String refresh = 'test-refresh-token',
  DateTime? accessExpires,
  DateTime? refreshExpires,
}) => <String, Object?>{
  'access_token': access,
  'access_expires_at': (accessExpires ?? DateTime.utc(2030, 1, 1))
      .toIso8601String(),
  'refresh_token': refresh,
  'refresh_expires_at': (refreshExpires ?? DateTime.utc(2030, 1, 2))
      .toIso8601String(),
  'token_type': 'Bearer',
};

Map<String, Object?> testEnrollResult({String deviceId = 'device-1'}) =>
    <String, Object?>{
      'device_id': deviceId,
      'device_key_fingerprint': 'fingerprint-1',
      'tokens': testTokens(),
    };

Map<String, Object?> testProfile({String username = 'partner-user'}) =>
    <String, Object?>{
      'username': username,
      'status': 'active',
      'online': true,
      'used_bytes': 30,
      'data_limit_bytes': 100,
      'remaining_bytes': 70,
      'expire_at': DateTime.utc(2030, 6, 1).toIso8601String(),
      'application': <String, Object?>{
        'application_id': 'application-1',
        'name': 'Partner',
        'default_lang': 'en',
        'branding': <String, Object?>{},
      },
    };

Map<String, Object?> testConfigEntry({
  String? configId = 'cfg-1',
  String coreId = 'core-1',
  String protocol = 'wireguard',
  String engine = 'wireguard',
  String displayName = 'Germany 01',
  String status = 'active',
}) => <String, Object?>{
  'config_id': configId,
  'core_id': coreId,
  'protocol': protocol,
  'engine': engine,
  'display_name': displayName,
  'status': status,
};

Map<String, Object?> testUsage() => <String, Object?>{
  'used_bytes': 30,
  'uplink_bytes': 10,
  'downlink_bytes': 20,
  'data_limit_bytes': 100,
  'remaining_bytes': 70,
  'expire_at': DateTime.utc(2030, 6, 1).toIso8601String(),
  'active_connections': 1,
  'as_of': DateTime.utc(2026, 9, 8).toIso8601String(),
};

Map<String, Object?> testConnection({
  String connectionId = 'conn-1',
  String configId = 'cfg-1',
}) => <String, Object?>{
  'connection_id': connectionId,
  'config_id': configId,
  'core_id': 'core-1',
  'protocol': 'wireguard',
  'desired_status': 'active',
  'observed_status': 'active',
  'target': 'node',
  'teardown_capability': 'targeted',
  'not_after': DateTime.utc(2030, 1, 1).toIso8601String(),
};

/// Fake HTTP seam under the REAL SDK stack (real signing, real parsing).
/// Every request must carry the signed Application headers or the test
/// fails loudly.
class FakeApiTransport implements ApiTransport {
  FakeApiTransport({this.applicationId = 'application-1'}) {
    _installDefaults();
  }

  final String applicationId;
  final List<ApiRequest> requests = <ApiRequest>[];
  final Map<String, Future<ApiResponse> Function(ApiRequest)> handlers =
      <String, Future<ApiResponse> Function(ApiRequest)>{};

  static ApiResponse ok(Map<String, Object?> json) => ApiResponse(
    statusCode: 200,
    headers: const <String, String>{},
    body: Uint8List.fromList(utf8.encode(jsonEncode(json))),
  );

  static ApiResponse failure(int status, String code, String message) =>
      ApiResponse(
        statusCode: status,
        headers: const <String, String>{},
        body: Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, Object?>{'error': code, 'message': message}),
          ),
        ),
      );

  void _installDefaults() {
    handlers['POST /api/application/v1/devices/enroll'] = (request) async =>
        ok(testEnrollResult());
    handlers['POST /api/application/v1/auth/login'] = (request) async =>
        ok(testTokens());
    handlers['POST /api/application/v1/auth/refresh'] = (request) async =>
        ok(testTokens());
    handlers['POST /api/application/v1/auth/logout'] = (request) async =>
        ok(<String, Object?>{});
    handlers['GET /api/application/v1/user/profile'] = (request) async =>
        ok(testProfile());
    handlers['GET /api/application/v1/devices'] = (request) async =>
        ok(<String, Object?>{'devices': <Object?>[]});
    handlers['GET /api/application/v1/configs'] = (request) async =>
        ok(<String, Object?>{
          'configs': <Object?>[
            testConfigEntry(),
            testConfigEntry(
              configId: 'cfg-2',
              protocol: 'vless',
              engine: 'xray',
              displayName: 'Netherlands 02',
            ),
            testConfigEntry(
              configId: null,
              protocol: 'pptp',
              engine: '',
              displayName: 'Legacy 03',
              status: 'suspended',
            ),
          ],
        });
    handlers['GET /api/application/v1/connections/status'] = (request) async =>
        ok(<String, Object?>{'connections': <Object?>[]});
    handlers['GET /api/application/v1/usage/summary'] = (request) async =>
        ok(testUsage());
    handlers['POST /api/application/v1/connections/start'] = (request) async =>
        ok(testConnection());
  }

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    if (request.headers['x-zagros-application-id'] != applicationId ||
        (request.headers['x-zagros-signature'] ?? '').isEmpty ||
        (request.headers['x-zagros-nonce'] ?? '').isEmpty ||
        int.tryParse(request.headers['x-zagros-timestamp'] ?? '') == null) {
      throw StateError(
        'unsigned application request: ${request.method} ${request.path}',
      );
    }
    requests.add(request);
    final handler = handlers['${request.method} ${request.path}'];
    if (handler != null) return handler(request);
    if (request.method == 'GET' &&
        request.path.startsWith('/api/application/v1/configs/')) {
      throw StateError('config consume was not enabled for this test');
    }
    if (request.method == 'POST' &&
        request.path.endsWith('/stop') &&
        request.path.contains('/connections/')) {
      return ok(testConnection());
    }
    throw StateError('unexpected request: ${request.method} ${request.path}');
  }

  bool get sawStart => requests.any(
    (request) =>
        request.method == 'POST' &&
        request.path == '/api/application/v1/connections/start',
  );

  bool get sawConsume => requests.any(
    (request) =>
        request.method == 'GET' &&
        request.path.startsWith('/api/application/v1/configs/'),
  );

  Map<String, Object?> bodyOf(ApiRequest request) =>
      jsonDecode(utf8.decode(request.body)) as Map<String, Object?>;
}

/// Real SDK service (real auth/API/signing/identity) over [FakeApiTransport].
class WhiteLabelTestStack {
  WhiteLabelTestStack._({
    required this.configuration,
    required this.backend,
    required this.stores,
    required this.transport,
    required this.service,
  });

  static Future<WhiteLabelTestStack> create({
    FakeApiTransport? transport,
    Map<String, String>? values,
  }) async {
    final configuration = ProductConfiguration.fromValues(
      values ?? whiteLabelValues(),
    );
    final backend = MemorySecureBackend();
    final stores = ClientSecureStores(
      backend: backend,
      namespace: 'zagros.whitelabel',
    );
    final deviceIdentity = await DeviceIdentityManager(stores.values)
        .loadOrCreate();
    final effectiveTransport = transport ?? FakeApiTransport();
    final api = ApplicationApi(
      executor: SignedRequestExecutor(
        transport: effectiveTransport,
        application: configuration.applicationIdentity!,
        deviceKeyPair: deviceIdentity.keyPair,
      ),
      deviceIdentity: deviceIdentity,
    );
    return WhiteLabelTestStack._(
      configuration: configuration,
      backend: backend,
      stores: stores,
      transport: effectiveTransport,
      service: WhiteLabelService.test(
        api: api,
        auth: ApplicationAuthController(
          api: api,
          tokenStorage: stores.tokens,
          identityStorage: stores.values,
        ),
        application: configuration.applicationIdentity!,
        deviceIdentity: deviceIdentity,
      ),
    );
  }

  final ProductConfiguration configuration;
  final MemorySecureBackend backend;
  final ClientSecureStores stores;
  final FakeApiTransport transport;
  final WhiteLabelService service;
}

class FakeTunnelAdapter implements TunnelAdapter {
  FakeTunnelAdapter({
    this.protocols = const <String>{'wireguard'},
    this.unavailableReasons = const <String, String>{},
    this.response = const TunnelSnapshot(
      state: TunnelState.connecting,
      sequence: 1,
    ),
    this.connectError,
    this.disconnectError,
  });

  final StreamController<TunnelSnapshot> events =
      StreamController<TunnelSnapshot>.broadcast(sync: true);
  final Set<String> protocols;
  final Map<String, String> unavailableReasons;
  TunnelSnapshot response;
  Object? connectError;
  Object? disconnectError;
  TunnelConnectRequest? request;
  final List<String> disconnectReasons = <String>[];

  @override
  Future<TunnelCapabilities> capabilities() async => TunnelCapabilities(
    platform: 'widget-test',
    protocols: protocols,
    canProtectEntireDevice: true,
    canReportTraffic: false,
    unavailableReasons: unavailableReasons,
  );

  @override
  Future<TunnelSnapshot> connect(TunnelConnectRequest request) async {
    this.request = request;
    final error = connectError;
    if (error != null) throw error;
    return response;
  }

  @override
  Future<TunnelSnapshot> current() async => const TunnelSnapshot.disconnected();

  @override
  Future<TunnelSnapshot> disconnect({required String reason}) async {
    disconnectReasons.add(reason);
    final error = disconnectError;
    if (error != null) throw error;
    return const TunnelSnapshot(state: TunnelState.disconnected, sequence: 9);
  }

  @override
  Future<void> dispose() => events.close();

  @override
  Stream<TunnelSnapshot> get snapshots => events.stream;
}
