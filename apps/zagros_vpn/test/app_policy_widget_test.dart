import 'package:flutter_test/flutter_test.dart';
import 'package:zagros_vpn/src/app.dart';
import 'package:zagros_vpn/src/app_dependencies.dart';
import 'package:zagros_vpn/src/config/product_configuration.dart';
import 'package:zagros_vpn/src/storage/secure_storage.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import 'support/fixtures.dart';

void main() {
  testWidgets(
      'Official shell exposes 4 tabs and no Application account enrollment', (
    tester,
  ) async {
    final configuration = ProductConfiguration.fromValues(
      const <String, String>{'product_mode': 'official'},
    );
    await tester.pumpWidget(_app(configuration));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Configs'), findsOneWidget);
    expect(find.text('Logs'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Account'), findsNothing);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Open-source licenses'), findsOneWidget);
  });

  testWidgets(
      'White-label shell requires enrollment and hides raw config library', (
    tester,
  ) async {
    final configuration = ProductConfiguration.fromValues(
      whiteLabelValues()..['default_locale'] = 'en',
    );
    expect(configuration.policy.rawConfigDisplay, isFalse);
    expect(configuration.policy.rawConfigPersistence, isFalse);
    await tester.pumpWidget(_app(configuration));
    await tester.pumpAndSettle();
    expect(find.text('Account unavailable'), findsOneWidget);
    expect(find.text('Configs'), findsNothing);
  });
}

ZagrosApp _app(ProductConfiguration configuration) {
  final stores = ClientSecureStores(
    backend: MemorySecureBackend(),
    namespace: configuration.mode == ClientProductMode.whiteLabel
        ? 'zagros.whitelabel'
        : 'zagros.official',
  );
  return ZagrosApp(
    configuration: configuration,
    dependencies: AppDependencies(secureStores: stores, tunnelAdapter: null),
  );
}
