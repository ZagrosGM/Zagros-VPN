import 'package:flutter_test/flutter_test.dart';
import 'package:zagros_vpn/src/config/product_configuration.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

void main() {
  test('compile-time product composition matches the requested mode', () {
    const expected = String.fromEnvironment(
      'ZAGROS_EXPECT_PRODUCT_MODE',
      defaultValue: 'official',
    );
    final configuration = ProductConfiguration.fromEnvironment();

    switch (expected) {
      case 'official':
        expect(configuration.mode, ClientProductMode.official);
        expect(configuration.applicationIdentity, isNull);
      case 'white-label':
        expect(configuration.mode, ClientProductMode.whiteLabel);
        expect(configuration.applicationIdentity, isNotNull);
        configuration.policy.assertWhiteLabelInvariant();
      default:
        fail('Unsupported test expectation.');
    }
  });
}
