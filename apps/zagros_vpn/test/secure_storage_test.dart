import 'package:flutter_test/flutter_test.dart';

import 'package:zagros_vpn/src/storage/secure_storage.dart';

import 'support/fixtures.dart';

void main() {
  test(
    'binary identity values round-trip through namespaced secure storage',
    () async {
      final backend = MemorySecureBackend();
      final store = SdkSecureValueStore(
        backend: backend,
        namespace: 'zagros.whitelabel',
      );
      final input = <int>[1, 2, 3, 4];
      await store.write('device.key', input);
      input[0] = 99;
      expect(await store.read('device.key'), <int>[1, 2, 3, 4]);
      expect(backend.values.keys.single, 'zagros.whitelabel.device.key');
      expect(backend.values.values.single, isNot(contains('[1, 2, 3, 4]')));
      await store.delete('device.key');
      expect(await store.read('device.key'), isNull);
    },
  );

  test('token state is encoded, bounded, and namespaced', () async {
    final backend = MemorySecureBackend();
    final store = SdkSecureTokenStore(
      backend: backend,
      namespace: 'zagros.whitelabel',
    );
    const tokens = '{"access_token":"synthetic-test-value"}';
    await store.write(tokens);
    expect(backend.values.values.single, isNot(contains('access_token')));
    expect(await store.read(), tokens);
    await store.delete();
    expect(await store.read(), isNull);
  });

  test('backend failure is terminal and has no plaintext fallback', () async {
    final backend = MemorySecureBackend()..fail = true;
    final store = SdkSecureValueStore(
      backend: backend,
      namespace: 'zagros.whitelabel',
    );
    await expectLater(
      store.write('device.key', <int>[1]),
      throwsA(isA<ClientSecureStorageException>()),
    );
    expect(backend.values, isEmpty);
  });

  test('invalid storage key is rejected', () async {
    final store = SdkSecureValueStore(
      backend: MemorySecureBackend(),
      namespace: 'zagros.whitelabel',
    );
    await expectLater(
      store.read('../escape'),
      throwsA(isA<ClientSecureStorageException>()),
    );
  });

  test('token state is bounded before write and decode', () async {
    final backend = MemorySecureBackend();
    final store = SdkSecureTokenStore(
      backend: backend,
      namespace: 'zagros.whitelabel',
    );
    await expectLater(
      store.write(List<String>.filled(16 * 1024 + 1, 'a').join()),
      throwsA(isA<ClientSecureStorageException>()),
    );
    backend.values['zagros.whitelabel.application.tokens.v1'] =
        List<String>.filled(21849, 'A').join();
    await expectLater(
      store.read(),
      throwsA(isA<ClientSecureStorageException>()),
    );
  });

  test('identity values are bounded on write and read', () async {
    final backend = MemorySecureBackend();
    final store = SdkSecureValueStore(
      backend: backend,
      namespace: 'zagros.whitelabel',
    );
    await expectLater(
      store.write('identity', List<int>.filled(64 * 1024 + 1, 1)),
      throwsA(isA<ClientSecureStorageException>()),
    );
    backend.values['zagros.whitelabel.identity'] =
        'v1:${List<String>.filled(87385, 'A').join()}';
    await expectLater(
      store.read('identity'),
      throwsA(isA<ClientSecureStorageException>()),
    );
  });

  test('all secure-store namespaces fail closed', () async {
    expect(
      () => SdkSecureTokenStore(
        backend: MemorySecureBackend(),
        namespace: '../shared',
      ),
      throwsA(isA<ClientSecureStorageException>()),
    );
    final values = SdkSecureValueStore(
      backend: MemorySecureBackend(),
      namespace: '../shared',
    );
    await expectLater(
      values.write('identity', <int>[1]),
      throwsA(isA<ClientSecureStorageException>()),
    );
  });
}
