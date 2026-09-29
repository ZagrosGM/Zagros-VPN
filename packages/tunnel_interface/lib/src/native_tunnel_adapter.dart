import 'dart:async';

import 'package:flutter/services.dart';

import 'generated/tunnel_api.g.dart';
import 'runtime_config_encoder.dart';
import 'tunnel_adapter.dart';
import 'tunnel_models.dart';

abstract interface class NativeTunnelGateway {
  Future<NativeTunnelCapabilities> getCapabilities();

  Future<NativeTunnelStatus> getStatus();

  Future<NativeTunnelStatus> connect(NativeTunnelRequest request);

  Future<NativeTunnelStatus> disconnect(String reason);
}

final class PigeonNativeTunnelGateway implements NativeTunnelGateway {
  PigeonNativeTunnelGateway({NativeTunnelHostApi? api})
      : _api = api ?? NativeTunnelHostApi();

  final NativeTunnelHostApi _api;

  @override
  Future<NativeTunnelCapabilities> getCapabilities() => _api.getCapabilities();

  @override
  Future<NativeTunnelStatus> getStatus() => _api.getStatus();

  @override
  Future<NativeTunnelStatus> connect(NativeTunnelRequest request) =>
      _api.connect(request);

  @override
  Future<NativeTunnelStatus> disconnect(String reason) =>
      _api.disconnect(reason);
}

