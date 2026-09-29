import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tunnel_interface/tunnel_interface.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import '../config/product_configuration.dart';
import '../storage/secure_storage.dart';

enum LibraryLoadState { loading, ready, error }

enum LibraryFailureKind {
  validation,
  authorization,
  transport,
  protectedStorage,
  malformedData,
  unknown,
}

enum OfficialConnectResult {
  adapterUnavailable,
  protocolUnavailable,
  requestAccepted,
  connected,
  failed,
}

class LibraryController extends ChangeNotifier {
  LibraryController({
    required this.configuration,
    required this.repository,
    required this.tunnelAdapter,
  }) {
    _tunnelSubscription = tunnelAdapter?.snapshots.listen((snapshot) {
      tunnelSnapshot = snapshot;
      notifyListeners();
    });
  }

  final ProductConfiguration configuration;
  final OfficialProfileRepository repository;
  final TunnelAdapter? tunnelAdapter;
  StreamSubscription<TunnelSnapshot>? _tunnelSubscription;

  TunnelSnapshot tunnelSnapshot = const TunnelSnapshot.disconnected();
  TunnelCapabilities? tunnelCapabilities;
  String? protocolUnavailableReason;
  String? lastErrorMessage;
  LibraryLoadState loadState = LibraryLoadState.loading;
  OfficialProfileCatalog catalog = OfficialProfileCatalog.empty();
  LibraryFailureKind? failure;
  bool mutating = false;
  bool tunnelMutating = false;
  OfficialConfigEntry? selectedEntry;
  String? selectedEntryId;

  void selectEntry(OfficialConfigEntry? entry) {
    selectedEntry = entry;
    selectedEntryId = entry?.id;
    notifyListeners();
  }

  Future<void> load() async {
    loadState = LibraryLoadState.loading;
    failure = null;
    notifyListeners();
    await _refreshTunnelState();
    try {
      catalog = await repository.load();
      loadState = LibraryLoadState.ready;
      if (selectedEntryId != null) {
        for (final p in catalog.profiles) {
          for (final e in p.configs) {
            if (e.id == selectedEntryId) {
              selectedEntry = e;
              break;
            }
          }
        }
      }
    } catch (error) {
      failure = _failure(error);
      loadState = LibraryLoadState.error;
    }
    notifyListeners();
  }

  Future<bool> addManual({required String name, required String rawSource}) =>
      _mutate(() => repository.addManual(name: name, rawSource: rawSource));

  Future<bool> addSubscription({required String name, required String url}) =>
      _mutate(() => repository.addSubscription(name: name, url: url));

  Future<bool> updateManual({
    required String profileId,
    required String name,
    required String rawSource,
  }) => _mutate(
    () => repository.updateManual(
      profileId: profileId,
      name: name,
      rawSource: rawSource,
    ),
  );

  Future<bool> updateSubscription({
    required String profileId,
    required String name,
    required String url,
  }) => _mutate(
    () => repository.updateSubscription(
      profileId: profileId,
      name: name,
      url: url,
    ),
  );

  Future<bool> refresh(String profileId) =>
      _mutate(() => repository.refreshSubscription(profileId));

  Future<bool> delete(String profileId) =>
      _mutate(() => repository.delete(profileId));

