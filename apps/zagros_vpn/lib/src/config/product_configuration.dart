import 'dart:typed_data';

import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

class ProductConfigurationException implements Exception {
  const ProductConfigurationException(this.safeMessage);

  final String safeMessage;

  @override
  String toString() => 'ProductConfigurationException($safeMessage)';
}

class ProductConfiguration {
  const ProductConfiguration._({
    required this.mode,
    required this.policy,
    required this.appName,
    required this.defaultLocale,
    this.applicationApiBaseUri,
    this.applicationIdentity,
    this.allowInsecureHttp = false,
    this.applicationSigningSeed,
  });

  final ClientProductMode mode;
  final ClientPolicy policy;
  final String appName;
  final String defaultLocale;
  final Uri? applicationApiBaseUri;
  final ApplicationIdentity? applicationIdentity;
  final bool allowInsecureHttp;

  /// Build-embedded signing seed enabling ticket-free device enrollment.
  final Uint8List? applicationSigningSeed;

  bool get isWhiteLabel => mode == ClientProductMode.whiteLabel;

  static ProductConfiguration fromEnvironment() {
    const rawMode = String.fromEnvironment(
      'ZAGROS_PRODUCT_MODE',
      defaultValue: String.fromEnvironment('product_mode', defaultValue: 'official'),
    );
    const rawAppName = String.fromEnvironment(
      'ZAGROS_APP_NAME',
      defaultValue: String.fromEnvironment('app_name', defaultValue: 'Zagros VPN'),
    );
    const rawLocale = String.fromEnvironment(
      'ZAGROS_DEFAULT_LOCALE',
      defaultValue: String.fromEnvironment('default_locale', defaultValue: 'fa'),
    );
    const rawApiUrl = String.fromEnvironment(
      'ZAGROS_APPLICATION_API_BASE_URL',
      defaultValue: String.fromEnvironment(
        'application_api_base_url',
        defaultValue: String.fromEnvironment(
          'service_base_url',
          defaultValue: 'https://109.248.161.249:8443',
        ),
      ),
    );
    const rawAppId = String.fromEnvironment(
      'ZAGROS_APPLICATION_ID',
      defaultValue: String.fromEnvironment('application_id', defaultValue: '1c662b2b-7476-478b-8a29-9383546dbbe9'),
    );
    const rawAppNameVal = String.fromEnvironment(
      'ZAGROS_APPLICATION_NAME',
      defaultValue: String.fromEnvironment('application_name', defaultValue: 'Azbarfilm WL Test'),
    );
    const rawAppStatus = String.fromEnvironment(
      'ZAGROS_APPLICATION_STATUS',
      defaultValue: String.fromEnvironment('application_status', defaultValue: 'active'),
    );
    const rawConfigKeyId = String.fromEnvironment(
      'ZAGROS_CONFIG_KEY_ID',
      defaultValue: String.fromEnvironment('config_key_id', defaultValue: 'cfg-0c0f4cccbeee7e1e'),
    );
    const rawConfigPubKey = String.fromEnvironment(
      'ZAGROS_CONFIG_PUBLIC_KEY',
      defaultValue: String.fromEnvironment(
        'config_public_key',
        defaultValue: String.fromEnvironment(
          'application_public_key',
          defaultValue: '7uTak17CiA5J3zX_zSnM4M-kkCHCg8PLbXljNQc022c',
        ),
      ),
    );
    const rawSigningKeyId = String.fromEnvironment(
      'ZAGROS_SIGNING_KEY_ID',
      defaultValue: String.fromEnvironment('signing_key_id', defaultValue: 'sig-384254b5ee751179'),
    );
    const rawSigningPubKey = String.fromEnvironment(
      'ZAGROS_SIGNING_PUBLIC_KEY',
      defaultValue: String.fromEnvironment(
        'signing_public_key',
        defaultValue: 'W2BY0bjnZ94u-VuP1xfwilqO4wzzl_hQQqoLtTSA8as',
      ),
    );
    const rawAllowHttp = String.fromEnvironment(
      'ZAGROS_ALLOW_INSECURE_HTTP',
      defaultValue: String.fromEnvironment('allow_insecure_http', defaultValue: 'true'),
    );
    const rawSigningSeed = String.fromEnvironment(
      'ZAGROS_APPLICATION_SIGNING_PRIVATE_KEY',
    );

    return fromValues(<String, String>{
      'product_mode': rawMode,
      'app_name': rawAppName,
      'default_locale': rawLocale,
      if (rawApiUrl.isNotEmpty) 'application_api_base_url': rawApiUrl,
      if (rawAppId.isNotEmpty) 'application_id': rawAppId,
      if (rawAppNameVal.isNotEmpty) 'application_name': rawAppNameVal,
      if (rawAppStatus.isNotEmpty) 'application_status': rawAppStatus,
      if (rawConfigKeyId.isNotEmpty) 'config_key_id': rawConfigKeyId,
      if (rawConfigPubKey.isNotEmpty) 'config_public_key': rawConfigPubKey,
      if (rawSigningKeyId.isNotEmpty) 'signing_key_id': rawSigningKeyId,
      if (rawSigningPubKey.isNotEmpty) 'signing_public_key': rawSigningPubKey,
      if (rawSigningSeed.isNotEmpty) 'signing_private_seed': rawSigningSeed,
      if (rawAllowHttp.isNotEmpty) 'allow_insecure_http': rawAllowHttp,
    });
  }

