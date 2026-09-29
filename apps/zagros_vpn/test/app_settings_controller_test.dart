import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zagros_vpn/src/settings/app_settings_controller.dart';

void main() {
  group('AppSettingsController Tests', () {
    test('updates locale and notifies listeners', () {
      final controller = AppSettingsController(initialLocale: 'en');
      expect(controller.locale.languageCode, 'en');

      var notified = false;
      controller.addListener(() => notified = true);

      controller.setLocale(const Locale('fa'));
      expect(controller.locale.languageCode, 'fa');
      expect(notified, isTrue);
    });

    test('updates DNS preset and custom address and notifies listeners', () {
      final controller = AppSettingsController();
      expect(controller.dnsPreset, DnsPreset.system);

      var notified = false;
      controller.addListener(() => notified = true);

      controller.setDnsPreset(DnsPreset.cloudflare);
      expect(controller.dnsPreset, DnsPreset.cloudflare);
      expect(notified, isTrue);

      controller.setCustomDns('1.1.1.1');
      expect(controller.customDns, '1.1.1.1');
    });
  });
}
