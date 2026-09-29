import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

class ClientSecureStorageException implements Exception {
  const ClientSecureStorageException(this.operation);

  final String operation;

  @override
  String toString() => 'ClientSecureStorageException($operation)';
}

abstract interface class SecureStorageBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureStorageBackend implements SecureStorageBackend {
  FlutterSecureStorageBackend({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                resetOnError: false,
              ),
              iOptions: IOSOptions(
                accountName: 'ai.zagros.vpn',
                accessibility: KeychainAccessibility.unlocked_this_device,
                synchronizable: false,
              ),
              mOptions: MacOsOptions(
                accountName: 'ai.zagros.vpn',
                accessibility: KeychainAccessibility.unlocked_this_device,
                synchronizable: false,
              ),
              wOptions: WindowsOptions(useBackwardCompatibility: false),
              lOptions: LinuxOptions(),
            );

  final FlutterSecureStorage _storage;
  final Map<String, String> _memoryFallback = <String, String>{};

  @override
  Future<String?> read(String key) async {
    try {
      final value = await _storage.read(key: key);
      if (value != null) {
        _memoryFallback[key] = value;
        return value;
      }
    } catch (_) {
      // Graceful fallback to memory on hardware keystore errors
    }
    return _memoryFallback[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _memoryFallback[key] = value;
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      // Graceful fallback to memory on hardware keystore errors
    }
  }

  @override
  Future<void> delete(String key) async {
    _memoryFallback.remove(key);
    try {
      await _storage.delete(key: key);
    } catch (_) {
      // Graceful fallback to memory on hardware keystore errors
    }
  }
}

class SdkSecureValueStore implements SecureValueStore {
  factory SdkSecureValueStore({
    required SecureStorageBackend backend,
    required String namespace,
  }) =>
      SdkSecureValueStore._(backend, namespace);

  const SdkSecureValueStore._(this._backend, this._namespace);

  static const _maximumValueBytes = 64 * 1024;
  static const _maximumEncodedCharacters = 87384;

  final SecureStorageBackend _backend;
  final String _namespace;

  @override
  Future<List<int>?> read(String key) async {
    try {
      final encoded = await _backend.read(_key(key));
      if (encoded == null) return null;
      if (!encoded.startsWith('v1:')) throw const FormatException();
      final payload = encoded.substring(3);
      if (payload.length > _maximumEncodedCharacters) {
        throw const FormatException();
      }
      if (payload.isEmpty) return <int>[];
      final decoded = decodeBase64Url(payload);
      if (decoded.length > _maximumValueBytes) throw const FormatException();
      return decoded;
    } catch (_) {
      throw const ClientSecureStorageException('read');
    }
  }

  @override
  Future<void> write(String key, List<int> value) async {
    if (value.length > _maximumValueBytes) {
      throw const ClientSecureStorageException('value_too_large');
    }
    final encoded = 'v1:${base64UrlNoPadding(List<int>.from(value))}';
    try {
      await _backend.write(_key(key), encoded);
    } catch (_) {
      throw const ClientSecureStorageException('write');
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _backend.delete(_key(key));
    } catch (_) {
      throw const ClientSecureStorageException('delete');
    }
  }

  String _key(String key) {
    if (!RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(key) ||
        !RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(_namespace)) {
      throw const ClientSecureStorageException('invalid_key');
    }
    return '$_namespace.$key';
  }
}

class SdkSecureTokenStore implements SecureTokenStore {
  static const _maximumTokenBytes = 16 * 1024;
  static const _maximumEncodedCharacters = 21848;

  factory SdkSecureTokenStore({
    required SecureStorageBackend backend,
    required String namespace,
  }) =>
      SdkSecureTokenStore._(backend, _tokenKey(namespace));

  const SdkSecureTokenStore._(this._backend, this._key);

  final SecureStorageBackend _backend;
  final String _key;

  static String _tokenKey(String namespace) {
    if (!RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(namespace)) {
      throw const ClientSecureStorageException('invalid_namespace');
    }
    return '$namespace.application.tokens.v1';
  }

  @override
  Future<String?> read() async {
    try {
      final encoded = await _backend.read(_key);
      if (encoded == null) return null;
      if (encoded.length > _maximumEncodedCharacters) {
        throw const FormatException();
      }
      final bytes = base64Url.decode(base64Url.normalize(encoded));
      if (bytes.length > _maximumTokenBytes) throw const FormatException();
      return utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      throw const ClientSecureStorageException('read_tokens');
    }
  }

  @override
  Future<void> write(String serializedTokens) async {
    final bytes = utf8.encode(serializedTokens);
    if (bytes.length > _maximumTokenBytes) {
      throw const ClientSecureStorageException('tokens_too_large');
    }
    final encoded = base64Url.encode(bytes).replaceAll('=', '');
    try {
      await _backend.write(_key, encoded);
    } catch (_) {
      throw const ClientSecureStorageException('write_tokens');
    }
  }

  @override
  Future<void> delete() async {
    try {
      await _backend.delete(_key);
    } catch (_) {
      throw const ClientSecureStorageException('delete_tokens');
    }
  }
}

class ClientSecureStores {
  ClientSecureStores({
    required SecureStorageBackend backend,
    required String namespace,
  })  : values = SdkSecureValueStore(backend: backend, namespace: namespace),
        tokens = SdkSecureTokenStore(backend: backend, namespace: namespace);

  final SdkSecureValueStore values;
  final SdkSecureTokenStore tokens;
}
