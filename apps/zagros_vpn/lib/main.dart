import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tunnel_interface/tunnel_interface.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import 'src/account/white_label_service.dart';
import 'src/app.dart';
import 'src/app_dependencies.dart';
import 'src/config/product_configuration.dart';
import 'src/platform/raw_config_actions.dart';
import 'src/settings/app_settings_controller.dart';
import 'src/storage/secure_storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    final notices = await rootBundle.loadString(
      'assets/legal/native_engine_notices.txt',
    );
    yield LicenseEntryWithLineBreaks(const <String>[
      'Zagros native tunnel engines',
    ], notices);
  });
  try {
    final configuration = ProductConfiguration.fromEnvironment();
    final secureStores = ClientSecureStores(
      backend: FlutterSecureStorageBackend(),
      namespace: configuration.isWhiteLabel
          ? 'zagros.whitelabel'
          : 'zagros.official',
    );
    final officialProfiles =
        configuration.policy.allows(ClientCapability.rawConfigPersistence)
        ? OfficialProfileRepository(
            policy: configuration.policy,
            store: SecureOfficialCatalogStore(
              policy: configuration.policy,
              storage: secureStores.values,
            ),
            subscriptionClient: HttpOfficialSubscriptionClient(),
            deviceIdManager: OfficialDeviceIdManager(secureStores.values),
          )
        : null;
    final rawConfigActions =
        configuration.policy.allows(ClientCapability.rawConfigDisplay)
        ? PlatformRawConfigActions(configuration.policy)
        : null;
    final whiteLabel =
        configuration.policy.allows(ClientCapability.applicationLogin)
        ? await _buildWhiteLabelService(configuration, secureStores)
        : null;
    // One shared settings instance for the whole app (f53): the previous code
    // created one controller in the app root and ANOTHER in the shell, so
    // language/DNS changes never reached the MaterialApp and were lost on
    // restart. This instance is also persisted (secure storage, best-effort).
    final settings = await _loadSettings(configuration, secureStores.values);
    runApp(
      ZagrosApp(
        configuration: configuration,
        dependencies: AppDependencies(
          secureStores: secureStores,
          officialProfiles: officialProfiles,
          rawConfigActions: rawConfigActions,
          whiteLabel: whiteLabel,
          settingsController: settings,
          // Both product modes use the same runtime-only native orchestration.
          // Native capability discovery, not product branding, decides support.
          tunnelAdapter: NativeTunnelAdapter(
            // Apple/Windows system profiles persist structured metadata while
            // active, so fail closed for White-label runtime-only policy.
            allowStructuredOsProfiles: !configuration.isWhiteLabel,
          ),
        ),
      ),
    );
  } on ProductConfigurationException {
    runApp(const ConfigurationErrorApp());
  }
}

/// Builds the authenticated Application stack. Any failure (missing public
/// identity, unreachable secure storage, unusable device identity) yields
/// null so the account destination renders an unavailable state instead of
/// a login form that could never authenticate.
Future<WhiteLabelService?> _buildWhiteLabelService(
  ProductConfiguration configuration,
  ClientSecureStores secureStores,
) async {
  final baseUri = configuration.applicationApiBaseUri;
  final application = configuration.applicationIdentity;
  if (baseUri == null || application == null) return null;
  try {
    return await WhiteLabelService.create(
      baseUri: baseUri,
      application: application,
      stores: secureStores,
      appSigningSeed: configuration.applicationSigningSeed,
      allowInsecureHttp: baseUri.scheme == 'http' || configuration.allowInsecureHttp,
    );
  } catch (_) {
    return null;
  }
}

const _supportedLanguageCodes = <String>['en', 'fa'];

DnsPreset _dnsPresetFromName(String name) => DnsPreset.values
    .firstWhere((p) => p.name == name, orElse: () => DnsPreset.system);

String? _decodeStr(List<int>? bytes) {
  if (bytes == null || bytes.isEmpty) return null;
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return null;
  }
}

Future<AppSettingsController> _loadSettings(
  ProductConfiguration configuration,
  SdkSecureValueStore storage,
) async {
  String savedLocale = configuration.defaultLocale;
  String savedDns = DnsPreset.system.name;
  String savedCustomDns = '';
  bool savedFakeDns = false;
  bool savedPerAppEnabled = false;
  String savedPerAppMode = 'allow';
  List<String> savedPerAppPackages = const <String>[];
  try {
    savedLocale =
        _decodeStr(await storage.read('settings.locale')) ?? savedLocale;
    savedDns = _decodeStr(await storage.read('settings.dnsPreset')) ?? savedDns;
    savedCustomDns =
        _decodeStr(await storage.read('settings.customDns')) ?? '';
    savedFakeDns = (_decodeStr(await storage.read('settings.fakeDns')) ?? '0') == '1';
    savedPerAppEnabled =
        (_decodeStr(await storage.read('settings.perAppEnabled')) ?? '0') == '1';
    savedPerAppMode =
        _decodeStr(await storage.read('settings.perAppMode')) ?? 'allow';
    final rawPkgs =
        _decodeStr(await storage.read('settings.perAppPackages')) ?? '';
    savedPerAppPackages = rawPkgs
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  } catch (_) {
    // Fail open to defaults; settings still work for this session.
  }
  if (!_supportedLanguageCodes.contains(savedLocale)) {
    savedLocale = configuration.defaultLocale;
  }
  if (savedPerAppMode != 'allow' && savedPerAppMode != 'deny') {
    savedPerAppMode = 'allow';
  }
  return AppSettingsController(
    initialLocale: savedLocale,
    initialDns: _dnsPresetFromName(savedDns),
    initialCustomDns: savedCustomDns,
    initialFakeDns: savedFakeDns,
    initialPerAppEnabled: savedPerAppEnabled,
    initialPerAppMode: savedPerAppMode,
    initialPerAppPackages: savedPerAppPackages,
    onPersist: (locale, dnsPreset, customDns, fakeDns, perAppEnabled,
            perAppMode, perAppPackages) =>
        unawaited(_persistSettings(storage, locale, dnsPreset, customDns,
            fakeDns, perAppEnabled, perAppMode, perAppPackages)),
  );
}

Future<void> _persistSettings(
    SdkSecureValueStore storage,
    String locale,
    String dnsPreset,
    String customDns,
    bool fakeDns,
    bool perAppEnabled,
    String perAppMode,
    List<String> perAppPackages) async {
  try {
    await storage.write('settings.locale', utf8.encode(locale));
    await storage.write('settings.dnsPreset', utf8.encode(dnsPreset));
    if (customDns.isNotEmpty) {
      await storage.write('settings.customDns', utf8.encode(customDns));
    } else {
      await storage.delete('settings.customDns');
    }
    await storage.write('settings.fakeDns', utf8.encode(fakeDns ? '1' : '0'));
    await storage.write(
        'settings.perAppEnabled', utf8.encode(perAppEnabled ? '1' : '0'));
    await storage.write('settings.perAppMode', utf8.encode(perAppMode));
    if (perAppPackages.isNotEmpty) {
      await storage.write(
          'settings.perAppPackages', utf8.encode(perAppPackages.join(',')));
    } else {
      await storage.delete('settings.perAppPackages');
    }
  } catch (_) {
    // Best-effort persistence.
  }
}
