import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zagros_vpn/l10n/generated/app_localizations.dart';
import 'package:zagros_vpn/src/config/product_configuration.dart';
import 'package:zagros_vpn/src/configs/configs_screen.dart';
import 'package:zagros_vpn/src/library/library_controller.dart';
import 'package:zagros_vpn/src/storage/secure_storage.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import 'support/fixtures.dart';

void main() {
  group('ConfigsScreen Widget Tests', () {
    testWidgets('shows empty state when library has no profiles', (
      tester,
    ) async {
      final config = ProductConfiguration.fromValues(
        const <String, String>{
          'product_mode': 'official',
          'default_locale': 'en'
        },
      );
      final stores = ClientSecureStores(
        backend: MemorySecureBackend(),
        namespace: 'zagros.official',
      );
      final repo = OfficialProfileRepository(
        policy: config.policy,
        store: SecureOfficialCatalogStore(
          policy: config.policy,
          storage: stores.values,
        ),
        subscriptionClient: _DummySubscriptionClient(),
        deviceIdManager: OfficialDeviceIdManager(stores.values),
      );
      final controller = LibraryController(
        configuration: config,
        repository: repo,
        tunnelAdapter: null,
      );
      await controller.load();

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ConfigsScreen(
              configuration: config,
              libraryController: controller,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No profiles yet'), findsOneWidget);
      expect(find.text('Add subscription'), findsOneWidget);
      expect(find.text('Add manual config'), findsOneWidget);
    });

    test(
        'isProtocolSupported correctly recognizes native vs unsupported protocols',
        () {
      expect(isProtocolSupported('vless'), isTrue);
      expect(isProtocolSupported('VLESS'), isTrue);
      expect(isProtocolSupported('vmess'), isTrue);
      expect(isProtocolSupported('trojan'), isTrue);
      expect(isProtocolSupported('shadowsocks'), isTrue);
      expect(isProtocolSupported('ss'), isTrue);
      expect(isProtocolSupported('hysteria2'), isTrue);
      expect(isProtocolSupported('hy2'), isTrue);
      expect(isProtocolSupported('tuic'), isTrue);
      expect(isProtocolSupported('wireguard'), isTrue);
      expect(isProtocolSupported('ssh'), isTrue);
      expect(isProtocolSupported('anytls'), isTrue);
      expect(isProtocolSupported('openvpn'), isTrue);
      expect(isProtocolSupported('ovpn'), isTrue);
      // SoftEther ships as an embedded engine since the P3/P4 phases
      // (native TCP 5555 + SSTP 443); the old "unsupported" expectation is
      // stale.
      expect(isProtocolSupported('softether'), isTrue);
      // SSTP and raw L2TP ship as embedded engines; L2TP/IPsec joined them
      // with the in-process IKEv1+ESP stack. PPTP stays unsupported.
      expect(isProtocolSupported('l2tp'), isTrue);
      expect(isProtocolSupported('sstp'), isTrue);
      expect(isProtocolSupported('pptp'), isFalse);
    });
  });
}

class _DummySubscriptionClient implements OfficialSubscriptionClient {
  @override
  Future<OfficialSubscriptionDocument> fetch(
    Uri uri, {
    required String deviceId,
    String? etag,
    String? lastModified,
  }) async {
    throw UnimplementedError();
  }

  @override
  void close() {}
}
