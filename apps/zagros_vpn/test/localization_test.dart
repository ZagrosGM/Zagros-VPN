import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zagros_vpn/l10n/generated/app_localizations.dart';
import 'package:zagros_vpn/src/app.dart';
import 'package:zagros_vpn/src/app_dependencies.dart';
import 'package:zagros_vpn/src/config/product_configuration.dart';
import 'package:zagros_vpn/src/storage/secure_storage.dart';

import 'support/fixtures.dart';

Directory get _appDir {
  if (Directory('lib/l10n').existsSync()) return Directory.current;
  if (Directory('apps/zagros_vpn/lib/l10n').existsSync()) {
    return Directory('apps/zagros_vpn');
  }
  return Directory.current;
}

void main() {
  test('English and Persian catalogs have identical non-empty messages', () {
    final base = _appDir;
    final english = _messages('${base.path}/lib/l10n/app_en.arb');
    final persian = _messages('${base.path}/lib/l10n/app_fa.arb');
    expect(persian.keys, unorderedEquals(english.keys));
    expect(english.values, everyElement(isNotEmpty));
    expect(persian.values, everyElement(isNotEmpty));
    expect(AppLocalizations.supportedLocales, const <Locale>[
      Locale('en'),
      Locale('fa'),
    ]);
  });

  testWidgets('configuration failure is localized without raw details', (
    tester,
  ) async {
    await tester.pumpWidget(const ConfigurationErrorApp(locale: Locale('fa')));
    await tester.pumpAndSettle();

    expect(find.text('پیکربندی این بیلد معتبر نیست.'), findsOneWidget);
  });

  testWidgets('Persian product composition renders right-to-left', (
    tester,
  ) async {
    final configuration = ProductConfiguration.fromValues(whiteLabelValues());
    final stores = ClientSecureStores(
      backend: MemorySecureBackend(),
      namespace: 'zagros.whitelabel',
    );
    await tester.pumpWidget(
      ZagrosApp(
        configuration: configuration,
        dependencies: AppDependencies(
          secureStores: stores,
          tunnelAdapter: null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final title = find.text('حساب در دسترس نیست');
    expect(title, findsOneWidget);
    expect(Directionality.of(tester.element(title)), TextDirection.rtl);
  });
}

Map<String, String> _messages(String path) {
  final decoded =
      jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
  return <String, String>{
    for (final entry in decoded.entries)
      if (!entry.key.startsWith('@')) entry.key: entry.value! as String,
  };
}
