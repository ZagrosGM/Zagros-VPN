import 'package:flutter_test/flutter_test.dart';
import 'package:zagros_vpn/src/config/product_configuration.dart';
import 'package:zagros_vpn/src/policy/navigation_policy.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import 'support/fixtures.dart';

void main() {
  test('Official mode needs no Application identity', () {
    final configuration = ProductConfiguration.fromValues(
      const <String, String>{'product_mode': 'official'},
    );
    expect(configuration.mode, ClientProductMode.official);
    expect(configuration.applicationIdentity, isNull);
    expect(configuration.applicationApiBaseUri, isNull);
    expect(destinationsFor(configuration), <AppDestination>[
      AppDestination.home,
      AppDestination.configs,
      AppDestination.logs,
      AppDestination.settings,
    ]);
  });

  test(
    'White-label mode requires and validates public Application identity',
    () {
      final configuration = ProductConfiguration.fromValues(whiteLabelValues());
      expect(configuration.mode, ClientProductMode.whiteLabel);
      expect(configuration.applicationIdentity?.applicationId, 'application-1');
      expect(configuration.applicationApiBaseUri?.scheme, 'https');
      expect(destinationsFor(configuration), <AppDestination>[
        AppDestination.home,
        AppDestination.configs,
        AppDestination.logs,
        AppDestination.settings,
      ]);
      expect(
        () => configuration.policy.require(ClientCapability.rawConfigDisplay),
        throwsA(isA<ClientPolicyViolation>()),
      );
    },
  );

  test(
    'White-label rejects missing identity, plaintext URL, and invalid keys',
    () {
      expect(
        () => ProductConfiguration.fromValues(const <String, String>{
          'product_mode': 'white-label',
        }),
        throwsA(isA<ProductConfigurationException>()),
      );
      final insecure = whiteLabelValues()
        ..['application_api_base_url'] = 'http://panel.example.test';
      expect(
        () => ProductConfiguration.fromValues(insecure),
        throwsA(isA<ProductConfigurationException>()),
      );
      final badKey = whiteLabelValues()..['config_public_key'] = 'not-a-key';
      expect(
        () => ProductConfiguration.fromValues(badKey),
        throwsA(isA<ProductConfigurationException>()),
      );
    },
  );

  test('unknown product modes and locales fail closed', () {
    expect(
      () => ProductConfiguration.fromValues(const <String, String>{
        'product_mode': 'surprise',
      }),
      throwsA(isA<ProductConfigurationException>()),
    );
    expect(
      () => ProductConfiguration.fromValues(const <String, String>{
        'product_mode': 'official',
        'default_locale': 'de',
      }),
      throwsA(isA<ProductConfigurationException>()),
    );
  });

  test('configuration rejects ambiguous URLs and control characters', () {
    final queryUrl = whiteLabelValues()
      ..['application_api_base_url'] =
          'https://panel.example.test/api?destination=attacker';
    expect(
      () => ProductConfiguration.fromValues(queryUrl),
      throwsA(isA<ProductConfigurationException>()),
    );

    final userInfoUrl = whiteLabelValues()
      ..['application_api_base_url'] =
          'https://user:password@panel.example.test';
    expect(
      () => ProductConfiguration.fromValues(userInfoUrl),
      throwsA(isA<ProductConfigurationException>()),
    );

    final controlName = whiteLabelValues()
      ..['application_name'] = 'Partner\nInjected';
    expect(
      () => ProductConfiguration.fromValues(controlName),
      throwsA(isA<ProductConfigurationException>()),
    );
  });

  test('diagnostics redact public identity details', () {
    final values = whiteLabelValues();
    final configuration = ProductConfiguration.fromValues(values);
    final diagnostic = configuration.toString();
    expect(diagnostic, contains('**redacted**'));
    expect(diagnostic, isNot(contains(values['application_id']!)));
    expect(diagnostic, isNot(contains(values['config_public_key']!)));
    expect(diagnostic, isNot(contains(values['signing_public_key']!)));
  });
}
