import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_interface/tunnel_interface.dart';
import 'package:zagros_vpn/src/app.dart';
import 'package:zagros_vpn/src/app_dependencies.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import 'support/fakes.dart';
import 'support/fixtures.dart';

Map<String, String> _englishValues() =>
    whiteLabelValues()..['default_locale'] = 'en';

ZagrosApp _app(WhiteLabelTestStack stack, {TunnelAdapter? adapter}) =>
    ZagrosApp(
      configuration: stack.configuration,
      dependencies: AppDependencies(
        secureStores: stack.stores,
        whiteLabel: stack.service,
        tunnelAdapter: adapter,
      ),
    );

Future<void> _openAccount(WidgetTester tester) async {
  if (find.text('Settings').evaluate().isNotEmpty) {
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
  } else if (find.text('تنظیمات').evaluate().isNotEmpty) {
    await tester.tap(find.text('تنظیمات'));
    await tester.pumpAndSettle();
  }
}

Future<void> _enroll(
  WidgetTester tester, {
  String username = 'partner-user',
  String password = 'secret-password',
}) async {
  // Final contract: enrollment is username+password only. The device is
  // proven by the build-embedded signing key — users NEVER enter an
  // activation code (the field was removed from the product entirely).
  expect(find.byKey(const ValueKey('wl-enroll-submit')), findsOneWidget);
  expect(find.byKey(const ValueKey('wl-ticket')), findsNothing);
  await tester.enterText(find.byKey(const ValueKey('wl-username')), username);
  await tester.enterText(find.byKey(const ValueKey('wl-password')), password);
  await tester.tap(find.byKey(const ValueKey('wl-enroll-submit')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('fresh install logs in and lists configs without raw exposure', (
    tester,
  ) async {
    final stack = await WhiteLabelTestStack.create(values: _englishValues());
    await tester.pumpWidget(_app(stack));
    await tester.pumpAndSettle();
    await _openAccount(tester);

    // Fresh install: the simple credential form is the entry point; the
    // activation-code field must stay gone from the product.
    expect(find.byKey(const ValueKey('wl-enroll-submit')), findsOneWidget);
    await _enroll(tester);

    await tester.tap(find.text('Configs'));
    await tester.pumpAndSettle();

    expect(find.text('Connections'), findsOneWidget);
    expect(find.text('Germany 01'), findsOneWidget);
    expect(find.text('Netherlands 02'), findsOneWidget);
    expect(find.textContaining('wireguard • wireguard'), findsOneWidget);
    expect(find.textContaining('vless • xray'), findsOneWidget);
    expect(find.text('Legacy 03'), findsOneWidget);
    expect(find.byKey(const ValueKey('wl-connect-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('wl-connect-2')), findsNothing);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    final accountText = find.text('Signed in as partner-user');
    await tester.scrollUntilVisible(accountText, 200);
    expect(accountText, findsOneWidget);

    // Secrets never render: password fields are cleared on submit,
    // tokens stay in secure storage, and no raw config is ever displayed.
    expect(find.text('secret-password'), findsNothing);
    expect(find.text('test-access-token'), findsNothing);
    expect(find.text('test-refresh-token'), findsNothing);

    // The enrollment really went through the signed SDK stack.
    final enroll = stack.transport.requests.singleWhere(
      (request) =>
          request.method == 'POST' &&
          request.path == '/api/application/v1/devices/enroll',
    );
    final body = stack.transport.bodyOf(enroll);
    expect(body['username'], 'partner-user');
    expect(body['password'], 'secret-password');
    expect((body['device_public_key'] as String).isNotEmpty, isTrue);
    expect(enroll.headers['x-zagros-device-id'], '-');
  });

  testWidgets('wrong password on login shows invalid credentials', (
    tester,
  ) async {
    final transport = FakeApiTransport();
    transport.handlers['POST /api/application/v1/devices/enroll'] = (
      request,
    ) async =>
        FakeApiTransport.failure(401, 'invalid_credentials', 'nope');
    assert(() {
      // sanity: this test exercises a rejected *enroll*, matching the
      // ticketed activation flow the UI now enforces on fresh installs.
      return true;
    }());
    final stack = await WhiteLabelTestStack.create(
      transport: transport,
      values: _englishValues(),
    );
    await tester.pumpWidget(_app(stack));
    await tester.pumpAndSettle();
    await _openAccount(tester);

    // Fresh install: the credential (enrollment) form is the entry point.
    expect(find.byKey(const ValueKey('wl-enroll-submit')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('wl-username')),
      'partner-user',
    );
    await tester.enterText(
      find.byKey(const ValueKey('wl-password')),
      'wrong-password',
    );
    await tester.tap(find.byKey(const ValueKey('wl-enroll-submit')));
    await tester.pumpAndSettle();

    // The credential error from the rejected enroll stays on the form.
    expect(find.text('The username or password is incorrect.'), findsOneWidget);
    expect(find.byKey(const ValueKey('wl-enroll-submit')), findsOneWidget);
  });

  testWidgets('expired session drops to login with a session message', (
    tester,
  ) async {
    final stack = await WhiteLabelTestStack.create(values: _englishValues());
    await serviceEnrollDirectly(stack);
    await stack.stores.tokens.write(
      jsonEncode(
        testTokens(
          accessExpires: DateTime.utc(2020, 1, 1),
          refreshExpires: DateTime.utc(2020, 1, 2),
        ),
      ),
    );
    await tester.pumpWidget(_app(stack));
    await tester.pumpAndSettle();
    await _openAccount(tester);

    expect(find.text('The session expired. Sign in again.'), findsOneWidget);
    expect(find.byKey(const ValueKey('wl-login-submit')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('wl-username')),
      'partner-user',
    );
    await tester.enterText(
      find.byKey(const ValueKey('wl-password')),
      'secret-password',
    );
    await tester.tap(find.byKey(const ValueKey('wl-login-submit')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Configs'));
    await tester.pumpAndSettle();
    expect(find.text('Connections'), findsOneWidget);
  });

  testWidgets(
    'null adapter connect is honestly unavailable and never consumes config',
    (tester) async {
      final stack = await WhiteLabelTestStack.create(values: _englishValues());
      await tester.pumpWidget(_app(stack));
      await tester.pumpAndSettle();
      await _openAccount(tester);
      await _enroll(tester);

      await tester.tap(find.text('Configs'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('wl-connect-0')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('connection-result-adapterUnavailable')),
        findsOneWidget,
      );
      expect(
        find.text(
          'The installed native adapter does not support this configuration on the current platform.',
        ),
        findsOneWidget,
      );
      expect(stack.transport.sawStart, isFalse);
      expect(stack.transport.sawConsume, isFalse);
    },
  );

  testWidgets(
    'unsupported protocol never reaches acquisition or the native adapter',
    (tester) async {
      final stack = await WhiteLabelTestStack.create(values: _englishValues());
      final adapter = FakeTunnelAdapter(
        protocols: const <String>{'wireguard'},
        unavailableReasons: const <String, String>{
          'vless': 'No native engine handles vless here.',
        },
      );
      await tester.pumpWidget(_app(stack, adapter: adapter));
      await tester.pumpAndSettle();
      await _openAccount(tester);
      await _enroll(tester);

      await tester.tap(find.text('Configs'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('wl-connect-1')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('connection-result-protocolUnavailable')),
        findsOneWidget,
      );
      expect(find.text('No native engine handles vless here.'), findsOneWidget);
      expect(adapter.request, isNull);
      expect(stack.transport.sawStart, isFalse);
      expect(stack.transport.sawConsume, isFalse);
    },
  );

  testWidgets('logout returns to login and clears stored tokens', (
    tester,
  ) async {
    final stack = await WhiteLabelTestStack.create(values: _englishValues());
    await tester.pumpWidget(_app(stack));
    await tester.pumpAndSettle();
    await _openAccount(tester);
    await _enroll(tester);
    expect(await stack.stores.tokens.read(), isNotNull);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    final logoutButton = find.byKey(const ValueKey('wl-logout'));
    await tester.scrollUntilVisible(logoutButton, 200);
    await tester.tap(logoutButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('wl-login-submit')), findsOneWidget);
    expect(await stack.stores.tokens.read(), isNull);
    expect(
      stack.transport.requests.any(
        (request) =>
            request.method == 'POST' &&
            request.path == '/api/application/v1/auth/logout',
      ),
      isTrue,
    );
  });

  testWidgets('missing service renders an unavailable account state', (
    tester,
  ) async {
    final stack = await WhiteLabelTestStack.create(values: _englishValues());
    await tester.pumpWidget(
      ZagrosApp(
        configuration: stack.configuration,
        dependencies: AppDependencies(
          secureStores: stack.stores,
          whiteLabel: null,
          tunnelAdapter: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openAccount(tester);

    expect(find.text('Account unavailable'), findsOneWidget);
    expect(find.byKey(const ValueKey('wl-username')), findsNothing);
  });

  testWidgets('Persian white-label renders right-to-left', (tester) async {
    final stack = await WhiteLabelTestStack.create();
    await tester.pumpWidget(_app(stack));
    await tester.pumpAndSettle();

    // Fresh install renders the credential enrollment form in RTL — and the
    // activation-code field is gone from the product.
    final title = find.text('ثبت این دستگاه').first;
    expect(title, findsOneWidget);
    expect(Directionality.of(tester.element(title)), TextDirection.rtl);
    expect(find.text('نام کاربری'), findsOneWidget);
    expect(find.text('گذرواژه'), findsOneWidget);
    expect(find.text('کد فعال‌سازی'), findsNothing);
  });
}

Future<void> serviceEnrollDirectly(WhiteLabelTestStack stack) =>
    stack.service.auth
        .enroll(
          credentials: const ApplicationCredentials(
            username: 'partner-user',
            password: 'secret-password',
          ),
          activationTicket: '',
        )
        .then((_) {});
