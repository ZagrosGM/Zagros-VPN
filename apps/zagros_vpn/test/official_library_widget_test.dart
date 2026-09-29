import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zagros_vpn/src/app.dart';
import 'package:zagros_vpn/src/app_dependencies.dart';
import 'package:zagros_vpn/src/config/product_configuration.dart';
import 'package:zagros_vpn/src/platform/raw_config_actions.dart';
import 'package:zagros_vpn/src/storage/secure_storage.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import 'support/fixtures.dart';

const _vless =
    'vless://00000000-0000-0000-0000-000000000001@vpn.example:443?security=tls&type=tcp#Primary';
const _trojan =
    'trojan://secret@backup.example:443?security=tls&type=tcp#Backup';

class FakeSubscriptionClient implements OfficialSubscriptionClient {
  OfficialSubscriptionDocument document = _document(_vless);
  Object? error;
  int calls = 0;

  @override
  Future<OfficialSubscriptionDocument> fetch(
    Uri uri, {
    required String deviceId,
    String? etag,
    String? lastModified,
  }) async {
    calls += 1;
    final nextError = error;
    error = null;
    if (nextError != null) throw nextError;
    return document;
  }

  @override
  void close() {}
}

class RecordingRawActions implements RawConfigActions {
  String? copied;
  String? exported;
  String? fileName;

  @override
  Future<void> copy(String rawConfig) async => copied = rawConfig;

  @override
  Future<String> export({
    required String rawConfig,
    required String suggestedName,
  }) async {
    exported = rawConfig;
    fileName = suggestedName;
    return '/synthetic-test-path/config.conf';
  }
}