/// Shared Dart facade over the generated runtime-only Pigeon contract.
///
/// This object never reports connected on its own. It accepts only validated,
/// monotonic native status and erases the mutable payload immediately after the
/// host call completes. Garbage-collected/native runtimes may still make copies,
/// so deterministic erasure is not claimed.
final class NativeTunnelAdapter
    implements TunnelAdapter, NativeTunnelFlutterApi {
  factory NativeTunnelAdapter({
    NativeTunnelGateway? gateway,
    NativeRuntimeConfigEncoder? encoder,
    bool allowStructuredOsProfiles = false,
    bool registerNativeCallbacks = true,
  }) {
    final adapter = NativeTunnelAdapter._(
      gateway ?? PigeonNativeTunnelGateway(),
      encoder ?? NativeRuntimeConfigEncoder(),
      allowStructuredOsProfiles,
      registerNativeCallbacks,
    );
    if (registerNativeCallbacks) {
      NativeTunnelFlutterApi.setUp(adapter);
      _traceChannel.setMethodCallHandler((call) async {
        if (call.method == 'onLog') {
          final args = call.arguments;
          if (args is Map && args['line'] is String) {
            adapter._traceLogs.add(args['line'] as String);
          }
        }
        return null;
      });
    }
    return adapter;
  }

  NativeTunnelAdapter._(
    this._gateway,
    this._encoder,
    this._allowStructuredOsProfiles,
    this._ownsCallbackRegistration,
  );

  final NativeTunnelGateway _gateway;
  final NativeRuntimeConfigEncoder _encoder;
  final bool _allowStructuredOsProfiles;
  final bool _ownsCallbackRegistration;
  final StreamController<TunnelSnapshot> _snapshots =
      StreamController<TunnelSnapshot>.broadcast(sync: true);

  static const MethodChannel _traceChannel = MethodChannel('zagros/tunnel_log');
  String? _lastRejectTrace;

  /// Fail-closed snapshot rejections are silent by design (no event data
  /// logged) — but the *rejection reason itself* is operationally vital when
  /// a relaunch leaves a live tunnel behind. Emit only the reason into the
  /// Logs tab (never the event payload), deduped per message.
  void _reportReject(Object error) {
    final line = 'status-reject: $error';
    if (_lastRejectTrace == line) return;
    _lastRejectTrace = line;
    _traceLogs.add(line);
  }

  final StreamController<String> _traceLogs =
      StreamController<String>.broadcast(sync: true);

  /// Native diagnostics lines (engine/Sing-box/SeTrace) for the Logs screen.
  Stream<String> get traceLogs => _traceLogs.stream;

  TunnelSnapshot _last = const TunnelSnapshot.disconnected();
  String? _activeConnectionId;
  DateTime? _connectedAt;
  Future<void> _operationTail = Future<void>.value();
  bool _disposed = false;

  @override
  Stream<TunnelSnapshot> get snapshots => _snapshots.stream;

  @override
  Future<TunnelCapabilities> capabilities() async {
    _ensureOpen();
    try {
      return _capabilitiesFromNative(await _gateway.getCapabilities());
    } on PlatformException catch (error) {
      throw TunnelFailure(
        code: _safeCode(error.code),
        safeMessage: 'The platform tunnel capability check failed.',
        terminal: false,
      );
    }
  }

  @override
  Future<TunnelSnapshot> current() async {
    _ensureOpen();
    try {
      return _accept(await _gateway.getStatus(), emit: false);
    } on FormatException catch (error) {
      _reportReject(error);
      rethrow;
    } on PlatformException catch (error) {
      throw TunnelFailure(
        code: _safeCode(error.code),
        safeMessage: 'The platform tunnel status check failed.',
        terminal: false,
      );
    }
  }

  @override
  Future<TunnelSnapshot> connect(TunnelConnectRequest request) =>
      _serialized(() => _connect(request));

  Future<TunnelSnapshot> _connect(TunnelConnectRequest request) async {
    _ensureOpen();
    _validateIdentifier(request.requestId, 'request ID');
    _validateIdentifier(request.connectionId, 'connection ID');
    final protocol = request.config.protocol.toLowerCase();
    final engine = request.config.engine.toLowerCase();
    final requiredEngine = switch (protocol) {
      'wireguard' => 'wireguard',
      'ikev2' => 'system',
      _ => null,
    };
    if (requiredEngine != null && engine != requiredEngine) {
      throw const TunnelFailure(
        code: 'protocol_engine_mismatch',
        safeMessage: 'This protocol cannot use the requested native engine.',
      );
    }
    final available = await capabilities();
    if (!available.supports(protocol)) {
      throw TunnelFailure(
        code: 'protocol_unavailable',
        safeMessage: available.unavailableReasons[protocol] ??
            'This protocol is unavailable on the current platform.',
      );
    }
    final payload = _encoder.encode(
      request.config,
      dnsServers: request.dnsServers,
      fakeDns: request.fakeDns,
    );
    try {
      if (_last.isActive || _activeConnectionId != null) {
        final previous = await _disconnect('replace_connection');
        if (previous.state != TunnelState.disconnected) {
          throw const TunnelFailure(
            code: 'replacement_teardown_failed',
            safeMessage: 'The previous tunnel could not be replaced safely.',
          );
        }
      }
      _activeConnectionId = request.connectionId;
      _connectedAt = null;
      return _accept(
        await _gateway.connect(
          NativeTunnelRequest(
            requestId: request.requestId,
            connectionId: request.connectionId,
            protocol: protocol,
            engine: engine,
            configPayload: payload,
            whiteLabel: request.productMode.name == 'whiteLabel',
            dnsServers: request.dnsServers,
            perAppMode: request.perAppMode,
            perAppPackages: request.perAppPackages,
          ),
        ),
      );
    } on PlatformException catch (error) {
      final code = _safeCode(error.code);
      if (_isNonMutatingRejection(code)) {
        _activeConnectionId = null;
        _connectedAt = null;
      }
      throw TunnelFailure(
        code: code,
        safeMessage: 'The native tunnel rejected the connection request.',
      );
    } finally {
      payload.fillRange(0, payload.length, 0);
    }
  }

  @override
  Future<TunnelSnapshot> disconnect({required String reason}) =>
      _serialized(() => _disconnect(reason));

  Future<TunnelSnapshot> _disconnect(String reason) async {
    _ensureOpen();
    final safeReason = _safeReason(reason);
    try {
      final snapshot = _accept(await _gateway.disconnect(safeReason));
      if (snapshot.state == TunnelState.disconnected) {
        _activeConnectionId = null;
        _connectedAt = null;
      }
      return snapshot;
    } on PlatformException catch (error) {
      throw TunnelFailure(
        code: _safeCode(error.code),
        safeMessage: 'The native tunnel could not be disconnected safely.',
      );
    }
  }

  @override
  void onStatusChanged(NativeTunnelStatus status) {
    if (_disposed) return;
    try {
      _accept(status);
    } on FormatException catch (error) {
      // A malformed or stale native event is dropped fail-closed. No event
      // data is logged because a compromised plugin could place secrets in
      // fields — but the rejection reason is surfaced for device diagnosis.
      _reportReject(error);
    }
  }

  @override
  Future<void> dispose() => _serialized(() async {
        if (_disposed) return;
        if (_last.isActive || _activeConnectionId != null) {
          try {
            await _gateway.disconnect('adapter_disposed');
          } on Object {
            // Best effort only during shutdown; the OS owns final tunnel teardown.
          }
        }
        _disposed = true;
        if (_ownsCallbackRegistration) {
          NativeTunnelFlutterApi.setUp(null);
          _traceChannel.setMethodCallHandler(null);
        }
        await _snapshots.close();
        await _traceLogs.close();
      });

  Future<T> _serialized<T>(Future<T> Function() operation) async {
    final predecessor = _operationTail;
    final release = Completer<void>();
    _operationTail = release.future;
    await predecessor;
    try {
      return await operation();
    } finally {
      release.complete();
    }
  }

  TunnelCapabilities _capabilitiesFromNative(NativeTunnelCapabilities native) {
    if (native.protocols.length > 64 ||
        native.unavailableReasons.length > 128) {
      throw const FormatException('native capability set is oversized');
    }
    final platform = _safeLabel(native.platform, 'platform', maximum: 32);
    final protocols = <String>{};
    for (final candidate in native.protocols) {
      protocols.add(_safeProtocol(candidate));
    }
    final reasons = <String, String>{};
    for (final entry in native.unavailableReasons.entries) {
      final key = _safeProtocol(entry.key);
      reasons[key] = _safeLabel(
        entry.value,
        'unavailable reason',
        maximum: 240,
      );
    }
    if (!_allowStructuredOsProfiles &&
        const <String>{'ios', 'macos', 'windows'}.contains(platform)) {
      protocols.remove('ikev2');
      reasons['ikev2'] =
          'IKEv2 requires an OS-managed profile and is disabled by runtime-only policy.';
    }
    return TunnelCapabilities(
      platform: platform,
      protocols: protocols,
      canProtectEntireDevice:
          native.canProtectEntireDevice && protocols.isNotEmpty,
      canReportTraffic: native.canReportTraffic && protocols.isNotEmpty,
      unavailableReasons: reasons,
    );
  }

  TunnelSnapshot _accept(NativeTunnelStatus native, {bool emit = true}) {
    if (native.sequence < _last.sequence ||
        native.sequence < 0 ||
        native.uplinkBytes < 0 ||
        native.downlinkBytes < 0) {
      throw const FormatException('invalid native tunnel sequence/counter');
    }
    final connectionId = native.connectionId;
    if (connectionId != null &&
        connectionId == _last.connectionId &&
        (native.uplinkBytes < _last.uplinkBytes ||
            native.downlinkBytes < _last.downlinkBytes)) {
      throw const FormatException('native tunnel counters decreased');
    }
    if (connectionId != null) {
      _validateIdentifier(connectionId, 'native connection ID');
      if (_activeConnectionId != null && connectionId != _activeConnectionId) {
        throw const FormatException('native connection ID mismatch');
      }
    }
    final protocol =
        native.protocol == null ? null : _safeProtocol(native.protocol!);
    final state = switch (native.state) {
      NativeTunnelState.disconnected => TunnelState.disconnected,
      NativeTunnelState.preparing => TunnelState.preparing,
      NativeTunnelState.connecting => TunnelState.connecting,
      NativeTunnelState.connected => TunnelState.connected,
      NativeTunnelState.disconnecting => TunnelState.disconnecting,
      NativeTunnelState.failed => TunnelState.failed,
    };
    final requiresIdentity = state == TunnelState.preparing ||
        state == TunnelState.connecting ||
        state == TunnelState.connected ||
        state == TunnelState.disconnecting;
    if (requiresIdentity && (connectionId == null || protocol == null)) {
      throw const FormatException('active native tunnel identity is missing');
    }
    if (state == TunnelState.disconnected &&
        (connectionId != null ||
            protocol != null ||
            native.connectedAtEpochMs != null ||
            native.uplinkBytes != 0 ||
            native.downlinkBytes != 0)) {
      throw const FormatException(
        'disconnected native tunnel contains active data',
      );
    }
    if (state != TunnelState.connected && native.connectedAtEpochMs != null) {
      throw const FormatException(
        'inactive native tunnel has a connected timestamp',
      );
    }
    DateTime? connectedAt;
    if (state == TunnelState.connected) {
      final epoch = native.connectedAtEpochMs;
      if (epoch == null || epoch <= 0) {
        throw const FormatException('connected timestamp is missing');
      }
      connectedAt = DateTime.fromMillisecondsSinceEpoch(epoch, isUtc: true);
      final now = DateTime.now().toUtc();
      if (connectedAt.isAfter(now.add(const Duration(minutes: 5)))) {
        throw const FormatException('connected timestamp is in the future');
      }
      _connectedAt ??= connectedAt;
      connectedAt = _connectedAt;
    }
    TunnelFailure? failure;
    if (state == TunnelState.failed) {
      failure = TunnelFailure(
        code: _safeCode(native.failureCode ?? 'native_failure'),
        // Deliberately do not trust or surface plugin-provided text. Codes are
        // localized by higher layers without allowing a secret-bearing native
        // exception message to cross into UI or logs.
        safeMessage: 'The native tunnel failed safely.',
      );
    } else if (native.failureCode != null ||
        native.safeFailureMessage != null) {
      throw const FormatException('failure data on non-failed status');
    }
    final snapshot = TunnelSnapshot(
      state: state,
      sequence: native.sequence,
      connectionId: connectionId,
      protocol: protocol,
      connectedAt: connectedAt,
      uplinkBytes: native.uplinkBytes,
      downlinkBytes: native.downlinkBytes,
      failure: failure,
    );
    _last = snapshot;
    if (state == TunnelState.disconnected || state == TunnelState.failed) {
      _connectedAt = null;
    }
    if (state == TunnelState.disconnected ||
        (state == TunnelState.failed && connectionId == null)) {
      _activeConnectionId = null;
    }
    if (emit && !_snapshots.isClosed) _snapshots.add(snapshot);
    return snapshot;
  }

  String _safeProtocol(String value) {
    final normalized = value.toLowerCase();
    if (!RegExp(r'^[a-z0-9][a-z0-9+._-]{0,31}$').hasMatch(normalized)) {
      throw const FormatException('invalid native protocol');
    }
    return normalized;
  }

  String _safeCode(String value) {
    final normalized = value.toLowerCase().replaceAll('-', '_');
    return RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(normalized)
        ? normalized
        : 'native_failure';
  }

  bool _isNonMutatingRejection(String code) => const <String>{
        'backend_unavailable',
        'endpoint_resolution_failed',
        'invalid_config',
        'invalid_disconnect_reason',
        'invalid_request',
        'operation_in_progress',
        'protocol_unavailable',
        'runtime_profile_policy',
        'vpn_permission_denied',
      }.contains(code);

  String _safeLabel(String value, String name, {required int maximum}) {
    if (value.isEmpty ||
        value.length > maximum ||
        value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw FormatException('invalid native $name');
    }
    return value;
  }

  void _validateIdentifier(String value, String name) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value)) {
      throw FormatException('invalid $name');
    }
  }

  String _safeReason(String value) {
    final normalized = value.toLowerCase().replaceAll(
          RegExp(r'[^a-z0-9_]+'),
          '_',
        );
    if (normalized.isEmpty) return 'user_requested';
    return normalized.substring(0, normalized.length.clamp(0, 64));
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('native tunnel adapter is disposed');
  }
}
