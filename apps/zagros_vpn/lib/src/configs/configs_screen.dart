import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tunnel_interface/tunnel_interface.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import '../../l10n/generated/app_localizations.dart';
import '../account/white_label_controller.dart';
import '../common/formatters.dart';
import '../config/product_configuration.dart';
import '../library/library_controller.dart';
import '../platform/raw_config_actions.dart';

const _supportedProtocols = <String>{
  'vless',
  'vmess',
  'trojan',
  'shadowsocks',
  'ss',
  'hysteria2',
  'hy2',
  'tuic',
  'wireguard',
  'ssh',
  'anytls',
  'openvpn',
  'ovpn',
  // Embedded userspace-PPP SSTP engine (third_party/sstp-client, MIT).
  // Android-only, same as the OpenVPN engine above; the native capability
  // check at connect time remains the source of truth per platform.
  'sstp',
  // Embedded raw-L2TP engine (userspace PPP over L2TP/UDP; reuses the same
  // MIT PPP core). No IPsec encryption — the panel flags this in the config.
  'l2tp_raw',
  // L2TP/IPsec: our own userspace IKEv1 Main-Mode PSK + Quick Mode + ESP
  // (in-process, MIT-clean) carrying the same L2TP stream inside UDP/4500.
  'l2tp',
  // SoftEther native (SSL-VPN): our own TLS block-stream client + Ethernet
  // shim (in-process, MIT-clean, no third-party GPL code).
  'softether',
};

bool isProtocolSupported(String protocol) =>
    _supportedProtocols.contains(protocol.toLowerCase());

class ConfigsScreen extends StatelessWidget {
  const ConfigsScreen({
    required this.configuration,
    this.libraryController,
    this.whiteLabelController,
    this.rawActions,
    super.key,
  });

  final ProductConfiguration configuration;
  final LibraryController? libraryController;
  final WhiteLabelController? whiteLabelController;
  final RawConfigActions? rawActions;

  @override
  Widget build(BuildContext context) {
    if (configuration.isWhiteLabel) {
      return _WhiteLabelConfigsView(
        controller: whiteLabelController,
        configuration: configuration,
      );
    }
    return _OfficialConfigsView(
      controller: libraryController,
      configuration: configuration,
      rawActions: rawActions,
    );
  }
}

class _OfficialConfigsView extends StatefulWidget {
  const _OfficialConfigsView({
    required this.controller,
    required this.configuration,
    required this.rawActions,
  });

  final LibraryController? controller;
  final ProductConfiguration configuration;
  final RawConfigActions? rawActions;

  @override
  State<_OfficialConfigsView> createState() => _OfficialConfigsViewState();
}

class _OfficialConfigsViewState extends State<_OfficialConfigsView> {
  final Set<String> _expandedProfileIds = <String>{};

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final ctrl = widget.controller;
    if (ctrl == null) {
      return Center(
        child: Text(localizations.libraryUnavailableBody),
      );
    }

