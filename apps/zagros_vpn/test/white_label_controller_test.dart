import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_interface/tunnel_interface.dart';
import 'package:zagros_vpn/src/account/white_label_controller.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import 'support/fakes.dart';
import 'support/fixtures.dart';

class _ManualScheduler implements ActionScheduler {
  const _ManualScheduler();

  @override
  ScheduledAction schedule(Duration delay, void Function() action) =>
      _ManualAction();
}

class _ManualAction implements ScheduledAction {
  @override
  void cancel() {}
}

class _ControllerFixture {
  _ControllerFixture._({required this.stack, required this.session});

  static Future<_ControllerFixture> create() async {
    final stack = await WhiteLabelTestStack.create(
      values: whiteLabelValues()..['default_locale'] = 'en',
    );
    final session = await stack.service.auth.enroll(
      credentials: const ApplicationCredentials(
        username: 'partner-user',
        password: 'secret-password',
      ),
      activationTicket: 'zgat1.test.ticket',
    );
    return _ControllerFixture._(stack: stack, session: session);
  }

  final WhiteLabelTestStack stack;
  final ApplicationSession session;

  AcquireWhiteLabelConfig stubAcquire(
    void Function(AcquiredConfig acquired) onAcquire,
  ) => (session, selector) async {
    final acquired = _acquired(stack, session);
    onAcquire(acquired);
    return acquired;
  };

  AcquiredConfig _acquired(
    WhiteLabelTestStack stack,
    ApplicationSession session,
  ) {
    const envelope = ConfigEnvelope(
      version: 1,
      algorithm: 'X25519-HKDF-AES-256-GCM',
      applicationId: 'application-1',
      applicationKeyId: 'config-key-1',
      signingKeyId: 'signing-key-1',
      deviceId: 'device-1',
      configId: 'cfg-1',
      connectionId: 'conn-1',
      coreId: 'core-1',
      protocol: 'wireguard',
      engine: 'wireguard',
      issuedAt: 0,
      notBefore: 0,
      expiresAt: 4102444800,
      salt: 'salt',
      ephemeralPublicKey: 'eph',
      nonce: 'nonce',
      ciphertext: 'ct',
      signature: 'sig',
    );
    return AcquiredConfig(
      selector: ConfigSelector.fromJson(testConfigEntry()),
      opened: OpenedConfig(
        envelope: envelope,
        plaintext: const <int>[1, 2, 3, 4, 5, 6, 7, 8],
      ),
      normalized: NormalizedConfig(
        protocol: 'wireguard',
        engine: 'wireguard',
        displayName: 'Germany 01',
        sourceFormat: ConfigSourceFormat.fields,
        endpoints: const <VpnEndpoint>[
          VpnEndpoint(host: 'vpn.example', port: 443),
        ],
        credentials: const <String, Object?>{},
        options: const <String, Object?>{},
        extensions: const <String, Object?>{},
        warnings: const <String>[],
      ),
      lifecycle: ConnectionLifecycle(
        api: stack.service.api,
        session: session,
        initial: ConnectionInfo.fromJson(testConnection()),
        scheduler: const _ManualScheduler(),
      ),
    );
  }

