import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zagros_vpn/l10n/generated/app_localizations.dart';
import 'package:zagros_vpn/src/config/product_configuration.dart';
import 'package:zagros_vpn/src/home/home_screen.dart';
import 'package:zagros_vpn/src/library/library_controller.dart';
import 'package:zagros_vpn/src/storage/secure_storage.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import 'support/fixtures.dart';

void main() {
  group('HomeScreen Widget Tests', () {
    testWidgets('renders disconnected central button when tunnel is idle', (
      tester,
    ) async {
      final config = ProductConfiguration.fromValues(
        const <String, String>{'product_mode': 'official', 'default_locale': 'en'},
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

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: HomeScreen(
              configuration: config,
              libraryController: controller,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('DISCONNECTED'), findsOneWidget);
      expect(find.byIcon(Icons.power_settings_new_rounded), findsOneWidget);
      expect(find.text('No configuration selected'), findsOneWidget);
    });

    testWidgets('renders active subscription banner and speed meters', (
      tester,
    ) async {
      final config = ProductConfiguration.fromValues(
        const <String, String>{'product_mode': 'official', 'default_locale': 'en'},
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: HomeScreen(
              configuration: config,
              libraryController: null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Download'), findsOneWidget);
      expect(find.text('Upload'), findsOneWidget);
      expect(find.text('0 B/s'), findsNWidgets(2));
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
