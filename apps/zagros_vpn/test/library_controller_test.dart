import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_interface/tunnel_interface.dart';
import 'package:zagros_vpn/src/config/product_configuration.dart';
import 'package:zagros_vpn/src/library/library_controller.dart';
import 'package:zagros_vpn/src/storage/secure_storage.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import 'support/fixtures.dart';

const _link =
    'vless://00000000-0000-0000-0000-000000000001@vpn.example:443?security=tls&type=tcp#Primary';

class NoopSubscriptionClient implements OfficialSubscriptionClient {
  @override
  void close() {}

  @override
  Future<OfficialSubscriptionDocument> fetch(
    Uri uri, {
    required String deviceId,
    String? etag,
    String? lastModified,
  }) =>
      throw UnimplementedError();
}

class RecordingTunnelAdapter implements TunnelAdapter {
  final StreamController<TunnelSnapshot> events =
      StreamController<TunnelSnapshot>.broadcast(sync: true);
  TunnelConnectRequest? request;
  String? disconnectReason;
  TunnelSnapshot response = const TunnelSnapshot(
    state: TunnelState.connecting,
    sequence: 1,
  );

  @override
  Future<TunnelCapabilities> capabilities() async => TunnelCapabilities(
        platform: 'widget-test',
        protocols: <String>{'vless'},
        canProtectEntireDevice: true,
        canReportTraffic: false,
      );

  @override
  Future<TunnelSnapshot> connect(TunnelConnectRequest request) async {
    this.request = request;
    return response;
  }

  @override
  Future<TunnelSnapshot> current() async => const TunnelSnapshot.disconnected();

  @override
  Future<TunnelSnapshot> disconnect({required String reason}) async {
    disconnectReason = reason;
    return const TunnelSnapshot(state: TunnelState.disconnected, sequence: 4);
  }

  @override
  Future<void> dispose() => events.close();

  @override
  Stream<TunnelSnapshot> get snapshots => events.stream;
}

void main() {
  test(
    'controller never invents a connection when adapter is absent',
    () async {
      final fixture = await _fixture();
      final controller = LibraryController(
        configuration: fixture.configuration,
        repository: fixture.repository,
        tunnelAdapter: null,
      );
      await controller.load();

      final result = await controller.connect(
        controller.catalog.profiles.single.configs.single,
      );

      expect(result, OfficialConnectResult.adapterUnavailable);
      controller.dispose();
    },
  );

  test(
      'controller passes the SDK model to TunnelAdapter without claiming early success',
      () async {
    final fixture = await _fixture();
    final adapter = RecordingTunnelAdapter();
    final controller = LibraryController(
      configuration: fixture.configuration,
      repository: fixture.repository,
      tunnelAdapter: adapter,
    );
    await controller.load();

    var result = await controller.connect(
      controller.catalog.profiles.single.configs.single,
    );
    expect(result, OfficialConnectResult.requestAccepted);
    expect(adapter.request?.config.protocol, 'vless');
    expect(adapter.request?.productMode, ClientProductMode.official);

    adapter.response = const TunnelSnapshot(
      state: TunnelState.connected,
      sequence: 2,
    );
    result = await controller.connect(
      controller.catalog.profiles.single.configs.single,
    );
    expect(result, OfficialConnectResult.connected);

    final authoritative = TunnelSnapshot(
      state: TunnelState.connected,
      sequence: 3,
      connectionId: adapter.request!.connectionId,
      protocol: 'vless',
      connectedAt: DateTime.utc(2026),
      uplinkBytes: 10,
      downlinkBytes: 20,
    );
    adapter.events.add(authoritative);
    expect(controller.tunnelSnapshot, same(authoritative));
    expect(controller.adapterAvailable, isTrue);

    expect(await controller.disconnect(), isTrue);
    expect(adapter.disconnectReason, 'user_requested');
    expect(controller.tunnelSnapshot.state, TunnelState.disconnected);

    controller.dispose();
    await adapter.dispose();
  });
}

class _ControllerFixture {
  const _ControllerFixture(this.configuration, this.repository);

  final ProductConfiguration configuration;
  final OfficialProfileRepository repository;
}

Future<_ControllerFixture> _fixture() async {
  final configuration = ProductConfiguration.fromValues(const <String, String>{
    'product_mode': 'official',
  });
  final stores = ClientSecureStores(
    backend: MemorySecureBackend(),
    namespace: 'zagros.official',
  );
  final repository = OfficialProfileRepository(
    policy: configuration.policy,
    store: SecureOfficialCatalogStore(
      policy: configuration.policy,
      storage: stores.values,
    ),
    subscriptionClient: NoopSubscriptionClient(),
    deviceIdManager: OfficialDeviceIdManager(stores.values),
    idGenerator: () => 'profile_controller_test',
  );
  await repository.addManual(name: 'Manual', rawSource: _link);
  return _ControllerFixture(configuration, repository);
}
