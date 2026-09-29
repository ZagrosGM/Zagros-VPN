import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import 'app_catalog.dart';
import 'app_settings_controller.dart';

/// Per-app proxy picker: check the apps for the active mode (allow = only
/// these use the VPN; deny = these bypass the VPN). The app itself is always
/// handled natively and never listed.
class PerAppScreen extends StatefulWidget {
  const PerAppScreen({
    required this.controller,
    super.key,
  });

  final AppSettingsController controller;

  @override
  State<PerAppScreen> createState() => _PerAppScreenState();
}

class _PerAppScreenState extends State<PerAppScreen> {
  final AppCatalog _catalog = AppCatalog();
  final TextEditingController _search = TextEditingController();
  List<AppCatalogEntry>? _apps;

  @override
  void initState() {
    super.initState();
    _catalog.listLaunchableApps().then((apps) {
      if (mounted) setState(() => _apps = apps);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final apps = _apps;

    return Scaffold(
      appBar: AppBar(
        title: Text(localizations.perAppSelectApps),
        centerTitle: false,
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: localizations.perAppSearch,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: <Widget>[
                ListenableBuilder(
                  listenable: widget.controller,
                  builder: (context, _) => Text(
                    localizations
                        .perAppSelectedCount(widget.controller.perAppPackages.length),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    for (final app in apps ?? const <AppCatalogEntry>[]) {
                      widget.controller.setPerAppPackageSelected(app.packageName, false);
                    }
                  },
                  child: Text(localizations.perAppClearAll),
                ),
              ],
            ),
          ),
          Expanded(
            child: apps == null
                ? const Center(child: CircularProgressIndicator())
                : (apps.isEmpty
                    ? Center(child: Text(localizations.perAppNoApps))
                    : Builder(builder: (context) {
                        final query = _search.text.trim().toLowerCase();
                        final filtered = query.isEmpty
                            ? apps
                            : apps
                                .where((a) =>
                                    a.label.toLowerCase().contains(query) ||
                                    a.packageName.toLowerCase().contains(query))
                                .toList(growable: false);
                        return ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final app = filtered[index];
                            return ListenableBuilder(
                              listenable: widget.controller,
                              builder: (context, _) {
                                final selected = widget.controller.perAppPackages
                                    .contains(app.packageName);
                                return CheckboxListTile(
                                  value: selected,
                                  title: Text(app.label,
                                      maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: Text(app.packageName,
                                      maxLines: 1, overflow: TextOverflow.ellipsis),
                                  onChanged: (value) => widget.controller
                                      .setPerAppPackageSelected(
                                          app.packageName, value ?? false),
                                );
                              },
                            );
                          },
                        );
                      })),
          ),
        ],
      ),
    );
  }
}