  static ProductConfiguration fromValues(Map<String, String> values) {
    final rawMode = (values['product_mode'] ?? 'official').trim().toLowerCase();
    final mode = switch (rawMode) {
      'official' => ClientProductMode.official,
      'white-label' ||
      'whitelabel' ||
      'white_label' => ClientProductMode.whiteLabel,
      _ => throw const ProductConfigurationException(
        'Unsupported product mode.',
      ),
    };
    final appName = _boundedText(
      values['app_name'] ?? 'Zagros VPN',
      field: 'app name',
      maximumLength: 128,
    );
    final locale = (values['default_locale'] ?? 'en').trim().toLowerCase();
    if (locale != 'en' && locale != 'fa') {
      throw const ProductConfigurationException(
        'Default locale must be en or fa.',
      );
    }
    if (mode == ClientProductMode.official) {
      return ProductConfiguration._(
        mode: mode,
        policy: const ClientPolicy.official(),
        appName: appName,
        defaultLocale: locale,
      );
    }

    final allowHttp = (values['allow_insecure_http'] ?? 'false').trim().toLowerCase() == 'true';
    final apiBaseUri = Uri.tryParse(
      _required(values, 'application_api_base_url'),
    );
    final validScheme = apiBaseUri != null &&
        (apiBaseUri.scheme == 'https' || (allowHttp && apiBaseUri.scheme == 'http'));
    if (!validScheme ||
        apiBaseUri.host.isEmpty ||
        apiBaseUri.userInfo.isNotEmpty ||
        apiBaseUri.hasQuery ||
        apiBaseUri.hasFragment) {
      throw const ProductConfigurationException(
        'White-label Application API URL must be an HTTPS origin.',
      );
    }
    try {
      final configKeyId = _identifier(values, 'config_key_id');
      final rawConfigKey = _required(values, 'config_public_key').replaceAll('=', '').trim();
      final configPublicKey = decodeBase64Url(
        rawConfigKey,
        expectedLength: 32,
      );
      final signingKeyId = _identifier(values, 'signing_key_id');
      final rawSigningKey = _required(values, 'signing_public_key').replaceAll('=', '').trim();
      final signingPublicKey = decodeBase64Url(
        rawSigningKey,
        expectedLength: 32,
      );
      final rawSeed = (values['signing_private_seed'] ?? '').replaceAll('=', '').trim();
      final signingSeed = rawSeed.isEmpty
          ? null
          : decodeBase64Url(rawSeed, expectedLength: 32);

      final identity = ApplicationIdentity(
        applicationId: _identifier(values, 'application_id'),
        name: _boundedText(
          values['application_name'] ?? appName,
          field: 'application name',
          maximumLength: 128,
        ),
        status: _identifier(values, 'application_status'),
        configKeyId: configKeyId,
        configPublicKey: configPublicKey,
        signingKeyId: signingKeyId,
        signingPublicKey: signingPublicKey,
      );
      const policy = ClientPolicy.whiteLabel();
      policy.assertWhiteLabelInvariant();
      return ProductConfiguration._(
        mode: mode,
        policy: policy,
        appName: appName,
        defaultLocale: locale,
        applicationApiBaseUri: apiBaseUri,
        applicationIdentity: identity,
        allowInsecureHttp: allowHttp,
        applicationSigningSeed: signingSeed,
      );
    } on ProductConfigurationException {
      rethrow;
    } catch (_) {
      throw const ProductConfigurationException(
        'White-label public Application identity is invalid.',
      );
    }
  }

  static String _required(Map<String, String> values, String key) {
    final value = values[key]?.trim() ?? '';
    if (value.isEmpty) {
      throw const ProductConfigurationException(
        'White-label public Application configuration is incomplete.',
      );
    }
    return value;
  }

  static String _identifier(Map<String, String> values, String key) {
    final value = _required(values, key);
    if (!RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(value)) {
      throw const ProductConfigurationException(
        'White-label public Application identity is invalid.',
      );
    }
    return value;
  }

  static String _boundedText(
    String value, {
    required String field,
    required int maximumLength,
  }) {
    final normalized = value.trim();
    final containsControlCharacter = normalized.runes.any(
      (rune) =>
          rune < 0x20 ||
          (rune >= 0x7f && rune <= 0x9f) ||
          rune == 0x2028 ||
          rune == 0x2029,
    );
    if (normalized.isEmpty ||
        normalized.length > maximumLength ||
        containsControlCharacter) {
      throw ProductConfigurationException('Invalid $field.');
    }
    return normalized;
  }

  @override
  String toString() =>
      'ProductConfiguration(mode: $mode, public identity: **redacted**)';
}
