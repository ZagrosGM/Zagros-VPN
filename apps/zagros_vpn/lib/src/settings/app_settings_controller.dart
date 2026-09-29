import 'package:flutter/material.dart';

enum DnsPreset {
  system,
  cloudflare,
  google,
  custom,
}

typedef AppSettingsPersist = void Function(
    String locale, String dnsPreset, String customDns, bool fakeDns,
    bool perAppEnabled, String perAppMode, List<String> perAppPackages);

class AppSettingsController extends ChangeNotifier {
  AppSettingsController({
    String initialLocale = 'en',
    DnsPreset initialDns = DnsPreset.system,
    String initialCustomDns = '',
    bool initialFakeDns = false,
    bool initialPerAppEnabled = false,
    String initialPerAppMode = 'allow',
    List<String> initialPerAppPackages = const <String>[],
    AppSettingsPersist? onPersist,
  })  : _locale = Locale(initialLocale),
        _dnsPreset = initialDns,
        _customDns = initialCustomDns,
        _fakeDns = initialFakeDns,
        _perAppEnabled = initialPerAppEnabled,
        _perAppMode = initialPerAppMode,
        _perAppPackages = List<String>.unmodifiable(initialPerAppPackages),
        _onPersist = onPersist;

  final AppSettingsPersist? _onPersist;

  void _persist() {
    try {
      _onPersist?.call(_locale.languageCode, _dnsPreset.name, _customDns,
          _fakeDns, _perAppEnabled, _perAppMode, _perAppPackages);
    } catch (_) {
      // Persistence is best-effort; the in-memory setting still applies.
    }
  }

  Locale _locale;
  DnsPreset _dnsPreset;
  String _customDns;
  bool _fakeDns;
  bool _perAppEnabled;
  String _perAppMode;
  List<String> _perAppPackages;

  Locale get locale => _locale;
  DnsPreset get dnsPreset => _dnsPreset;
  String get customDns => _customDns;

  void setLocale(Locale newLocale) {
    if (_locale == newLocale) return;
    _locale = newLocale;
    notifyListeners();
    _persist();
  }

  void setDnsPreset(DnsPreset preset) {
    if (_dnsPreset == preset) return;
    _dnsPreset = preset;
    notifyListeners();
    _persist();
  }

  void setCustomDns(String ip) {
    _customDns = ip.trim();
    notifyListeners();
    _persist();
  }

  bool get fakeDns => _fakeDns;

  void setFakeDns(bool enabled) {
    if (_fakeDns == enabled) return;
    _fakeDns = enabled;
    notifyListeners();
    _persist();
  }

  bool get perAppEnabled => _perAppEnabled;

  void setPerAppEnabled(bool enabled) {
    if (_perAppEnabled == enabled) return;
    _perAppEnabled = enabled;
    notifyListeners();
    _persist();
  }

  /// "allow" = only selected apps use the VPN; "deny" = selected apps bypass.
  String get perAppMode => _perAppMode;

  void setPerAppMode(String mode) {
    if (_perAppMode == mode) return;
    _perAppMode = mode;
    notifyListeners();
    _persist();
  }

  List<String> get perAppPackages => _perAppPackages;

  void setPerAppPackageSelected(String pkg, bool selected) {
    final next = Set<String>.from(_perAppPackages);
    if (selected) {
      next.add(pkg);
    } else {
      next.remove(pkg);
    }
    _perAppPackages = List<String>.unmodifiable(next);
    notifyListeners();
    _persist();
  }

  List<String> get effectiveDnsServers => switch (_dnsPreset) {
        DnsPreset.system => const <String>[],
        DnsPreset.cloudflare => const <String>['1.1.1.1', '1.0.0.1'],
        DnsPreset.google => const <String>['8.8.8.8', '8.8.4.4'],
        DnsPreset.custom =>
          _customDns.isNotEmpty ? <String>[_customDns] : const <String>[],
      };
}
