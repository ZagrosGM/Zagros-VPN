import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tunnel_interface/tunnel_interface.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import '../../l10n/generated/app_localizations.dart';
import '../app_scope.dart';
import '../common/formatters.dart';
import '../config/product_configuration.dart';
import 'white_label_controller.dart';

/// Application account destination: enrollment, login, server-provided
/// config list, usage, and native connect/disconnect.
///
/// Raw configuration is never displayed, copied, exported, or persisted
/// here. Only server-provided display names, protocol labels, and statuses
/// are rendered; runtime config bytes stay inside the SDK acquisition and
/// are passed opaquely to the native adapter.
class WhiteLabelAccountScreen extends StatefulWidget {
  const WhiteLabelAccountScreen({
    required this.configuration,
    this.controller,
    super.key,
  });

  final ProductConfiguration configuration;
  final WhiteLabelController? controller;

  @override
  State<WhiteLabelAccountScreen> createState() =>
      _WhiteLabelAccountScreenState();
}

class _WhiteLabelAccountScreenState extends State<WhiteLabelAccountScreen> {
  WhiteLabelController? _controller;
  bool _initialized = false;
  final _username = TextEditingController();
  final _password = TextEditingController();
  WhiteLabelConnectResult? _shownResult;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    if (widget.controller != null) {
      _controller = widget.controller;
      return;
    }
    final dependencies = AppScope.of(context).dependencies;
    final service = dependencies.whiteLabel;
    if (service != null) {
      final controller = WhiteLabelController(
        service: service,
        productMode: widget.configuration.mode,
        tunnelAdapter: dependencies.tunnelAdapter,
      );
      _controller = controller;
      unawaited(controller.start());
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    if (widget.controller == null) {
      _controller?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final controller = _controller;
    if (controller == null) {
      return _CenteredMessage(
        icon: Icons.lock_outline,
        title: localizations.serviceUnavailableTitle,
        body: localizations.serviceUnavailableBody,
      );
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        _maybeShowConnectResult(context, controller);
        return switch (controller.phase) {
          WhiteLabelPhase.initializing => const Center(
            child: CircularProgressIndicator(),
          ),
          // Enrollment and login are the same two-field form: the device is
          // proven by the build-embedded signing key, so the user never
          // enters an activation code. Only the submit action differs.
          WhiteLabelPhase.needsEnrollment => _LoginForm(
            username: _username,
            password: _password,
            busy: controller.authenticating || controller.enrolling,
            error: _errorText(localizations, controller),
            onSubmit: () => _submitEnroll(controller),
            submitKey: 'wl-enroll-submit',
            title: localizations.enrollTitle,
          ),
          WhiteLabelPhase.needsLogin => _LoginForm(
            username: _username,
            password: _password,
            busy: controller.authenticating || controller.enrolling,
            error: _errorText(localizations, controller),
            onSubmit: () => _submitLogin(controller),
          ),
          WhiteLabelPhase.ready => _AccountReady(
            controller: controller,
            onRefresh: controller.working
                ? null
                : () => unawaited(controller.refreshData()),
            onLogout: () => unawaited(controller.logout()),
            onConnect: controller.connecting
                ? null
                : (selector) => unawaited(_connect(controller, selector)),
            onDisconnect: controller.disconnecting
                ? null
                : () => unawaited(controller.disconnect()),
          ),
        };
      },
    );
  }

