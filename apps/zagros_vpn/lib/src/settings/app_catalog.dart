import 'package:flutter/services.dart';

/// One launchable app for the per-app proxy picker.
final class AppCatalogEntry {
  const AppCatalogEntry({required this.packageName, required this.label});

  final String packageName;
  final String label;
}

/// Lists launchable apps through the native plugin channel. Fails open to an
/// empty list (the picker renders an unavailable state, settings keep working).
final class AppCatalog {
  static const MethodChannel _channel = MethodChannel('zagros/appmgr');

  Future<List<AppCatalogEntry>> listLaunchableApps() async {
    try {
      final raw =
          await _channel.invokeListMethod<Object?>('listLaunchableApps');
      if (raw == null) return const <AppCatalogEntry>[];
      return raw
          .whereType<Map<Object?, Object?>>()
          .map((e) => AppCatalogEntry(
                packageName: (e['package'] ?? '').toString(),
                label: (e['label'] ?? '').toString(),
              ))
          .where((e) => e.packageName.isNotEmpty)
          .toList(growable: false);
    } on MissingPluginException {
      return const <AppCatalogEntry>[];
    } on PlatformException {
      return const <AppCatalogEntry>[];
    }
  }
}
