import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory get _appDir {
  if (Directory('lib/src').existsSync()) return Directory.current;
  if (Directory('apps/zagros_vpn/lib/src').existsSync()) {
    return Directory('apps/zagros_vpn');
  }
  return Directory.current;
}

void main() {
  test('Flutter application remains UI and orchestration only', () {
    final base = _appDir;
    final sources = _dartSources(Directory('${base.path}/lib/src'));
    final combined = sources.map((file) => file.readAsStringSync()).join('\n');

    const forbiddenImports = <String>[
      "import 'dart:ffi'",
      "import 'dart:io'",
      "package:crypto/",
      "package:cryptography/",
      "package:http/",
      "package:sqlite",
      "package:sqflite/",
    ];
    for (final forbidden in forbiddenImports) {
      expect(
        combined,
        isNot(contains(forbidden)),
        reason: 'App domain boundary must reject $forbidden',
      );
    }

    expect(combined, isNot(contains('class ClientPolicy')));
    expect(combined, isNot(contains('implements TunnelAdapter')));
    final library = _dartSources(Directory('${base.path}/lib/src/library'))
        .map((file) => file.readAsStringSync())
        .join('\n');
    for (final parser in <String>[
      'parseShareUri(',
      'parseWireGuard(',
      'parseOpenVpn(',
      'jsonDecode(',
    ]) {
      expect(library, isNot(contains(parser)));
    }
    expect(Directory('${base.path}/lib/src/official').existsSync(), isFalse);
    expect(Directory('${base.path}/lib/src/white_label').existsSync(), isFalse);
  });

  test('application dependencies delegate domain and tunnel ownership', () {
    final base = _appDir;
    final manifest = File('${base.path}/pubspec.yaml').readAsStringSync();
    expect(manifest, contains('zagros_vpn_sdk:'));
    expect(manifest, contains('tunnel_interface:'));
    expect(manifest, isNot(contains('\n  http:')));
    expect(manifest, isNot(contains('\n  cryptography:')));
    expect(manifest, isNot(contains('\n  crypto:')));
  });
}

List<File> _dartSources(Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'))
    .toList(growable: false);
