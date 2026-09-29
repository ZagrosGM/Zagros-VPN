import 'dart:convert';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/services.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

abstract interface class RawConfigActions {
  Future<void> copy(String rawConfig);

  Future<String> export({
    required String rawConfig,
    required String suggestedName,
  });
}

class PlatformRawConfigActions implements RawConfigActions {
  const PlatformRawConfigActions(this.policy);

  final ClientPolicy policy;

  @override
  Future<void> copy(String rawConfig) async {
    policy.require(ClientCapability.rawConfigClipboard);
    await Clipboard.setData(ClipboardData(text: rawConfig));
  }

  @override
  Future<String> export({
    required String rawConfig,
    required String suggestedName,
  }) async {
    policy.require(ClientCapability.rawConfigExport);
    final safeName = suggestedName
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return FileSaver.instance.saveFile(
      name: safeName.isEmpty ? 'zagros-config' : safeName,
      bytes: Uint8List.fromList(utf8.encode(rawConfig)),
      ext: 'conf',
      mimeType: MimeType.text,
    );
  }
}
