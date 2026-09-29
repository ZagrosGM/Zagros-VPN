import 'dart:typed_data';

import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import '../storage/secure_storage.dart';

/// Production composition of the authenticated Application stack.
///
/// The service owns the real SDK objects (transport, signed executor, API,
/// device identity, auth controller) and the single factory for
/// [ConfigAcquisition]. Screens and controllers consume this bundle; they
/// never build transports, executors, parsers, or cryptographic objects.
class WhiteLabelService {
  WhiteLabelService._(
    this.api,
    this.auth,
    this.application,
    this._deviceIdentity,
    this._closeTransport,
  );

  /// Builds the production stack over HTTPS transport and OS-protected
  /// storage. The device X25519 identity is loaded or created inside secure
  /// storage; its private key never leaves this service boundary in Dart.
  static Future<WhiteLabelService> create({
    required Uri baseUri,
    required ApplicationIdentity application,
    required ClientSecureStores stores,
    Uint8List? appSigningSeed,
    bool allowInsecureHttp = false,
  }) async {
    final transport = HttpApiTransport(
      baseUri: baseUri,
      allowInsecureHttp: allowInsecureHttp || baseUri.scheme == 'http',
    );
    try {
      final deviceIdentity =
          await DeviceIdentityManager(stores.values).loadOrCreate();
      final api = ApplicationApi(
        executor: SignedRequestExecutor(
          transport: transport,
          application: application,
          deviceKeyPair: deviceIdentity.keyPair,
        ),
        deviceIdentity: deviceIdentity,
      );
      final auth = ApplicationAuthController(
        api: api,
        tokenStorage: stores.tokens,
        identityStorage: stores.values,
        applicationPublicId: application.applicationId,
        appSigningSeed: appSigningSeed,
        appSigningKeyId: application.signingKeyId,
      );
      return WhiteLabelService._(
        api,
        auth,
        application,
        deviceIdentity,
        () async => transport.close(),
      );
    } catch (_) {
      transport.close();
      rethrow;
    }
  }

  /// Test stack with an injected transport seam. Production must use
  /// [create]. Tests still run the real SDK executor, API, signing, and
  /// parsing above the fake [ApiTransport].
  factory WhiteLabelService.test({
    required ApplicationApi api,
    required ApplicationAuthController auth,
    required ApplicationIdentity application,
    required DeviceIdentity deviceIdentity,
  }) =>
      WhiteLabelService._(api, auth, application, deviceIdentity, () async {});

  final ApplicationApi api;
  final ApplicationAuthController auth;
  final ApplicationIdentity application;
  final DeviceIdentity _deviceIdentity;
  final Future<void> Function() _closeTransport;

  /// Immediate list-select-consume for the selector the user tapped.
  /// Acquisition re-lists and only consumes the same `config_id`, so the
  /// displayed list can never cause a different config to be consumed.
  Future<AcquiredConfig> defaultAcquire(
    ApplicationSession session,
    ConfigSelector selector,
  ) =>
      createAcquisition(session).acquire((list) {
        return list.firstWhere(
          (s) =>
              (selector.configId != null && s.configId == selector.configId) ||
              (s.coreId == selector.coreId &&
                  s.protocol == selector.protocol &&
                  s.displayName == selector.displayName),
          orElse: () => list.firstWhere(
            (s) => s.displayName == selector.displayName,
            orElse: () => list.first,
          ),
        );
      });

  ConfigAcquisition createAcquisition(
    ApplicationSession session, {
    ActionScheduler? scheduler,
  }) =>
      ConfigAcquisition(
        api: api,
        session: session,
        application: application,
        deviceKeyPair: _deviceIdentity.keyPair,
        scheduler: scheduler ?? const TimerActionScheduler(),
      );

  Future<void> close() => _closeTransport();
}