  void _maybeShowConnectResult(
    BuildContext context,
    WhiteLabelController controller,
  ) {
    final result = controller.connectResult;
    if (result == null || result == _shownResult) return;
    _shownResult = result;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final localizations = AppLocalizations.of(context);
      final (title, body) = switch (result) {
        WhiteLabelConnectResult.adapterUnavailable => (
          localizations.tunnelUnavailableTitle,
          localizations.tunnelUnavailableBody,
        ),
        WhiteLabelConnectResult.protocolUnavailable => (
          localizations.protocolUnavailableTitle,
          controller.protocolUnavailableReason ??
              localizations.protocolUnavailableBody(
                controller.attemptedProtocol ?? '',
              ),
        ),
        WhiteLabelConnectResult.alreadyConnected => (
          localizations.alreadyConnectedTitle,
          localizations.alreadyConnectedBody,
        ),
        WhiteLabelConnectResult.requestAccepted => (
          localizations.connectionRequestedTitle,
          localizations.connectionRequestedBody,
        ),
        WhiteLabelConnectResult.connected => (
          localizations.connectedTitle,
          localizations.connectedBody,
        ),
        WhiteLabelConnectResult.failed => (
          localizations.connectionFailedTitle,
          localizations.connectionFailedBody,
        ),
      };
      unawaited(
        showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            key: ValueKey('connection-result-${result.name}'),
            title: Text(title),
            content: Text(body),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(localizations.ok),
              ),
            ],
          ),
        ),
      );
    });
  }

  Future<void> _submitEnroll(WhiteLabelController controller) async {
    final username = _username.text;
    final password = _password.text;
    _password.clear();
    await controller.enroll(
      username: username,
      password: password,
    );
  }

  Future<void> _submitLogin(WhiteLabelController controller) async {
    final username = _username.text;
    final password = _password.text;
    _password.clear();
    await controller.login(username: username, password: password);
  }

  Future<void> _connect(
    WhiteLabelController controller,
    ConfigSelector selector,
  ) => controller.connect(selector);
}

String _errorText(
  AppLocalizations localizations,
  WhiteLabelController controller,
) => switch (controller.error) {
  WhiteLabelError.none => '',
  WhiteLabelError.invalidInput =>
    controller.phase == WhiteLabelPhase.needsEnrollment
        ? localizations.errorEnrollInput
        : localizations.errorLoginInput,
  WhiteLabelError.invalidCredentials => localizations.errorInvalidCredentials,
  WhiteLabelError.ticketInvalid => localizations.errorTicketInvalid,
  WhiteLabelError.accessDenied => localizations.errorAccessDenied,
  WhiteLabelError.sessionExpired => localizations.errorSessionExpired,
  WhiteLabelError.enrollmentRequired => localizations.errorEnrollmentRequired,
  WhiteLabelError.networkUnreachable => localizations.errorNetwork,
  WhiteLabelError.rateLimited => localizations.errorRateLimited,
  WhiteLabelError.storageUnavailable => localizations.errorStorage,
  WhiteLabelError.unknown => localizations.errorUnknown,
};

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    if (message.isEmpty) return const SizedBox.shrink();
    return Card(
      key: const ValueKey('wl-error'),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Semantics(
          liveRegion: true,
          child: Text(
            message,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
        ),
      ),
    );
  }
}


class _LoginForm extends StatelessWidget {
  const _LoginForm({
    required this.username,
    required this.password,
    required this.busy,
    required this.error,
    required this.onSubmit,
    this.submitKey = 'wl-login-submit',
    this.title,
  });

  final TextEditingController username;
  final TextEditingController password;
  final bool busy;
  final String error;
  final Future<void> Function() onSubmit;
  final String submitKey;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    return _FormScaffold(
      title: title ?? localizations.loginTitle,
      children: <Widget>[
        _ErrorBanner(message: error),
        TextField(
          key: const ValueKey('wl-username'),
          controller: username,
          enabled: !busy,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const <String>[AutofillHints.username],
          decoration: InputDecoration(labelText: localizations.usernameLabel),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('wl-password'),
          controller: password,
          enabled: !busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const <String>[AutofillHints.password],
          decoration: InputDecoration(labelText: localizations.passwordLabel),
        ),
        const SizedBox(height: 20),
        FilledButton(
          key: ValueKey(submitKey),
          onPressed: busy ? null : onSubmit,
          child: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(localizations.loginAction),
        ),
      ],
    );
  }
}

class _FormScaffold extends StatelessWidget {
  const _FormScaffold({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: ListView(
        padding: const EdgeInsets.all(24),
        shrinkWrap: true,
        children: <Widget>[
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          AutofillGroup(child: Column(children: children)),
        ],
      ),
    ),
  );
}

class _AccountReady extends StatelessWidget {
  const _AccountReady({
    required this.controller,
    required this.onRefresh,
    required this.onLogout,
    required this.onConnect,
    required this.onDisconnect,
  });

