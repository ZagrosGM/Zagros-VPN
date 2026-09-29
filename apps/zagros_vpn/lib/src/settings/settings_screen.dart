import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../account/white_label_controller.dart';
import '../config/product_configuration.dart';
import 'app_settings_controller.dart';
import 'per_app_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.configuration,
    this.settingsController,
    this.whiteLabelController,
    super.key,
  });

  final ProductConfiguration configuration;
  final AppSettingsController? settingsController;
  final WhiteLabelController? whiteLabelController;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(localizations.settings),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: <Widget>[
          _buildLanguageSection(context, localizations),
          const SizedBox(height: 16),
          _buildDnsSection(context, localizations),
          const SizedBox(height: 16),
          _buildPerAppSection(context, localizations),
          const SizedBox(height: 16),
          _buildLegalSection(context, localizations),
          if (configuration.isWhiteLabel) ...<Widget>[
            const SizedBox(height: 16),
            _buildAccountSection(context, localizations),
          ],
        ],
      ),
    );
  }

  Widget _buildLanguageSection(
    BuildContext context,
    AppLocalizations localizations,
  ) {
    final theme = Theme.of(context);
    final ctrl = settingsController;
    final currentLang = ctrl?.locale.languageCode ?? 'en';

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withAlpha(100),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withAlpha(50)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.language_rounded, color: theme.colorScheme.primary, size: 22),
                const SizedBox(width: 10),
                Text(
                  localizations.language,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: <ButtonSegment<String>>[
                ButtonSegment<String>(
                  value: 'en',
                  label: Text(localizations.english),
                  icon: const Icon(Icons.check, size: 16),
                ),
                ButtonSegment<String>(
                  value: 'fa',
                  label: Text(localizations.persian),
                  icon: const Icon(Icons.check, size: 16),
                ),
              ],
              selected: <String>{currentLang},
              onSelectionChanged: (selection) {
                if (selection.isNotEmpty && ctrl != null) {
                  ctrl.setLocale(Locale(selection.first));
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDnsSection(
    BuildContext context,
    AppLocalizations localizations,
  ) {
    final theme = Theme.of(context);
    final ctrl = settingsController;
    final currentPreset = ctrl?.dnsPreset ?? DnsPreset.system;

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withAlpha(100),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withAlpha(50)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.alt_route_rounded, color: theme.colorScheme.primary, size: 22),
                const SizedBox(width: 10),
                Text(
                  localizations.dnsSettings,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            RadioListTile<DnsPreset>(
              title: Text(localizations.dnsSystem),
              value: DnsPreset.system,
              groupValue: currentPreset,
              onChanged: (val) => val != null ? ctrl?.setDnsPreset(val) : null,
              contentPadding: EdgeInsets.zero,
            ),
            RadioListTile<DnsPreset>(
              title: Text(localizations.dnsCloudflare),
              value: DnsPreset.cloudflare,
              groupValue: currentPreset,
              onChanged: (val) => val != null ? ctrl?.setDnsPreset(val) : null,
              contentPadding: EdgeInsets.zero,
            ),
            RadioListTile<DnsPreset>(
              title: Text(localizations.dnsGoogle),
              value: DnsPreset.google,
              groupValue: currentPreset,
              onChanged: (val) => val != null ? ctrl?.setDnsPreset(val) : null,
              contentPadding: EdgeInsets.zero,
            ),
            RadioListTile<DnsPreset>(
              title: Text(localizations.dnsCustom),
              value: DnsPreset.custom,
              groupValue: currentPreset,
              onChanged: (val) => val != null ? ctrl?.setDnsPreset(val) : null,
              contentPadding: EdgeInsets.zero,
            ),
            if (currentPreset == DnsPreset.custom) ...<Widget>[
              const SizedBox(height: 8),
              TextField(
                decoration: InputDecoration(
                  labelText: localizations.customDnsAddress,
                  hintText: '1.1.1.1',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                controller: TextEditingController(text: ctrl?.customDns ?? ''),
                onChanged: (text) => ctrl?.setCustomDns(text),
              ),
            ],
            const Divider(height: 24),
            ListenableBuilder(
              listenable: ctrl ?? ValueNotifier<bool>(false),
              builder: (context, _) => SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(localizations.fakeDnsTitle),
                subtitle: Text(localizations.fakeDnsSubtitle),
                value: ctrl?.fakeDns ?? false,
                onChanged: (value) => ctrl?.setFakeDns(value),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPerAppSection(
    BuildContext context,
    AppLocalizations localizations,
  ) {
    final theme = Theme.of(context);
    final ctrl = settingsController;

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withAlpha(100),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withAlpha(50)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ListenableBuilder(
          listenable: ctrl ?? ValueNotifier<bool>(false),
          builder: (context, _) {
            final enabled = ctrl?.perAppEnabled ?? false;
            final mode = ctrl?.perAppMode ?? 'allow';
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.apps_rounded, color: theme.colorScheme.primary, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        localizations.perAppTitle,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Switch(
                      value: enabled,
                      onChanged: (value) => ctrl?.setPerAppEnabled(value),
                    ),
                  ],
                ),
                Text(
                  localizations.perAppSubtitle,
                  style: theme.textTheme.bodySmall,
                ),
                if (enabled) ...<Widget>[
                  const SizedBox(height: 8),
                  RadioListTile<String>(
                    title: Text(localizations.perAppAllowMode),
                    value: 'allow',
                    groupValue: mode,
                    onChanged: (val) =>
                        val != null ? ctrl?.setPerAppMode(val) : null,
                    contentPadding: EdgeInsets.zero,
                  ),
                  RadioListTile<String>(
                    title: Text(localizations.perAppDenyMode),
                    value: 'deny',
                    groupValue: mode,
                    onChanged: (val) =>
                        val != null ? ctrl?.setPerAppMode(val) : null,
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 4),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => PerAppScreen(controller: ctrl!),
                      ),
                    ),
                    icon: const Icon(Icons.checklist_rounded),
                    label: Text(localizations
                        .perAppSelectedCount(ctrl?.perAppPackages.length ?? 0)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    localizations.perAppAppliesNextConnect,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildLegalSection(
    BuildContext context,
    AppLocalizations localizations,
  ) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withAlpha(100),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withAlpha(50)),
      ),
      child: ListTile(
        leading: Icon(Icons.description_outlined, color: theme.colorScheme.primary),
        title: Text(localizations.openSourceLicenses),
        subtitle: Text(localizations.openSourceLicensesBody),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showLicensePage(
          context: context,
          applicationName: configuration.appName,
        ),
      ),
    );
  }

  Widget _buildAccountSection(
    BuildContext context,
    AppLocalizations localizations,
  ) {
    final theme = Theme.of(context);
    final profile = whiteLabelController?.profile;
    final username = profile?.username ?? '';

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withAlpha(100),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withAlpha(50)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.person_outline, color: theme.colorScheme.primary, size: 22),
                const SizedBox(width: 10),
                Text(
                  localizations.accountInfo,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            if (username.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                localizations.signedInAs(username),
                style: theme.textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: 14),
            OutlinedButton.icon(
              key: const ValueKey('wl-logout'),
              onPressed: () => whiteLabelController?.logout(),
              icon: const Icon(Icons.logout),
              label: Text(localizations.logoutAction),
            ),
          ],
        ),
      ),
    );
  }
}