  Future<OfficialConnectResult> connect(OfficialConfigEntry config) async {
    final adapter = tunnelAdapter;
    if (adapter == null) return OfficialConnectResult.adapterUnavailable;
    if (tunnelMutating) return OfficialConnectResult.failed;
    tunnelMutating = true;
    protocolUnavailableReason = null;
    lastErrorMessage = null;
    notifyListeners();
    try {
      final capabilities = await adapter.capabilities();
      tunnelCapabilities = capabilities;
      if (!capabilities.supports(config.normalized.protocol)) {
        protocolUnavailableReason = capabilities
            .unavailableReasons[config.normalized.protocol.toLowerCase()];
        lastErrorMessage = protocolUnavailableReason ?? 'این پروتکل در دستگاه شما پشتیبانی نمی‌شود.';
        return OfficialConnectResult.protocolUnavailable;
      }
      final snapshot = await adapter.connect(
        TunnelConnectRequest(
          requestId:
              'official-${DateTime.now().toUtc().microsecondsSinceEpoch}',
          connectionId: config.id,
          config: config.normalized,
          productMode: configuration.mode,
        ),
      );
      tunnelSnapshot = snapshot;
      if (snapshot.state == TunnelState.failed) {
        lastErrorMessage = snapshot.failure?.safeMessage ?? 'راه‌اندازی سرویس اتصال با خطا مواجه شد.';
        return OfficialConnectResult.failed;
      }
      return snapshot.state == TunnelState.connected
          ? OfficialConnectResult.connected
          : OfficialConnectResult.requestAccepted;
    } on TunnelFailure catch (failure) {
      lastErrorMessage = failure.safeMessage;
      return OfficialConnectResult.failed;
    } catch (e) {
      lastErrorMessage = 'خطا در برقراری اتصال: $e';
      return OfficialConnectResult.failed;
    } finally {
      tunnelMutating = false;
      notifyListeners();
    }
  }

  Future<bool> disconnect() async {
    final adapter = tunnelAdapter;
    if (adapter == null || tunnelMutating) return false;
    tunnelMutating = true;
    notifyListeners();
    try {
      final snapshot = await adapter.disconnect(reason: 'user_requested');
      tunnelSnapshot = snapshot;
      return snapshot.state == TunnelState.disconnected ||
          snapshot.state == TunnelState.disconnecting;
    } catch (_) {
      return false;
    } finally {
      tunnelMutating = false;
      notifyListeners();
    }
  }

  bool get adapterAvailable =>
      tunnelAdapter != null &&
      tunnelCapabilities?.canProtectEntireDevice == true &&
      tunnelCapabilities!.protocols.isNotEmpty;

  void clearFailure() {
    failure = null;
    notifyListeners();
  }

  Future<void> _refreshTunnelState() async {
    final adapter = tunnelAdapter;
    if (adapter == null) return;
    try {
      tunnelCapabilities = await adapter.capabilities();
      tunnelSnapshot = await adapter.current();
    } catch (_) {
      // The profile library remains usable. Connection controls fail closed and
      // no native exception text is surfaced or logged.
      tunnelCapabilities = null;
      tunnelSnapshot = const TunnelSnapshot.disconnected();
    }
    notifyListeners();
  }

  Future<bool> _mutate(
    Future<OfficialProfileCatalog> Function() operation,
  ) async {
    if (mutating) return false;
    mutating = true;
    failure = null;
    notifyListeners();
    try {
      catalog = await operation();
      loadState = LibraryLoadState.ready;
      return true;
    } catch (error) {
      failure = _failure(error);
      return false;
    } finally {
      mutating = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(_tunnelSubscription?.cancel());
    _tunnelSubscription = null;
    super.dispose();
  }

  LibraryFailureKind _failure(Object error) {
    if (error is ClientPolicyViolation) {
      return LibraryFailureKind.authorization;
    }
    if (error is ZagrosException) {
      return switch (error.kind) {
        ZagrosErrorKind.validation || ZagrosErrorKind.secureTransportRequired =>
          LibraryFailureKind.validation,
        ZagrosErrorKind.authentication ||
        ZagrosErrorKind.authorization ||
        ZagrosErrorKind.rateLimited => LibraryFailureKind.authorization,
        ZagrosErrorKind.transport => LibraryFailureKind.transport,
        ZagrosErrorKind.malformedResponse => LibraryFailureKind.malformedData,
        _ => LibraryFailureKind.unknown,
      };
    }
    if (error is FormatException) return LibraryFailureKind.malformedData;
    if (error is ClientSecureStorageException) {
      return LibraryFailureKind.protectedStorage;
    }
    return LibraryFailureKind.unknown;
  }
}
