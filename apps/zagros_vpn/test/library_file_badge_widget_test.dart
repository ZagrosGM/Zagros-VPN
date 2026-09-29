import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zagros_vpn/src/app.dart';
import 'package:zagros_vpn/src/app_dependencies.dart';
import 'package:zagros_vpn/src/config/product_configuration.dart';
import 'package:zagros_vpn/src/platform/raw_config_actions.dart';
import 'package:zagros_vpn/src/storage/secure_storage.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import 'support/fixtures.dart';

const _link = 'ss://YWVzLTI1Ni1nY206c2VjcmV0@example:8388#one';
const _markerWg =
    '# zagros-file: /sub/file/TOKEN0123456789abcdef0123456789/wireguard/wg0';
const _wgConf = '''[Interface]
PrivateKey = AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=
Address = 10.9.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = Hx4dHBsaGRgXFhUUExIREA8ODQwLCgkIBwYFBAMCAQA=
Endpoint = 203.0.113.7:51820
AllowedIPs = 0.0.0.0/0
''';

class _FakeSubscriptions implements OfficialSubscriptionClient {
  _FakeSubscriptions(this.document);

  OfficialSubscriptionDocument document;

  @override
  Future<OfficialSubscriptionDocument> fetch(
    Uri uri, {
    required String deviceId,
    String? etag,
    String? lastModified,
  }) async =>
      document;

  @override
  void close() {}
}

class _FakeFiles implements OfficialFileDownloadClient {
  Object? nextError;

  @override
  Future<String> fetchFile({
    required Uri subscriptionUri,
    required OfficialFileRef ref,
    required String deviceId,
  }) async {
    final error = nextError;
    nextError = null;
    if (error != null) throw error;
    return _wgConf;
  }

  @override
  void close() {}
}

class _NoopRawActions implements RawConfigActions {
  @override
  Future<void> copy(String rawConfig) async {}

  @override
  Future<String> export({
    required String rawConfig,
    required String suggestedName,
  }) async =>
      '/synthetic-test-path/config.conf';
}

class _Fixture {
  _Fixture() {
    configuration = ProductConfiguration.fromValues(<String, String>{
      'product_mode': 'official',
      'default_locale': 'en',
    });
    stores = ClientSecureStores(
      backend: MemorySecureBackend(),
      namespace: 'zagros.official',
    );
    repository = OfficialProfileRepository(
      policy: configuration.policy,
      store: SecureOfficialCatalogStore(
        policy: configuration.policy,
        storage: stores.values,
      ),
      subscriptionClient: subscriptions,
      deviceIdManager: OfficialDeviceIdManager(stores.values),
      fileDownloadClient: files,
      idGenerator: () => 'profile_test_${++id}',
      clock: () => DateTime.utc(2026, 9, 9, 12, id),
    );
  }

  late final ProductConfiguration configuration;
  late final ClientSecureStores stores;
  late final OfficialProfileRepository repository;
  final _FakeSubscriptions subscriptions =
      _FakeSubscriptions(_doc('$_link\n$_markerWg\n'));
  final _FakeFiles files = _FakeFiles();
  int id = 0;

  ZagrosApp app() => ZagrosApp(
        configuration: configuration,
        dependencies: AppDependencies(
          secureStores: stores,
          officialProfiles: repository,
          rawConfigActions: _NoopRawActions(),
          tunnelAdapter: null,
        ),
      );
}

OfficialSubscriptionDocument _doc(String raw) {
  const parser = OfficialConfigParser();
  return OfficialSubscriptionDocument(
    rawBody: raw,
    configs: parser.parse(raw),
    fileRefs: parser.fileRefs(raw),
    notModified: false,
  );
}

Future<void> _addSubscription(WidgetTester tester, String name) async {
  await tester.tap(find.text('Configs'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('library-add-subscription')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('profile-name-field')),
    name,
  );
  await tester.enterText(
    find.byKey(const ValueKey('subscription-url-field')),
    'https://panel.example/sub/TOKEN0123456789abcdef0123456789',
  );
  await tester.tap(find.byKey(const ValueKey('save-profile')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('WireGuard file entries render with a file badge', (
    tester,
  ) async {
    final fixture = _Fixture();
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();
    await _addSubscription(tester, 'File profile');

    expect(find.text('File profile'), findsOneWidget);
    expect(find.text('2 configurations'), findsOneWidget);

    await tester.tap(find.text('File profile'));
    await tester.pumpAndSettle();
    expect(find.text('WIREGUARD • 203.0.113.7:51820'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('config-filebadge-profile_test_1.1')),
      findsOneWidget,
    );
    expect(find.text('File'), findsOneWidget);
    expect(find.text('1 downloaded file is unavailable'), findsNothing);
  });

  testWidgets('a dead file marker shows a warning instead of an entry', (
    tester,
  ) async {
    final fixture = _Fixture();
    fixture.files.nextError = const ZagrosTransportException('offline');
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();
    await _addSubscription(tester, 'Broken file profile');

    expect(find.text('1 configuration'), findsOneWidget);

    await tester.tap(find.text('Broken file profile'));
    await tester.pumpAndSettle();
    expect(find.text('1 downloaded file is unavailable'), findsOneWidget);
    expect(find.text('File'), findsNothing);
  });
}
