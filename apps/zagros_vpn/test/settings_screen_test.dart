import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zagros_vpn/l10n/generated/app_localizations.dart';
import 'package:zagros_vpn/src/config/product_configuration.dart';
import 'package:zagros_vpn/src/settings/app_settings_controller.dart';
import 'package:zagros_vpn/src/settings/settings_screen.dart';

void main() {
  group('SettingsScreen Widget Tests', () {
    testWidgets('renders language selector, DNS options, and license entry', (
      tester,
    ) async {
      final config = ProductConfiguration.fromValues(
        const <String, String>{
          'product_mode': 'official',
          'default_locale': 'en'
        },
      );
      final controller = AppSettingsController(initialLocale: 'en');

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SettingsScreen(
            configuration: config,
            settingsController: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Language'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('فارسی'), findsOneWidget);

      expect(find.text('DNS Settings'), findsOneWidget);
      expect(find.text('System Default'), findsOneWidget);
      expect(find.text('Cloudflare (1.1.1.1)'), findsOneWidget);
      expect(find.text('Google (8.8.8.8)'), findsOneWidget);
      expect(find.text('Custom DNS'), findsOneWidget);

      expect(find.text('Open-source licenses'), findsOneWidget);
    });
  });
}
