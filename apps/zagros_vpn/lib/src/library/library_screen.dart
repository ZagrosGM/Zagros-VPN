import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tunnel_interface/tunnel_interface.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import '../../l10n/generated/app_localizations.dart';
import '../app_scope.dart';
import '../common/formatters.dart';
import '../config/product_configuration.dart';
import '../platform/raw_config_actions.dart';
import 'library_controller.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({required this.configuration, super.key});

  final ProductConfiguration configuration;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  LibraryController? _controller;
  RawConfigActions? _rawActions;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final dependencies = AppScope.of(context).dependencies;
    final repository = dependencies.officialProfiles;
    _rawActions = dependencies.rawConfigActions;
    if (repository != null) {
      final controller = LibraryController(
        configuration: widget.configuration,
        repository: repository,
        tunnelAdapter: dependencies.tunnelAdapter,
      );
      _controller = controller;
      unawaited(controller.load());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final controller = _controller;
    if (controller == null) {
      return _CenteredMessage(
        icon: Icons.lock_outline,
        title: localizations.libraryUnavailableTitle,
        body: localizations.libraryUnavailableBody,
      );
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Column(
        children: <Widget>[
          if (controller.mutating || controller.tunnelMutating)
            const LinearProgressIndicator(),
          _LibraryHeader(
            adapterAvailable: controller.adapterAvailable,
            tunnelSnapshot: controller.tunnelSnapshot,
            onDisconnect: controller.tunnelMutating ||
                    controller.tunnelSnapshot.state == TunnelState.disconnecting
                ? null
                : _disconnect,
            onAddSubscription: controller.mutating
                ? null
                : () => _openEditor(OfficialProfileKind.subscription),
            onAddManual: controller.mutating
                ? null
                : () => _openEditor(OfficialProfileKind.manual),
          ),
          if (controller.failure != null &&
              controller.loadState != LibraryLoadState.error)
            _FailureBanner(
              failure: controller.failure!,
              onDismiss: controller.clearFailure,
            ),
          Expanded(child: _content(controller)),
        ],
      ),
    );
  }

  Widget _content(LibraryController controller) {
    final localizations = AppLocalizations.of(context);
    return switch (controller.loadState) {
      LibraryLoadState.loading => const Center(
          child: CircularProgressIndicator(key: ValueKey('library-loading')),
        ),
      LibraryLoadState.error => _CenteredMessage(
          icon: Icons.error_outline,
          title: localizations.libraryLoadFailed,
          body: _failureText(localizations, controller.failure),
          action: FilledButton.icon(
            key: const ValueKey('library-retry'),
            onPressed: controller.load,
            icon: const Icon(Icons.refresh),
            label: Text(localizations.retry),
          ),
        ),
      LibraryLoadState.ready when controller.catalog.profiles.isEmpty =>
        _CenteredMessage(
          icon: Icons.inventory_2_outlined,
          title: localizations.libraryEmptyTitle,
          body: localizations.libraryEmptyBody,
        ),
      LibraryLoadState.ready => ListView.builder(
          key: const ValueKey('library-profile-list'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          itemCount: controller.catalog.profiles.length,
          itemBuilder: (context, index) {
            final profile = controller.catalog.profiles[index];
            return _ProfileCard(
              profile: profile,
              enabled: !controller.mutating,
              onOpen: () => _openProfile(profile),
              onRefresh:
                  profile.isSubscription ? () => _refresh(profile) : null,
              onEdit: () => _openEditor(profile.kind, profile: profile),
              onDelete: () => _confirmDelete(profile),
            );
          },
        ),
    };
  }

  Future<void> _openEditor(
    OfficialProfileKind kind, {
    OfficialProfile? profile,
  }) async {
    final controller = _controller!;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ProfileEditorDialog(
        kind: kind,
        profile: profile,
        controller: controller,
      ),
    );
    if (!mounted || saved != true) return;
    _showMessage(AppLocalizations.of(context).saved);
  }

  Future<void> _refresh(OfficialProfile profile) async {
    final success = await _controller!.refresh(profile.id);
    if (!mounted) return;
    _showMessage(
      success
          ? AppLocalizations.of(context).subscriptionRefreshed
          : _failureText(AppLocalizations.of(context), _controller!.failure),
    );
  }

  Future<void> _confirmDelete(OfficialProfile profile) async {
    final localizations = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(localizations.deleteProfileTitle),
        content: Text(localizations.deleteProfileBody(profile.name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(localizations.cancel),
          ),
          FilledButton(
            key: const ValueKey('confirm-delete-profile'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(localizations.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final success = await _controller!.delete(profile.id);
    if (!mounted) return;
    _showMessage(
      success
          ? localizations.deleted
          : _failureText(localizations, _controller!.failure),
    );
  }

  Future<void> _openProfile(OfficialProfile profile) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _ProfileDetailDialog(
        profile: profile,
        configuration: widget.configuration,
        rawActions: _rawActions,
        onConnect: (config) => _connect(dialogContext, config),
      ),
    );
  }

  Future<void> _connect(
    BuildContext dialogContext,
    OfficialConfigEntry config,
  ) async {
    final result = await _controller!.connect(config);
    if (!mounted || !dialogContext.mounted) return;
    final localizations = AppLocalizations.of(context);
    final (title, body) = switch (result) {
      OfficialConnectResult.adapterUnavailable => (
          localizations.tunnelUnavailableTitle,
          localizations.tunnelUnavailableBody,
        ),
      OfficialConnectResult.protocolUnavailable => (
          localizations.protocolUnavailableTitle,
          _controller!.protocolUnavailableReason ??
              localizations.protocolUnavailableBody(config.normalized.protocol),
        ),
      OfficialConnectResult.requestAccepted => (
          localizations.connectionRequestedTitle,
          localizations.connectionRequestedBody,
        ),
      OfficialConnectResult.connected => (
          localizations.connectedTitle,
          localizations.connectedBody,
        ),
      OfficialConnectResult.failed => (
          localizations.connectionFailedTitle,
          localizations.connectionFailedBody,
        ),
    };
    await showDialog<void>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        key: ValueKey('connection-result-${result.name}'),
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(localizations.ok),
          ),
        ],
      ),
    );
  }

  Future<void> _disconnect() async {
    final accepted = await _controller!.disconnect();
    if (!mounted || accepted) return;
    _showMessage(AppLocalizations.of(context).connectionFailedBody);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _LibraryHeader extends StatelessWidget {
  const _LibraryHeader({
    required this.adapterAvailable,
    required this.tunnelSnapshot,
    required this.onDisconnect,
    required this.onAddSubscription,
    required this.onAddManual,
  });

  final bool adapterAvailable;
  final TunnelSnapshot tunnelSnapshot;
  final VoidCallback? onDisconnect;
  final VoidCallback? onAddSubscription;
  final VoidCallback? onAddManual;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            localizations.libraryTitle,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 4),
          Text(localizations.libraryDescription),
          const SizedBox(height: 12),
          if (!adapterAvailable)
            Card(
              color: colorScheme.secondaryContainer,
              child: ListTile(
                key: const ValueKey('tunnel-unavailable-banner'),
                leading: const Icon(Icons.cable_outlined),
                title: Text(localizations.tunnelUnavailableTitle),
                subtitle: Text(localizations.tunnelUnavailableBody),
              ),
            )
          else if (tunnelSnapshot.state != TunnelState.disconnected)
            Card(
              color: tunnelSnapshot.state == TunnelState.failed
                  ? colorScheme.errorContainer
                  : colorScheme.primaryContainer,
              child: ListTile(
                key: ValueKey('tunnel-status-${tunnelSnapshot.state.name}'),
                leading: Icon(
                  tunnelSnapshot.state == TunnelState.connected
                      ? Icons.shield_outlined
                      : tunnelSnapshot.state == TunnelState.failed
                          ? Icons.error_outline
                          : Icons.sync,
                ),
                title: Text(
                  tunnelSnapshot.state == TunnelState.connected
                      ? localizations.connectedTitle
                      : tunnelSnapshot.state == TunnelState.failed
                          ? localizations.connectionFailedTitle
                          : localizations.connectionRequestedTitle,
                ),
                subtitle: Text(
                  tunnelSnapshot.state == TunnelState.connected
                      ? localizations.connectedBody
                      : tunnelSnapshot.state == TunnelState.failed
                          ? localizations.connectionFailedBody
                          : localizations.connectionRequestedBody,
                ),
                trailing: tunnelSnapshot.isActive ||
                        tunnelSnapshot.connectionId != null
                    ? TextButton(
                        key: const ValueKey('disconnect-tunnel'),
                        onPressed: onDisconnect,
                        child: Text(localizations.disconnect),
                      )
                    : null,
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                key: const ValueKey('library-add-subscription'),
                onPressed: onAddSubscription,
                icon: const Icon(Icons.add_link),
                label: Text(localizations.addSubscription),
              ),
              OutlinedButton.icon(
                key: const ValueKey('library-add-manual'),
                onPressed: onAddManual,
                icon: const Icon(Icons.note_add_outlined),
                label: Text(localizations.addManualConfig),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.enabled,
    required this.onOpen,
    required this.onRefresh,
    required this.onEdit,
    required this.onDelete,
  });

  final OfficialProfile profile;
  final bool enabled;
  final VoidCallback onOpen;
  final VoidCallback? onRefresh;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final warning = profile.configs.any(
      (config) => config.normalized.warnings.isNotEmpty,
    );
    return Card(
      key: ValueKey('profile-card-${profile.id}'),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: enabled ? onOpen : null,
        leading: Icon(
          profile.isSubscription ? Icons.link : Icons.description_outlined,
        ),
        title: Text(profile.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              profile.isSubscription
                  ? localizations.subscriptionProfile
                  : localizations.manualProfile,
            ),
            Text(localizations.profileConfigCount(profile.configs.length)),
            if (profile.subscriptionUri != null)
              Text(
                localizations.subscriptionHost(profile.subscriptionUri!.host),
              ),
            if (warning)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.warning_amber, size: 16),
                  const SizedBox(width: 4),
                  Text(localizations.protocolWarningPresent),
                ],
              ),
          ],
        ),
        isThreeLine: true,
        trailing: Wrap(
          spacing: 0,
          children: <Widget>[
            if (onRefresh != null)
              IconButton(
                key: ValueKey('profile-refresh-${profile.id}'),
                tooltip: localizations.refresh,
                onPressed: enabled ? onRefresh : null,
                icon: const Icon(Icons.refresh),
              ),
            IconButton(
              key: ValueKey('profile-edit-${profile.id}'),
              tooltip: localizations.edit,
              onPressed: enabled ? onEdit : null,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              key: ValueKey('profile-delete-${profile.id}'),
              tooltip: localizations.delete,
              onPressed: enabled ? onDelete : null,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileEditorDialog extends StatefulWidget {
  const _ProfileEditorDialog({
    required this.kind,
    required this.profile,
    required this.controller,
  });

  final OfficialProfileKind kind;
  final OfficialProfile? profile;
  final LibraryController controller;

  @override
  State<_ProfileEditorDialog> createState() => _ProfileEditorDialogState();
}

class _ProfileEditorDialogState extends State<_ProfileEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _source;
  bool _saving = false;

  bool get _subscription => widget.kind == OfficialProfileKind.subscription;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.profile?.name ?? '');
    _source = TextEditingController(
      text: _subscription
          ? widget.profile?.subscriptionUri?.toString() ?? ''
          : widget.profile?.rawSource ?? '',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final editing = widget.profile != null;
    return AlertDialog(
      title: Text(
        editing
            ? localizations.editProfile
            : _subscription
                ? localizations.addSubscription
                : localizations.addManualConfig,
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                key: const ValueKey('profile-name-field'),
                controller: _name,
                enabled: !_saving,
                maxLength: 128,
                decoration: InputDecoration(
                  labelText: localizations.profileName,
                ),
              ),
              TextField(
                key: ValueKey(
                  _subscription
                      ? 'subscription-url-field'
                      : 'manual-config-field',
                ),
                controller: _source,
                enabled: !_saving,
                keyboardType:
                    _subscription ? TextInputType.url : TextInputType.multiline,
                autocorrect: false,
                enableSuggestions: false,
                minLines: _subscription ? 1 : 6,
                maxLines: _subscription ? 2 : 12,
                decoration: InputDecoration(
                  labelText: _subscription
                      ? localizations.subscriptionUrl
                      : localizations.rawConfiguration,
                  helperText: _subscription
                      ? localizations.subscriptionUrlHelp
                      : localizations.manualConfigHelp,
                ),
              ),
              if (widget.controller.failure != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  _failureText(localizations, widget.controller.failure),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: Text(localizations.cancel),
        ),
        FilledButton(
          key: const ValueKey('save-profile'),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(localizations.save),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final profile = widget.profile;
    final success = switch ((widget.kind, profile)) {
      (OfficialProfileKind.subscription, null) =>
        await widget.controller.addSubscription(
          name: _name.text,
          url: _source.text,
        ),
      (OfficialProfileKind.manual, null) => await widget.controller.addManual(
          name: _name.text,
          rawSource: _source.text,
        ),
      (OfficialProfileKind.subscription, final existing?) =>
        await widget.controller.updateSubscription(
          profileId: existing.id,
          name: _name.text,
          url: _source.text,
        ),
      (OfficialProfileKind.manual, final existing?) =>
        await widget.controller.updateManual(
          profileId: existing.id,
          name: _name.text,
          rawSource: _source.text,
        ),
    };
    if (!mounted) return;
    if (success) {
      Navigator.pop(context, true);
    } else {
      setState(() => _saving = false);
    }
  }
}

class _ProfileDetailDialog extends StatelessWidget {
  const _ProfileDetailDialog({
    required this.profile,
    required this.configuration,
    required this.rawActions,
    required this.onConnect,
  });

  final OfficialProfile profile;
  final ProductConfiguration configuration;
  final RawConfigActions? rawActions;
  final Future<void> Function(OfficialConfigEntry config) onConnect;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 12, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      profile.name,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: localizations.close,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                localizations.profileConfigCount(profile.configs.length),
              ),
            ),
            if (profile.usage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: Text(
                  localizations.subscriptionUsage(
                    formatBytes(profile.usage!.usedBytes),
                    profile.usage!.totalBytes <= 0
                        ? localizations.unlimited
                        : formatBytes(profile.usage!.totalBytes),
                  ),
                ),
              ),
            if (profile.usage?.expiresAt != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Text(
                  localizations.subscriptionExpires(
                    formatDateTime(context, profile.usage!.expiresAt!),
                  ),
                ),
              ),
            if (profile.updateInterval != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Text(
                  localizations.subscriptionUpdateInterval(
                    profile.updateInterval!.inHours,
                  ),
                ),
              ),
            if (profile.lastRefreshedAt != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Text(
                  localizations.subscriptionLastRefreshed(
                    formatDateTime(context, profile.lastRefreshedAt!),
                  ),
                ),
              ),
            if (profile.fileErrors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Text(
                  localizations.subscriptionFilesUnavailable(
                    profile.fileErrors.length,
                  ),
                ),
              ),
            const Divider(),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                itemCount: profile.configs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 4),
                itemBuilder: (context, index) {
                  final config = profile.configs[index];
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.shield_outlined),
                            title: Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(config.normalized.displayName),
                                ),
                                if (config.source == OfficialConfigSource.file)
                                  Chip(
                                    key: ValueKey(
                                      'config-filebadge-${config.id}',
                                    ),
                                    label: Text(
                                      localizations.configFileBadge,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                  ),
                              ],
                            ),
                            subtitle: Text(
                              '${config.normalized.protocol.toUpperCase()} • '
                              '${config.normalized.endpoints.first.host}:'
                              '${config.normalized.endpoints.first.port}',
                            ),
                          ),
                          for (final warning in config.normalized.warnings)
                            _ProtocolWarning(code: warning),
                          Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 8,
                            children: <Widget>[
                              if (configuration.policy.allows(
                                ClientCapability.rawConfigDisplay,
                              ))
                                TextButton.icon(
                                  key: ValueKey('config-raw-${config.id}'),
                                  onPressed: () => _showRaw(context, config),
                                  icon: const Icon(Icons.code),
                                  label: Text(localizations.viewRawConfig),
                                ),
                              FilledButton.icon(
                                key: ValueKey('config-connect-${config.id}'),
                                onPressed: () => onConnect(config),
                                icon: const Icon(Icons.power_settings_new),
                                label: Text(localizations.connect),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showRaw(
    BuildContext context,
    OfficialConfigEntry config,
  ) async {
    configuration.policy.require(ClientCapability.rawConfigDisplay);
    await showDialog<void>(
      context: context,
      builder: (context) => _RawConfigDialog(
        config: config,
        configuration: configuration,
        actions: rawActions,
      ),
    );
  }
}

class _RawConfigDialog extends StatelessWidget {
  const _RawConfigDialog({
    required this.config,
    required this.configuration,
    required this.actions,
  });

  final OfficialConfigEntry config;
  final ProductConfiguration configuration;
  final RawConfigActions? actions;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    return AlertDialog(
      key: const ValueKey('raw-config-dialog'),
      title: Text(localizations.rawConfigTitle),
      content: SizedBox(
        width: 680,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.warning_amber),
                title: Text(localizations.rawConfigSecretWarning),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 420),
                padding: const EdgeInsets.all(12),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: SingleChildScrollView(
                  child: configuration.policy.allows(
                    ClientCapability.rawConfigClipboard,
                  )
                      ? SelectionArea(child: _rawText())
                      : _rawText(),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        if (actions != null &&
            configuration.policy.allows(ClientCapability.rawConfigClipboard))
          TextButton.icon(
            key: const ValueKey('raw-config-copy'),
            onPressed: () => _copy(context),
            icon: const Icon(Icons.copy),
            label: Text(localizations.copy),
          ),
        if (actions != null &&
            configuration.policy.allows(ClientCapability.rawConfigExport))
          TextButton.icon(
            key: const ValueKey('raw-config-export'),
            onPressed: () => _export(context),
            icon: const Icon(Icons.save_alt),
            label: Text(localizations.export),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(localizations.close),
        ),
      ],
    );
  }

  Widget _rawText() => Text(
        config.rawText,
        key: const ValueKey('raw-config-text'),
        style: const TextStyle(fontFamily: 'monospace'),
      );

  Future<void> _copy(BuildContext context) async {
    try {
      await actions!.copy(config.rawText);
      if (!context.mounted) return;
      _snack(context, AppLocalizations.of(context).copied);
    } catch (_) {
      if (!context.mounted) return;
      _snack(context, AppLocalizations.of(context).rawActionFailed);
    }
  }

  Future<void> _export(BuildContext context) async {
    final localizations = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(localizations.exportRawTitle),
        content: Text(localizations.exportRawWarning),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(localizations.cancel),
          ),
          FilledButton(
            key: const ValueKey('confirm-raw-export'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(localizations.export),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await actions!.export(
        rawConfig: config.rawText,
        suggestedName: 'zagros-${config.normalized.protocol}-${config.id}',
      );
      if (!context.mounted) return;
      _snack(context, localizations.exported);
    } catch (_) {
      if (!context.mounted) return;
      _snack(context, localizations.rawActionFailed);
    }
  }

  void _snack(BuildContext context, String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
}