  bool get sawStop => stack.transport.requests.any(
    (request) =>
        request.method == 'POST' &&
        request.path == '/api/application/v1/connections/conn-1/stop',
  );
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

ConfigSelector _selector() => ConfigSelector.fromJson(testConfigEntry());

void main() {
  test('connect reports connected only on native confirmation', () async {
    final fixture = await _ControllerFixture.create();
    final adapter = FakeTunnelAdapter(
      response: const TunnelSnapshot(state: TunnelState.connected, sequence: 2),
    );
    AcquiredConfig? acquired;
    final controller = WhiteLabelController(
      service: fixture.stack.service,
      productMode: ClientProductMode.whiteLabel,
      tunnelAdapter: adapter,
      acquire: fixture.stubAcquire((value) => acquired = value),
    );
    addTearDown(controller.dispose);
    await controller.start();
    expect(controller.phase, WhiteLabelPhase.ready);

    final result = await controller.connect(_selector());

    expect(result, WhiteLabelConnectResult.connected);
    expect(controller.tunnelSnapshot.state, TunnelState.connected);
    expect(controller.hasActiveConnection, isTrue);
    expect(controller.attemptedProtocol, 'wireguard');
    final request = adapter.request!;
    expect(request.productMode, ClientProductMode.whiteLabel);
    expect(request.connectionId, 'conn-1');
    expect(request.requestId.startsWith('whitelabel-'), isTrue);
    expect(identical(request.config, acquired!.normalized), isTrue);
  });

  test(
    'connecting snapshot yields requestAccepted without claiming success',
    () async {
      final fixture = await _ControllerFixture.create();
      final adapter = FakeTunnelAdapter();
      final controller = WhiteLabelController(
        service: fixture.stack.service,
        productMode: ClientProductMode.whiteLabel,
        tunnelAdapter: adapter,
        acquire: fixture.stubAcquire((_) {}),
      );
      addTearDown(controller.dispose);
      await controller.start();

      final result = await controller.connect(_selector());

      expect(result, WhiteLabelConnectResult.requestAccepted);
      expect(controller.hasActiveConnection, isTrue);
    },
  );

  test(
    'failed native snapshot releases the lease and wipes runtime bytes',
    () async {
      final fixture = await _ControllerFixture.create();
      final adapter = FakeTunnelAdapter(
        response: const TunnelSnapshot(state: TunnelState.failed, sequence: 2),
      );
      AcquiredConfig? acquired;
      final controller = WhiteLabelController(
        service: fixture.stack.service,
        productMode: ClientProductMode.whiteLabel,
        tunnelAdapter: adapter,
        acquire: fixture.stubAcquire((value) => acquired = value),
      );
      addTearDown(controller.dispose);
      await controller.start();

      final result = await controller.connect(_selector());

      expect(result, WhiteLabelConnectResult.failed);
      expect(controller.hasActiveConnection, isFalse);
      expect(fixture.sawStop, isTrue);
      expect(acquired!.opened.plaintext.every((byte) => byte == 0), isTrue);
    },
  );

  test('native protocol failure maps without leaking lease state', () async {
    final fixture = await _ControllerFixture.create();
    final adapter = FakeTunnelAdapter(
      connectError: const TunnelFailure(
        code: 'protocol_unavailable',
        safeMessage: 'unavailable',
      ),
    );
    AcquiredConfig? acquired;
    final controller = WhiteLabelController(
      service: fixture.stack.service,
      productMode: ClientProductMode.whiteLabel,
      tunnelAdapter: adapter,
      acquire: fixture.stubAcquire((value) => acquired = value),
    );
    addTearDown(controller.dispose);
    await controller.start();

    final result = await controller.connect(_selector());

    expect(result, WhiteLabelConnectResult.protocolUnavailable);
    expect(controller.hasActiveConnection, isFalse);
    expect(fixture.sawStop, isTrue);
    expect(acquired!.opened.plaintext.every((byte) => byte == 0), isTrue);
  });

  test(
    'second connect while active is rejected without a new acquisition',
    () async {
      final fixture = await _ControllerFixture.create();
      final adapter = FakeTunnelAdapter();
      var acquisitions = 0;
      final controller = WhiteLabelController(
        service: fixture.stack.service,
        productMode: ClientProductMode.whiteLabel,
        tunnelAdapter: adapter,
        acquire: (session, selector) async {
          acquisitions += 1;
          return fixture.stubAcquire((_) {})(session, selector);
        },
      );
      addTearDown(controller.dispose);
      await controller.start();

      expect(
        await controller.connect(_selector()),
        WhiteLabelConnectResult.requestAccepted,
      );
      expect(
        await controller.connect(_selector()),
        WhiteLabelConnectResult.alreadyConnected,
      );
      expect(acquisitions, 1);
    },
  );

  test('null adapter never acquires runtime config', () async {
    final fixture = await _ControllerFixture.create();
    var acquisitions = 0;
    final controller = WhiteLabelController(
      service: fixture.stack.service,
      productMode: ClientProductMode.whiteLabel,
      tunnelAdapter: null,
      acquire: (session, selector) async {
        acquisitions += 1;
        return fixture.stubAcquire((_) {})(session, selector);
      },
    );
    addTearDown(controller.dispose);
    await controller.start();

    final result = await controller.connect(_selector());

    expect(result, WhiteLabelConnectResult.adapterUnavailable);
    expect(acquisitions, 0);
  });

  test('disconnect stops the lease and wipes runtime bytes', () async {
    final fixture = await _ControllerFixture.create();
    final adapter = FakeTunnelAdapter();
    AcquiredConfig? acquired;
    final controller = WhiteLabelController(
      service: fixture.stack.service,
      productMode: ClientProductMode.whiteLabel,
      tunnelAdapter: adapter,
      acquire: fixture.stubAcquire((value) => acquired = value),
    );
    addTearDown(controller.dispose);
    await controller.start();
    await controller.connect(_selector());
    expect(controller.hasActiveConnection, isTrue);

    await controller.disconnect();

    expect(controller.hasActiveConnection, isFalse);
    expect(adapter.disconnectReasons, <String>['user']);
    expect(fixture.sawStop, isTrue);
    expect(acquired!.opened.plaintext.every((byte) => byte == 0), isTrue);
    expect(controller.tunnelSnapshot.state, TunnelState.disconnected);
  });

  test('externally observed teardown releases the lease', () async {
    final fixture = await _ControllerFixture.create();
    final adapter = FakeTunnelAdapter();
    AcquiredConfig? acquired;
    final controller = WhiteLabelController(
      service: fixture.stack.service,
      productMode: ClientProductMode.whiteLabel,
      tunnelAdapter: adapter,
      acquire: fixture.stubAcquire((value) => acquired = value),
    );
    addTearDown(controller.dispose);
    await controller.start();
    await controller.connect(_selector());

    adapter.events.add(
      const TunnelSnapshot(state: TunnelState.failed, sequence: 7),
    );
    await _waitFor(() => !controller.hasActiveConnection);

    expect(adapter.disconnectReasons, <String>['external']);
    expect(fixture.sawStop, isTrue);
    expect(acquired!.opened.plaintext.every((byte) => byte == 0), isTrue);
  });

  test('dispose detaches without network and still wipes bytes', () async {
    final fixture = await _ControllerFixture.create();
    final adapter = FakeTunnelAdapter();
    AcquiredConfig? acquired;
    final controller = WhiteLabelController(
      service: fixture.stack.service,
      productMode: ClientProductMode.whiteLabel,
      tunnelAdapter: adapter,
      acquire: fixture.stubAcquire((value) => acquired = value),
    );
    await controller.start();
    await controller.connect(_selector());

    controller.dispose();

    expect(fixture.sawStop, isFalse);
    expect(acquired!.opened.plaintext.every((byte) => byte == 0), isTrue);
  });
}