  final WhiteLabelController controller;
  final void Function()? onRefresh;
  final void Function() onLogout;
  final void Function(ConfigSelector selector)? onConnect;
  final void Function()? onDisconnect;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final profile = controller.profile;
    final usage = controller.usage;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                localizations.configsTitle,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            if (controller.working)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            IconButton(
              key: const ValueKey('wl-refresh'),
              tooltip: localizations.refresh,
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_outlined),
            ),
            IconButton(
              key: const ValueKey('wl-logout'),
              tooltip: localizations.logoutAction,
              onPressed: onLogout,
              icon: const Icon(Icons.logout_outlined),
            ),
          ],
        ),
        if (profile != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              localizations.signedInAs(profile.username),
              key: const ValueKey('wl-account-info'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        _ErrorBanner(message: _errorText(localizations, controller)),
        if (controller.hasActiveConnection)
          _ActiveConnectionCard(
            controller: controller,
            onDisconnect: onDisconnect,
          ),
        if (usage != null)
          _UsageCard(usage: usage, expiresAt: profile?.expiresAt),
        if (controller.selectors.isEmpty)
          Card(
            child: ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: Text(localizations.noConfigsTitle),
              subtitle: Text(localizations.noConfigsBody),
            ),
          )
        else
          for (var index = 0; index < controller.selectors.length; index++)
            _ConfigRow(
              index: index,
              selector: controller.selectors[index],
              isActive:
                  controller.activeSelector?.configId ==
                      controller.selectors[index].configId &&
                  controller.selectors[index].configId != null,
              onConnect: onConnect,
            ),
      ],
    );
  }
}

class _ActiveConnectionCard extends StatelessWidget {
  const _ActiveConnectionCard({
    required this.controller,
    required this.onDisconnect,
  });

  final WhiteLabelController controller;
  final void Function()? onDisconnect;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final connected = controller.tunnelSnapshot.state == TunnelState.connected;
    return Card(
      key: const ValueKey('wl-active-connection'),
      color: connected
          ? Theme.of(context).colorScheme.primaryContainer
          : Theme.of(context).colorScheme.secondaryContainer,
      child: ListTile(
        leading: connected
            ? const Icon(Icons.vpn_lock_outlined)
            : const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
        title: Text(
          connected
              ? localizations.connectedTitle
              : localizations.connectionRequestedTitle,
        ),
        subtitle: Text(
          controller.activeSelector?.displayName ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: FilledButton.tonal(
          key: const ValueKey('wl-disconnect'),
          onPressed: onDisconnect,
          child: Text(localizations.disconnect),
        ),
      ),
    );
  }
}

class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.usage, required this.expiresAt});

  final UsageSummary usage;
  final DateTime? expiresAt;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final total = usage.remainingBytes != null
        ? formatBytes(usage.usedBytes + usage.remainingBytes!)
        : localizations.unlimited;
    return Card(
      key: const ValueKey('wl-usage'),
      child: ListTile(
        leading: const Icon(Icons.data_usage_outlined),
        title: Text(localizations.usageTitle),
        subtitle: Text(
          <String>[
            localizations.subscriptionUsage(
              formatBytes(usage.usedBytes),
              total,
            ),
            if (expiresAt != null)
              localizations.subscriptionExpires(
                formatDateTime(context, expiresAt!),
              ),
            localizations.activeConnectionsCount(usage.activeConnections),
          ].join('\n'),
        ),
        isThreeLine: true,
      ),
    );
  }
}

class _ConfigRow extends StatelessWidget {
  const _ConfigRow({
    required this.index,
    required this.selector,
    required this.isActive,
    required this.onConnect,
  });

  final int index;
  final ConfigSelector selector;
  final bool isActive;
  final void Function(ConfigSelector selector)? onConnect;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final engine = selector.engine.trim();
    final protocolLine = engine.isEmpty
        ? selector.protocol
        : '${selector.protocol} • $engine';
    return Card(
      key: ValueKey('wl-config-$index'),
      child: ListTile(
        leading: Icon(isActive ? Icons.vpn_lock_outlined : Icons.dns_outlined),
        title: Text(
          selector.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '$protocolLine\n${selector.connectable ? localizations.available : localizations.unavailable}',
        ),
        isThreeLine: true,
        trailing: selector.connectable
            ? FilledButton(
                key: ValueKey('wl-connect-$index'),
                onPressed: isActive || onConnect == null
                    ? null
                    : () => onConnect!(selector),
                child: Text(localizations.connect),
              )
            : null,
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 52),
            const SizedBox(height: 20),
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(body, textAlign: TextAlign.center),
          ],
        ),
      ),
    ),
  );
}