    return AnimatedBuilder(
      animation: ctrl,
      builder: (context, _) {
        if (ctrl.loadState == LibraryLoadState.loading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (ctrl.loadState == LibraryLoadState.error) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(localizations.libraryLoadFailed),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: ctrl.load,
                  icon: const Icon(Icons.refresh),
                  label: Text(localizations.retry),
                ),
              ],
            ),
          );
        }

        final banner = _buildTunnelBanner(context, ctrl, localizations);

        if (ctrl.catalog.profiles.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (banner != null) ...<Widget>[
                    banner,
                    const SizedBox(height: 16),
                  ],
                  const Icon(Icons.dns_outlined, size: 56),
                  const SizedBox(height: 16),
                  Text(
                    localizations.libraryEmptyTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    localizations.libraryEmptyBody,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    children: <Widget>[
                      FilledButton.icon(
                        key: const ValueKey('library-add-subscription'),
                        onPressed: () => _openEditor(
                            context, ctrl, OfficialProfileKind.subscription),
                        icon: const Icon(Icons.add_link),
                        label: Text(localizations.addSubscription),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey('library-add-manual'),
                        onPressed: () => _openEditor(
                            context, ctrl, OfficialProfileKind.manual),
                        icon: const Icon(Icons.note_add_outlined),
                        label: Text(localizations.addManualConfig),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }

        final subscriptions =
            ctrl.catalog.profiles.where((p) => p.isSubscription).toList();
        final manualProfiles =
            ctrl.catalog.profiles.where((p) => !p.isSubscription).toList();

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: <Widget>[
            if (banner != null) ...<Widget>[
              banner,
              const SizedBox(height: 12),
            ],
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      localizations.configsTitle,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  IconButton.filledTonal(
                    key: const ValueKey('library-add-subscription'),
                    tooltip: localizations.addSubscription,
                    onPressed: () => _openEditor(
                        context, ctrl, OfficialProfileKind.subscription),
                    icon: const Icon(Icons.add_link, size: 20),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    key: const ValueKey('library-add-manual'),
                    tooltip: localizations.addManualConfig,
                    onPressed: () =>
                        _openEditor(context, ctrl, OfficialProfileKind.manual),
                    icon: const Icon(Icons.note_add_outlined, size: 20),
                  ),
                ],
              ),
            ),
            if (subscriptions.isNotEmpty) ...<Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  localizations.subscriptionsSection,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
              for (final profile in subscriptions)
                _buildProfileCard(context, ctrl, profile, localizations),
            ],
            if (manualProfiles.isNotEmpty) ...<Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 6),
                child: Text(
                  localizations.localConfigsSection,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
              for (final profile in manualProfiles)
                _buildProfileCard(context, ctrl, profile, localizations),
            ],
          ],
        );
      },
    );
  }

  Widget? _buildTunnelBanner(
    BuildContext context,
    LibraryController ctrl,
    AppLocalizations localizations,
  ) {
    if (ctrl.tunnelAdapter != null) return null;
    return Card(
      key: const ValueKey('tunnel-unavailable-banner'),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            Icon(Icons.warning_amber_rounded,
                color: Theme.of(context).colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                localizations.tunnelUnavailableTitle,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileCard(
    BuildContext context,
    LibraryController ctrl,
    OfficialProfile profile,
    AppLocalizations localizations,
  ) {
    final theme = Theme.of(context);
    final isExpanded = _expandedProfileIds.contains(profile.id);

    return Card(
      key: ValueKey('profile-card-${profile.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withAlpha(100),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isExpanded
              ? theme.colorScheme.primary.withAlpha(120)
              : theme.colorScheme.outlineVariant.withAlpha(50),
          width: isExpanded ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              setState(() {
                if (_expandedProfileIds.contains(profile.id)) {
                  _expandedProfileIds.remove(profile.id);
                } else {
                  _expandedProfileIds.add(profile.id);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: <Widget>[
                  Icon(
                    profile.isSubscription
                        ? Icons.link_rounded
                        : Icons.description_outlined,
                    color: theme.colorScheme.primary,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          profile.name,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (profile.subscriptionUri?.host != null)
                          Text(
                            localizations.subscriptionHost(
                                profile.subscriptionUri!.host),
                            style: theme.textTheme.bodySmall,
                          ),
                        Text(
                          localizations
                              .profileConfigCount(profile.configs.length),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (profile.isSubscription)
                    IconButton(
                      key: ValueKey('profile-refresh-${profile.id}'),
                      icon: const Icon(Icons.refresh, size: 20),
                      tooltip: localizations.refresh,
                      onPressed: () async {
                        final ok = await ctrl.refresh(profile.id);
                        if (!ok && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                _failureText(localizations, ctrl.failure),
                              ),
                            ),
                          );
                        }
                      },
                    ),
                  IconButton(
                    key: ValueKey('profile-edit-${profile.id}'),
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    tooltip: localizations.edit,
                    onPressed: () => _openEditor(context, ctrl, profile.kind,
                        existing: profile),
                  ),
                  IconButton(
                    key: ValueKey('profile-delete-${profile.id}'),
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: localizations.delete,
                    onPressed: () => _confirmDelete(context, ctrl, profile),
                  ),
                  IconButton(
                    tooltip: isExpanded
                        ? localizations.close
                        : localizations.viewRawConfig,
                    icon: Icon(
                      isExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onPressed: () {
                      setState(() {
                        if (_expandedProfileIds.contains(profile.id)) {
                          _expandedProfileIds.remove(profile.id);
                        } else {
                          _expandedProfileIds.add(profile.id);
                        }
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded) ...<Widget>[
            const Divider(height: 1),
            if (profile.usage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                child: Text(
                  localizations.subscriptionUsage(
                    formatBytes(profile.usage!.usedBytes),
                    profile.usage!.totalBytes <= 0
                        ? localizations.unlimited
                        : formatBytes(profile.usage!.totalBytes),
                  ),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            if (profile.usage?.expiresAt != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                child: Text(
                  localizations.subscriptionExpires(
                    formatDateTime(context, profile.usage!.expiresAt!),
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (profile.updateInterval != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                child: Text(
                  localizations.subscriptionUpdateInterval(
                    profile.updateInterval!.inHours,
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (profile.lastRefreshedAt != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                child: Text(
                  localizations.subscriptionLastRefreshed(
                    formatDateTime(context, profile.lastRefreshedAt!),
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (profile.fileErrors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                child: Text(
                  localizations.subscriptionFilesUnavailable(
                    profile.fileErrors.length,
                  ),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 6),
            for (final config in profile.configs)
              _buildConfigItem(context, ctrl, config, localizations),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildConfigItem(
    BuildContext context,
    LibraryController ctrl,
    OfficialConfigEntry config,
    AppLocalizations localizations,
  ) {
    final theme = Theme.of(context);
    final proto = config.normalized.protocol.toLowerCase();
    final supported = isProtocolSupported(proto);
    final isSelected = ctrl.selectedEntry?.id == config.id;
    final isConnected = ctrl.tunnelSnapshot.connectionId == config.id &&
        ctrl.tunnelSnapshot.state == TunnelState.connected;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: isConnected
            ? const Color(0xFF00C853).withAlpha(40)
            : isSelected
                ? theme.colorScheme.primaryContainer.withAlpha(120)
                : theme.colorScheme.surface.withAlpha(180),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isConnected
              ? const Color(0xFF00C853)
              : isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant.withAlpha(50),
          width: (isConnected || isSelected) ? 2.0 : 1.0,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (!supported) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '${config.normalized.protocol.toUpperCase()}: ${localizations.comingSoon}',
                ),
              ),
            );
            return;
          }
          ctrl.selectEntry(config);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: const Duration(milliseconds: 1200),
              content: Text(
                  '${config.normalized.displayName} (${proto.toUpperCase()}) انتخاب شد'),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 20,
                    color: isSelected
                        ? (isConnected
                            ? const Color(0xFF00C853)
                            : theme.colorScheme.primary)
                        : theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          config.normalized.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight:
                                isSelected ? FontWeight.bold : FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${config.normalized.protocol.toUpperCase()} • '
                          '${config.normalized.endpoints.first.host}:'
                          '${config.normalized.endpoints.first.port}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (config.source == OfficialConfigSource.file)
                    Chip(
                      key: ValueKey('config-filebadge-${config.id}'),
                      label: Text(localizations.configFileBadge),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              for (final warning in config.normalized.warnings)
                _ProtocolWarning(code: warning),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 6,
                children: <Widget>[
                  if (widget.configuration.policy.allows(
                    ClientCapability.rawConfigDisplay,
                  ))
                    TextButton.icon(
                      key: ValueKey('config-raw-${config.id}'),
                      onPressed: () => _showRaw(context, config),
                      icon: const Icon(Icons.code, size: 18),
                      label: Text(localizations.viewRawConfig),
                    ),
                  if (!supported)
                    Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer.withAlpha(160),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        localizations.comingSoon,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )
                  else if (isConnected)
                    IconButton(
                      key: ValueKey('config-connect-${config.id}'),
                      icon: const Icon(Icons.stop_circle_outlined,
                          color: Color(0xFF00C853)),
                      tooltip: localizations.disconnect,
                      onPressed: ctrl.disconnect,
                    )
                  else
                    IconButton(
                      key: ValueKey('config-connect-${config.id}'),
                      icon: const Icon(Icons.play_circle_outline),
                      tooltip: localizations.connect,
                      onPressed: () async {
                        ctrl.selectEntry(config);
                        final res = await ctrl.connect(config);
                        if (context.mounted &&
                            res != OfficialConnectResult.connected &&
                            res != OfficialConnectResult.requestAccepted) {
                          final msg = ctrl.protocolUnavailableReason ??
                              switch (res) {
                                OfficialConnectResult.adapterUnavailable =>
                                  localizations.tunnelUnavailableBody,
                                OfficialConnectResult.protocolUnavailable =>
                                  ctrl.protocolUnavailableReason ??
                                      localizations.protocolUnavailableBody(
                                          config.normalized.protocol),
                                _ => localizations.tunnelUnavailableBody,
                              };
                          showDialog<void>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              key: ValueKey('connection-result-${res.name}'),
                              title: Text(localizations.tunnelUnavailableTitle),
                              content: Text(msg),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: Text(localizations.ok),
                                ),
                              ],
                            ),
                          );
                        }
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showRaw(
    BuildContext context,
    OfficialConfigEntry config,
  ) async {
    widget.configuration.policy.require(ClientCapability.rawConfigDisplay);
    await showDialog<void>(
      context: context,
      builder: (context) => _RawConfigDialog(
        config: config,
        configuration: widget.configuration,
        actions: widget.rawActions,
      ),
    );
  }

  Future<void> _openEditor(
    BuildContext context,
    LibraryController ctrl,
    OfficialProfileKind kind, {
    OfficialProfile? existing,
  }) async {
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => _ProfileEditorDialog(
        kind: kind,
        profile: existing,
        controller: ctrl,
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    LibraryController ctrl,
    OfficialProfile profile,
  ) async {
    final localizations = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(localizations.deleteProfileTitle),
        content: Text(localizations.deleteProfileBody(profile.name)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(localizations.cancel),
          ),
          FilledButton(
            key: const ValueKey('confirm-delete-profile'),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(localizations.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ctrl.delete(profile.id);
    }
  }
}

class _ProfileEditorDialog extends StatefulWidget {
  const _ProfileEditorDialog({
    required this.kind,
    required this.controller,
    this.profile,
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
                  child: configuration.policy
                          .allows(ClientCapability.rawConfigDisplay)
                      ? _rawText()
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        if (actions != null &&
            configuration.policy.allows(ClientCapability.rawConfigDisplay))
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
            Icons.warning_amber_rounded,
            color: Theme.of(context).colorScheme.error,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WhiteLabelConfigsView extends StatelessWidget {
  const _WhiteLabelConfigsView({
    required this.controller,
    required this.configuration,
  });

  final WhiteLabelController? controller;
  final ProductConfiguration configuration;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final ctrl = controller;
    if (ctrl == null) {
      return Center(child: Text(localizations.serviceUnavailableBody));
    }

    return AnimatedBuilder(
      animation: ctrl,
      builder: (context, _) {
        if (ctrl.working) {
          return const Center(child: CircularProgressIndicator());
        }
        if (ctrl.selectors.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.dns_outlined, size: 56),
                const SizedBox(height: 16),
                Text(
                  localizations.noConfigsTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(localizations.noConfigsBody),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: ctrl.refreshData,
                  icon: const Icon(Icons.refresh),
                  label: Text(localizations.refresh),
                ),
              ],
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      localizations.configsTitle,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                  IconButton(
                    tooltip: localizations.refresh,
                    onPressed: ctrl.refreshData,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            for (var i = 0; i < ctrl.selectors.length; i++)
              _buildSelectorCard(
                  context, ctrl, ctrl.selectors[i], i, localizations),
          ],
        );
      },
    );
  }

  Widget _buildSelectorCard(
    BuildContext context,
    WhiteLabelController ctrl,
    ConfigSelector selector,
    int index,
    AppLocalizations localizations,
  ) {
    final theme = Theme.of(context);
    final proto = selector.protocol.toLowerCase();
    final isProtoSupported = isProtocolSupported(proto);
    final isConnectable = selector.connectable;
    final supported = isProtoSupported && isConnectable;
    final isSelected = ctrl.selectedSelector == selector ||
        (selector.configId != null &&
            ctrl.selectedSelector?.configId == selector.configId &&
            selector.configId!.isNotEmpty);
    final isConnected = ctrl.activeSelector == selector &&
        ctrl.tunnelSnapshot.state == TunnelState.connected;

    return Card(
      elevation: isSelected ? 2 : 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isConnected
              ? const Color(0xFF00C853)
              : isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant.withAlpha(50),
          width: (isConnected || isSelected) ? 1.5 : 1.0,
        ),
      ),
      color: isConnected
          ? const Color(0xFF00C853).withAlpha(30)
          : isSelected
              ? theme.colorScheme.primaryContainer.withAlpha(80)
              : theme.colorScheme.surfaceContainerHighest.withAlpha(60),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          if (!isProtoSupported) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '${selector.protocol.toUpperCase()}: ${localizations.comingSoon}',
                ),
              ),
            );
            return;
          }
          if (!isConnectable) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'پیکربندی ${selector.displayName} (${selector.protocol.toUpperCase()}) در سرور غیرفعال است.',
                ),
              ),
            );
            return;
          }
          ctrl.selectSelector(selector);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: const Duration(milliseconds: 1000),
              content: Text(
                  '${selector.displayName} (${selector.protocol.toUpperCase()}) انتخاب شد'),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: <Widget>[
              Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                size: 22,
                color: isSelected
                    ? (isConnected
                        ? const Color(0xFF00C853)
                        : theme.colorScheme.primary)
                    : theme.colorScheme.outline,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      selector.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${proto.toLowerCase()} • ${selector.engine}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (!supported)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isProtoSupported
                        ? theme.colorScheme.surfaceContainerHighest
                        : theme.colorScheme.errorContainer.withAlpha(160),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isProtoSupported
                        ? localizations.unavailable
                        : localizations.comingSoon,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isProtoSupported
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                )
              else if (isConnected)
                IconButton(
                  key: ValueKey('wl-disconnect-$index'),
                  icon: const Icon(Icons.stop_circle_outlined,
                      color: Color(0xFF00C853)),
                  tooltip: localizations.disconnect,
                  onPressed: ctrl.disconnect,
                )
              else
                IconButton(
                  key: ValueKey('wl-connect-$index'),
                  icon: const Icon(Icons.play_circle_outline),
                  tooltip: localizations.connect,
                  onPressed: () async {
                    ctrl.selectSelector(selector);
                    final res = await ctrl.connect(selector);
                    if (context.mounted &&
                        res != WhiteLabelConnectResult.connected &&
                        res != WhiteLabelConnectResult.requestAccepted) {
                      final msg = ctrl.lastErrorMessage ??
                          ctrl.protocolUnavailableReason ??
                          switch (res) {
                            WhiteLabelConnectResult.adapterUnavailable =>
                              localizations.tunnelUnavailableBody,
                            WhiteLabelConnectResult.protocolUnavailable =>
                              ctrl.protocolUnavailableReason ??
                                  localizations.tunnelUnavailableBody,
                            _ => localizations.tunnelUnavailableBody,
                          };
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          key: ValueKey('connection-result-${res.name}'),
                          content: Text(msg),
                        ),
                      );
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
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
