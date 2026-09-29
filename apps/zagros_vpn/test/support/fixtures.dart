import 'package:zagros_vpn/src/storage/secure_storage.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

Map<String, String> whiteLabelValues() => <String, String>{
  'product_mode': 'white-label',
  'app_name': 'Partner VPN',
  'default_locale': 'fa',
  'application_api_base_url': 'https://panel.example.test',
  'application_id': 'application-1',
  'application_name': 'Partner',
  'application_status': 'active',
  'config_key_id': 'config-key-1',
  'config_public_key': base64UrlNoPadding(List<int>.filled(32, 1)),
  'signing_key_id': 'signing-key-1',
  'signing_public_key': base64UrlNoPadding(List<int>.filled(32, 2)),
};

class MemorySecureBackend implements SecureStorageBackend {
  final Map<String, String> values = <String, String>{};
  bool fail = false;

  @override
  Future<void> delete(String key) async {
    if (fail) throw StateError('unavailable');
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    if (fail) throw StateError('unavailable');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (fail) throw StateError('unavailable');
    values[key] = value;
  }
}