class OfficialFixture {
  OfficialFixture({String locale = 'en'}) {
    configuration = ProductConfiguration.fromValues(<String, String>{
      'product_mode': 'official',
      'default_locale': locale,
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
      idGenerator: () => 'profile_test_${++id}',
      clock: () => DateTime.utc(2026, 9, 7, 12, id),
    );
  }

  late final ProductConfiguration configuration;
  late final ClientSecureStores stores;
  late final OfficialProfileRepository repository;
  final FakeSubscriptionClient subscriptions = FakeSubscriptionClient();
  final RecordingRawActions rawActions = RecordingRawActions();
  int id = 0;

  ZagrosApp app() => ZagrosApp(
        configuration: configuration,
        dependencies: AppDependencies(
          secureStores: stores,
          officialProfiles: repository,
          rawConfigActions: rawActions,
          tunnelAdapter: null,
        ),
      );
}

void main() {
  testWidgets(
    'Official manual CRUD exposes safe raw actions and honest tunnel state',
    (tester) async {
      final fixture = OfficialFixture();
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();
      await _openLibrary(tester);

      expect(find.text('No profiles yet'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('tunnel-unavailable-banner')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('library-add-manual')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('profile-name-field')),
        'Manual test',
      );
      await tester.enterText(
        find.byKey(const ValueKey('manual-config-field')),
        _vless,
      );
      await tester.tap(find.byKey(const ValueKey('save-profile')));
      await tester.pumpAndSettle();

      expect(find.text('Manual test'), findsOneWidget);
      expect(find.text('1 configuration'), findsOneWidget);

      await tester.tap(find.text('Manual test'));
      await tester.pumpAndSettle();
      expect(find.text('VLESS • vpn.example:443'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('config-raw-profile_test_1.0')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('raw-config-dialog')), findsOneWidget);
      expect(find.text(_vless), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('raw-config-copy')));
      await tester.pump();
      expect(fixture.rawActions.copied, _vless);

      await tester.tap(find.byKey(const ValueKey('raw-config-export')));
      await tester.pumpAndSettle();
      expect(find.text('Export plaintext configuration?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-raw-export')));
      await tester.pumpAndSettle();
      expect(fixture.rawActions.exported, _vless);
      expect(fixture.rawActions.fileName, contains('vless'));

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('config-connect-profile_test_1.0')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('connection-result-adapterUnavailable')),
        findsOneWidget,
      );
      expect(
        find.text(
          'The installed native adapter does not support this configuration on the current platform.',
        ),
        findsWidgets,
      );
    },
  );

  testWidgets(
    'Official subscription add, refresh failure, edit, and delete are safe',
    (tester) async {
      final fixture = OfficialFixture();
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();
      await _openLibrary(tester);

      await tester.tap(find.byKey(const ValueKey('library-add-subscription')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('profile-name-field')),
        'Main subscription',
      );
      await tester.enterText(
        find.byKey(const ValueKey('subscription-url-field')),
        'https://panel.example/sub/token',
      );
      await tester.tap(find.byKey(const ValueKey('save-profile')));
      await tester.pumpAndSettle();

      expect(find.text('Main subscription'), findsOneWidget);
      expect(find.text('Source: panel.example'), findsOneWidget);
      expect(fixture.subscriptions.calls, 1);
      await tester.tap(find.text('Main subscription'));
      await tester.pumpAndSettle();
      expect(find.text('Used 30 B of 100 B'), findsOneWidget);
      expect(find.text('Suggested refresh interval: 12 hours'), findsOneWidget);
      expect(find.textContaining('Expires '), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      fixture.subscriptions.error = const ZagrosTransportException('offline');
      await tester.tap(
        find.byKey(const ValueKey('profile-refresh-profile_test_1')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'The subscription could not be reached. The previous profile was kept.',
        ),
        findsWidgets,
      );
      expect(find.text('Main subscription'), findsOneWidget);

      fixture.subscriptions.document = _document(_trojan);
      await tester.tap(
        find.byKey(const ValueKey('profile-edit-profile_test_1')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('profile-name-field')),
        'Renamed subscription',
      );
      await tester.tap(find.byKey(const ValueKey('save-profile')));
      await tester.pumpAndSettle();
      expect(find.text('Renamed subscription'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('profile-delete-profile_test_1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Delete profile?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('confirm-delete-profile')));
      await tester.pumpAndSettle();
      expect(find.text('No profiles yet'), findsOneWidget);
    },
  );

  testWidgets('malformed manual config and legacy warnings are localized', (
    tester,
  ) async {
    final fixture = OfficialFixture();
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();
    await _openLibrary(tester);

    await tester.tap(find.byKey(const ValueKey('library-add-manual')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('profile-name-field')),
      'Invalid',
    );
    await tester.enterText(
      find.byKey(const ValueKey('manual-config-field')),
      'not a config',
    );
    await tester.tap(find.byKey(const ValueKey('save-profile')));
    await tester.pumpAndSettle();
    expect(
      find.text('The configuration or protected catalog is malformed.'),
      findsWidgets,
    );

    await tester.enterText(
      find.byKey(const ValueKey('manual-config-field')),
      'pptp://alice:secret@vpn.example:1723#Legacy',
    );
    await tester.tap(find.byKey(const ValueKey('save-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Invalid'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'PPTP is legacy and insecure, and is unavailable on modern iOS and Android systems.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Persian Official library renders right-to-left', (tester) async {
    final fixture = OfficialFixture(locale: 'fa');
    await tester.pumpWidget(fixture.app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('کانفیگ‌ها'));
    await tester.pumpAndSettle();

    final title = find.text('کانفیگ‌ها');
    expect(title, findsWidgets);
    expect(Directionality.of(tester.element(title.first)), TextDirection.rtl);
    expect(find.text('افزودن اشتراک'), findsOneWidget);
    expect(find.text('اتصال در دسترس نیست'), findsOneWidget);
  });
}

Future<void> _openLibrary(WidgetTester tester) async {
  await tester.tap(find.text('Configs'));
  await tester.pumpAndSettle();
}

OfficialSubscriptionDocument _document(String raw) =>
    OfficialSubscriptionDocument(
      rawBody: raw,
      configs: const OfficialConfigParser().parse(raw),
      notModified: false,
      etag: '"widget-test"',
      usage: OfficialSubscriptionUsage(
        uploadBytes: 10,
        downloadBytes: 20,
        totalBytes: 100,
        expiresAt: DateTime.utc(2030, 1, 1),
      ),
      updateInterval: const Duration(hours: 12),
    );
