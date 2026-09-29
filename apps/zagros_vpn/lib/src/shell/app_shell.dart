import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tunnel_interface/tunnel_interface.dart';

import '../../l10n/generated/app_localizations.dart';
import '../account/white_label_controller.dart';
import '../account/white_label_screen.dart';
import '../app_scope.dart';
import '../config/product_configuration.dart';
import '../configs/configs_screen.dart';
import '../home/home_screen.dart';
import '../library/library_controller.dart';
import '../logs/diagnostic_logs_service.dart';
import '../logs/logs_screen.dart';
import '../policy/navigation_policy.dart';
import '../settings/app_settings_controller.dart';
import '../settings/settings_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({required this.configuration, super.key});

  final ProductConfiguration configuration;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  var _selectedIndex = 0;
  LibraryController? _libraryController;
  WhiteLabelController? _whiteLabelController;
  DiagnosticLogsService? _logsService;
  AppSettingsController? _settingsController;
  StreamSubscription<TunnelSnapshot>? _tunnelLogSub;
  StreamSubscription<String>? _traceLogSub;
  bool _initialized = false;

  final _username = TextEditingController();
  final _password = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;

    final dependencies = AppScope.of(context).dependencies;
    _logsService = dependencies.logsService ?? DiagnosticLogsService();
    _settingsController = dependencies.settingsController ??
        AppSettingsController(
          initialLocale: widget.configuration.defaultLocale,
        );

    final adapter = dependencies.tunnelAdapter;
    _tunnelLogSub = adapter?.snapshots.listen(_onTunnelSnapshot);
    if (adapter is NativeTunnelAdapter) {
      _traceLogSub = adapter.traceLogs.listen(
        (line) => _logsService?.log(line),
      );
    }

    if (widget.configuration.isWhiteLabel) {
      final service = dependencies.whiteLabel;
      if (service != null) {
        final ctrl = WhiteLabelController(
          service: service,
          productMode: widget.configuration.mode,
          tunnelAdapter: adapter,
          settings: _settingsController,
        );
        _whiteLabelController = ctrl;
        unawaited(ctrl.start());
      }
    } else {
      final repository = dependencies.officialProfiles;
      if (repository != null) {
        final ctrl = LibraryController(
          configuration: widget.configuration,
          repository: repository,
          tunnelAdapter: adapter,
        );
        _libraryController = ctrl;
        unawaited(ctrl.load());
      }
    }
  }

  void _onTunnelSnapshot(TunnelSnapshot snapshot) {
    final logs = _logsService;
    if (logs == null) return;
    switch (snapshot.state) {
      case TunnelState.preparing:
      case TunnelState.connecting:
        logs.log('Connecting to VPN tunnel (seq: ${snapshot.sequence})...');
      case TunnelState.connected:
        logs.log(
            'VPN Established on interface tun0 (Tx: ${snapshot.uplinkBytes} B, Rx: ${snapshot.downlinkBytes} B)');
      case TunnelState.disconnecting:
        logs.log('Disconnecting VPN tunnel...');
      case TunnelState.disconnected:
        logs.log('VPN Disconnected safely.');
      case TunnelState.failed:
        logs.log(
            'VPN connection failed (${snapshot.failure?.code ?? 'unknown'}).');
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    unawaited(_tunnelLogSub?.cancel());
    unawaited(_traceLogSub?.cancel());
    _libraryController?.dispose();
    _whiteLabelController?.dispose();
    super.dispose();
  }

  void _select(int index) => setState(() => _selectedIndex = index);

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);

    // In White-label mode, if authentication is needed, render full-screen login/enroll without tabs
    if (widget.configuration.isWhiteLabel) {
      final ctrl = _whiteLabelController;
      if (ctrl == null) {
        return Scaffold(
          body: WhiteLabelAccountScreen(configuration: widget.configuration),
        );
      }
      return AnimatedBuilder(
        animation: ctrl,
        builder: (context, _) {
          return switch (ctrl.phase) {
            WhiteLabelPhase.initializing => const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              ),
            WhiteLabelPhase.needsEnrollment => Scaffold(
                body: WhiteLabelAccountScreen(
                  configuration: widget.configuration,
                  controller: ctrl,
                ),
              ),
            WhiteLabelPhase.needsLogin => Scaffold(
                body: WhiteLabelAccountScreen(
                  configuration: widget.configuration,
                  controller: ctrl,
                ),
              ),
            WhiteLabelPhase.ready => _buildMainShell(context, localizations),
          };
        },
      );
    }

    return _buildMainShell(context, localizations);
  }

  Widget _buildMainShell(BuildContext context, AppLocalizations localizations) {
    final destinations = destinationsFor(widget.configuration);
    if (_selectedIndex >= destinations.length) _selectedIndex = 0;

    final navigationDestinations = destinations
        .map(
          (destination) => NavigationDestination(
            icon: Icon(_icon(destination)),
            selectedIcon: Icon(_selectedIcon(destination)),
            label: _label(localizations, destination),
          ),
        )
        .toList(growable: false);

    final railDestinations = destinations
        .map(
          (destination) => NavigationRailDestination(
            icon: Icon(_icon(destination)),
            selectedIcon: Icon(_selectedIcon(destination)),
            label: Text(_label(localizations, destination)),
          ),
        )
        .toList(growable: false);

    final content = _buildContent(destinations[_selectedIndex]);

    return Scaffold(
      appBar: _selectedIndex == 0
          ? AppBar(
              title: Text(widget.configuration.appName),
              centerTitle: false,
            )
          : null,
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 720) {
            return Row(
              children: <Widget>[
                NavigationRail(
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: _select,
                  labelType: NavigationRailLabelType.all,
                  destinations: railDestinations,
                ),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ],
            );
          }
          return content;
        },
      ),
      bottomNavigationBar: MediaQuery.sizeOf(context).width < 720
          ? NavigationBar(
              selectedIndex: _selectedIndex,
              onDestinationSelected: _select,
              destinations: navigationDestinations,
            )
          : null,
    );
  }

  Widget _buildContent(AppDestination destination) {
    return switch (destination) {
      AppDestination.home => HomeScreen(
          configuration: widget.configuration,
          libraryController: _libraryController,
          whiteLabelController: _whiteLabelController,
          onNavigateToConfigs: () => _select(1),
        ),
      AppDestination.configs => ConfigsScreen(
          configuration: widget.configuration,
          libraryController: _libraryController,
          whiteLabelController: _whiteLabelController,
          rawActions: AppScope.of(context).dependencies.rawConfigActions,
        ),
      AppDestination.logs => LogsScreen(
          logsService: _logsService,
        ),
      AppDestination.settings => SettingsScreen(
          configuration: widget.configuration,
          settingsController: _settingsController,
          whiteLabelController: _whiteLabelController,
        ),
    };
  }
}

String _label(AppLocalizations localizations, AppDestination destination) =>
    switch (destination) {
      AppDestination.home => localizations.home,
      AppDestination.configs => localizations.configs,
      AppDestination.logs => localizations.logs,
      AppDestination.settings => localizations.settings,
    };

IconData _icon(AppDestination destination) => switch (destination) {
      AppDestination.home => Icons.home_outlined,
      AppDestination.configs => Icons.dns_outlined,
      AppDestination.logs => Icons.article_outlined,
      AppDestination.settings => Icons.settings_outlined,
    };

IconData _selectedIcon(AppDestination destination) => switch (destination) {
      AppDestination.home => Icons.home_rounded,
      AppDestination.configs => Icons.dns_rounded,
      AppDestination.logs => Icons.article_rounded,
      AppDestination.settings => Icons.settings_rounded,
    };