class _ProtocolWarning extends StatelessWidget {
  const _ProtocolWarning({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final text = switch (code) {
      'legacy_insecure' => localizations.legacyProtocolWarning,
      'platform_support_conditional' => localizations.platformProtocolWarning,
      _ => localizations.genericProtocolWarning,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.warning_amber,
            size: 18,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 6),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _FailureBanner extends StatelessWidget {
  const _FailureBanner({required this.failure, required this.onDismiss});

  final LibraryFailureKind failure;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Card(
          color: Theme.of(context).colorScheme.errorContainer,
          child: ListTile(
            leading: const Icon(Icons.error_outline),
            title: Text(_failureText(AppLocalizations.of(context), failure)),
            trailing: IconButton(
              tooltip: AppLocalizations.of(context).close,
              onPressed: onDismiss,
              icon: const Icon(Icons.close),
            ),
          ),
        ),
      );
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 44),
                const SizedBox(height: 12),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(body, textAlign: TextAlign.center),
                if (action != null) ...<Widget>[
                  const SizedBox(height: 16),
                  action!,
                ],
              ],
            ),
          ),
        ),
      );
}

String _failureText(
  AppLocalizations localizations,
  LibraryFailureKind? failure,
) =>
    switch (failure) {
      LibraryFailureKind.validation => localizations.libraryValidationFailed,
      LibraryFailureKind.authorization => localizations.libraryAccessDenied,
      LibraryFailureKind.transport => localizations.libraryNetworkFailed,
      LibraryFailureKind.protectedStorage => localizations.libraryStorageFailed,
      LibraryFailureKind.malformedData => localizations.libraryMalformedFailed,
      LibraryFailureKind.unknown || null => localizations.libraryUnknownFailed,
    };
