import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../l10n/generated/app_localizations.dart';
import 'app_dependencies.dart';
import 'app_scope.dart';
import 'config/product_configuration.dart';
import 'settings/app_settings_controller.dart';
import 'shell/app_shell.dart';
import 'theme/zagros_theme.dart';

class ZagrosApp extends StatefulWidget {
  const ZagrosApp({
    required this.configuration,
    required this.dependencies,
    super.key,
  });

  final ProductConfiguration configuration;
  final AppDependencies dependencies;

  @override
  State<ZagrosApp> createState() => _ZagrosAppState();
}

class _ZagrosAppState extends State<ZagrosApp> with WidgetsBindingObserver {
  Future<void>? _shutdown;
  late final AppSettingsController _settings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // f53: the shared controller is created in main() and handed to the
    // dependencies. The fallback below stays only for isolated widget tests.
    _settings = widget.dependencies.settingsController ??
        AppSettingsController(
          initialLocale: widget.configuration.defaultLocale,
        );
  }

  Future<void> _disposeDependencies() =>
      _shutdown ??= widget.dependencies.dispose();

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await _disposeDependencies();
    return AppExitResponse.exit;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(_disposeDependencies());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_disposeDependencies());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppScope(
        configuration: widget.configuration,
        dependencies: widget.dependencies,
        child: ListenableBuilder(
          listenable: _settings,
          builder: (context, _) => MaterialApp(
            debugShowCheckedModeBanner: false,
            onGenerateTitle: (_) => widget.configuration.appName,
            locale: _settings.locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: buildZagrosTheme(Brightness.light),
            darkTheme: buildZagrosTheme(Brightness.dark),
            home: AppShell(configuration: widget.configuration),
          ),
        ),
      );
}

class ConfigurationErrorApp extends StatelessWidget {
  const ConfigurationErrorApp({this.locale, super.key});

  final Locale? locale;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: buildZagrosTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    AppLocalizations.of(context).configurationError,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
