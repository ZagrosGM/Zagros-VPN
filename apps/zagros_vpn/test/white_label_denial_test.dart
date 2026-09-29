import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zagros_vpn/src/config/product_configuration.dart';
import 'package:zagros_vpn/src/platform/raw_config_actions.dart';

import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import 'support/fixtures.dart';

Directory get _appDir {
  if (Directory('lib/src').existsSync()) return Directory.current;
  if (Directory('apps/zagros_vpn/lib/src').existsSync()) {
    return Directory('apps/zagros_vpn');
  }
  return Directory.current;
}

void main() {
  test('White-label denies every subscription and raw-config capability', () {
    final configuration = ProductConfiguration.fromValues(whiteLabelValues());
    const prohibited = <ClientCapability>[
      ClientCapability.subscriptionImport,
      ClientCapability.manualConfig,
      ClientCapability.rawConfigDisplay,
      ClientCapability.rawConfigExport,
      ClientCapability.rawConfigClipboard,
      ClientCapability.rawConfigPersistence,
    ];

    for (final capability in prohibited) {
      expect(configuration.policy.allows(capability), isFalse);
      expect(
        () => configuration.policy.require(capability),
        throwsA(isA<ClientPolicyViolation>()),
      );
    }
    expect(configuration.policy.rawConfigDisplay, isFalse);
    expect(configuration.policy.rawConfigPersistence, isFalse);
  });

  test(
    'White-label raw actions deny before reaching platform services',
    () async {
      const actions = PlatformRawConfigActions(ClientPolicy.whiteLabel());
      await expectLater(
        actions.copy('runtime-secret'),
        throwsA(isA<ClientPolicyViolation>()),
      );
      await expectLater(
        actions.export(rawConfig: 'runtime-secret', suggestedName: 'forbidden'),
        throwsA(isA<ClientPolicyViolation>()),
      );
    },
  );

  test('secure-storage adapter has no runtime-config persistence path', () {
    final base = _appDir;
    final storageSource = File('${base.path}/lib/src/storage/secure_storage.dart')
        .readAsStringSync();
    for (final prohibitedType in <String>[
      'NormalizedConfig',
      'OpenedConfig',
      'TunnelConnectRequest',
      'configPayload',
    ]) {
      expect(storageSource, isNot(contains(prohibitedType)));
    }
  });

  test(
    'raw actions are policy-bound and White-label has no persistence sink',
    () {
      final base = _appDir;
      final source = Directory('${base.path}/lib/src')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .map((file) => file.readAsStringSync())
          .join('\n');
      for (final sink in <String>[
        'SharedPreferences',
        'sqflite',
        'dart:io',
        'debugPrint(',
        'print(',
        'FirebaseAnalytics',
        'FirebaseCrashlytics',
      ]) {
        expect(
          source,
          isNot(contains(sink)),
          reason: 'Found prohibited sink: $sink',
        );
      }

      final actions = File('${base.path}/lib/src/platform/raw_config_actions.dart')
          .readAsStringSync();
      expect(
        actions,
        contains('policy.require(ClientCapability.rawConfigClipboard)'),
      );
      expect(
        actions,
        contains('policy.require(ClientCapability.rawConfigExport)'),
      );

      final composition = File('${base.path}/lib/main.dart').readAsStringSync();
      expect(composition, contains('ClientCapability.rawConfigPersistence'));
      expect(composition, contains('ClientCapability.rawConfigDisplay'));
      expect(composition, contains(': null;'));
    },
  );
}
