import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tunnel_interface/tunnel_interface.dart';

import '../settings/app_settings_controller.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import '../storage/secure_storage.dart';
import 'white_label_service.dart';

enum WhiteLabelPhase { initializing, needsEnrollment, needsLogin, ready }

/// Safe, low-information error categories. The screen maps these to fixed
/// localized strings; server messages are never rendered.
enum WhiteLabelError {
  none,
  invalidInput,
  invalidCredentials,
  ticketInvalid,
  accessDenied,
  sessionExpired,
  enrollmentRequired,
  networkUnreachable,
  rateLimited,
  storageUnavailable,
  unknown,
}

enum WhiteLabelConnectResult {
  adapterUnavailable,
  protocolUnavailable,
  alreadyConnected,
  requestAccepted,
  connected,
  failed,
}

/// Acquire-and-open runtime config for exactly [selector]. Production uses
/// [WhiteLabelService.defaultAcquire]; tests inject a stub.
typedef AcquireWhiteLabelConfig = Future<AcquiredConfig> Function(
  ApplicationSession session,
  ConfigSelector selector,
);

class _ActiveWhiteLabelConnection {
  const _ActiveWhiteLabelConnection({
    required this.selector,
    required this.acquired,
  });

  final ConfigSelector selector;
  final AcquiredConfig acquired;
}

/// Orchestrates enrollment, login, config listing, usage, and native
/// connect/disconnect for the Application account destination.
///
/// The controller never parses configs, never opens envelopes, and never
/// reads runtime config bytes. Decrypted material exists only inside the
/// SDK [AcquiredConfig], is passed opaquely to the native adapter, and is
/// wiped on every terminal path.
class WhiteLabelController extends ChangeNotifier {
  WhiteLabelController({
    required this.service,
    required this.productMode,
    required this.tunnelAdapter,
    this.settings,
    AcquireWhiteLabelConfig? acquire,
  }) : _acquire = acquire ?? service.defaultAcquire {
    _tunnelSubscription = tunnelAdapter?.snapshots.listen(_onTunnelSnapshot);
    // Backstop for the engine re-attach case: after the app is swiped away and
    // relaunched, the push feed can take time to re-establish (or drop events
    // fail-closed). Actively pull the native truth on a short interval so the
    // UI can never sit on a stale disconnected snapshot while a tunnel lives.
    _nativeResyncTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_resyncFromNative()),
    );
  }

  Timer? _nativeResyncTimer;

  /// Pull-based status resync. Only ever moves the UI *towards* a live
  /// connected tunnel; terminal push events (disconnect/failure) always win.
  Future<void> _resyncFromNative() async {
    final adapter = tunnelAdapter;
    if (adapter == null || _active != null || _releasing) return;
    if (_tunnelSnapshot?.state == TunnelState.connected) return;
    try {
      final snapshot = await adapter.current();
      if (snapshot.state == TunnelState.connected &&
          _tunnelSnapshot?.state != TunnelState.connected) {
        _tunnelSnapshot = snapshot;
        notifyListeners();
      }
    } on FormatException {
      // Reason already reported to the Logs tab by the adapter (fail-closed
      // rejection diagnostics); the push feed stays authoritative.
    } on Object {
      // Native side not ready or disposed; the push feed stays authoritative.
    }
  }

  final WhiteLabelService service;
  final ClientProductMode productMode;
  final TunnelAdapter? tunnelAdapter;

  /// Shared app settings (DNS preset feeds the device tun at connect).
  final AppSettingsController? settings;
  final AcquireWhiteLabelConfig _acquire;

  static const _maxUsernameLength = 128;
  static const _maxPasswordLength = 512;
  static const _maxTicketLength = 2048;

  WhiteLabelPhase _phase = WhiteLabelPhase.initializing;
  WhiteLabelError _error = WhiteLabelError.none;
  bool _working = false;
  bool _enrolling = false;
  bool _authenticating = false;
  bool _connecting = false;
  bool _disconnecting = false;
  ApplicationSession? _session;
  UserProfile? _profile;
  List<ConfigSelector> _selectors = const <ConfigSelector>[];
  UsageSummary? _usage;
  TunnelSnapshot _tunnelSnapshot = const TunnelSnapshot.disconnected();
  TunnelCapabilities? _tunnelCapabilities;
  WhiteLabelConnectResult? _connectResult;
  String? _protocolUnavailableReason;
  String? _attemptedProtocol;
  String? _lastErrorMessage;
  TunnelFailure? _lastTunnelFailure;
  ConfigSelector? _activeSelector;
  ConfigSelector? _selectedSelector;
  String? _selectedConfigId;
  _ActiveWhiteLabelConnection? _active;
  bool _releasing = false;
  StreamSubscription<TunnelSnapshot>? _tunnelSubscription;

  WhiteLabelPhase get phase => _phase;
  WhiteLabelError get error => _error;
  bool get working => _working;
  bool get enrolling => _enrolling;
  bool get authenticating => _authenticating;
  bool get connecting => _connecting;
  bool get disconnecting => _disconnecting;
  UserProfile? get profile => _profile;
  List<ConfigSelector> get selectors => _selectors;
  UsageSummary? get usage => _usage;
  TunnelSnapshot get tunnelSnapshot => _tunnelSnapshot;
  TunnelCapabilities? get tunnelCapabilities => _tunnelCapabilities;
  WhiteLabelConnectResult? get connectResult => _connectResult;
  String? get protocolUnavailableReason => _protocolUnavailableReason;
  String? get attemptedProtocol => _attemptedProtocol;
  String? get lastErrorMessage => _lastErrorMessage;
  TunnelFailure? get lastTunnelFailure => _lastTunnelFailure;
  ConfigSelector? get activeSelector => _activeSelector;
  ConfigSelector? get selectedSelector => _selectedSelector;
  bool get hasActiveConnection => _active != null;

  void selectSelector(ConfigSelector? selector) {
    _selectedSelector = selector;
    _selectedConfigId = selector == null
        ? null
        : '${selector.protocol}:${selector.coreId}:${selector.displayName}';
    notifyListeners();
    if (_selectedConfigId != null) {
      unawaited(service.auth.identityStorage.write(
        'zagros.selected.config.id.v1',
        utf8.encode(_selectedConfigId!),
      ));
    }
  }

  /// Restores enrollment + session and loads account data. Safe to call once
  /// from the screen; [refreshData] reuses the loaded session afterwards.
  Future<void> start() async {
    if (_working) return;
    _working = true;
    _phase = WhiteLabelPhase.initializing;
    _error = WhiteLabelError.none;
    notifyListeners();
    try {
      final restored = await service.auth.restore();
      if (restored == null) {
        _phase = WhiteLabelPhase.needsEnrollment;
        return;
      }
      _session = restored;
      if (restored.current == null) {
        _phase = WhiteLabelPhase.needsLogin;
        return;
      }
      try {
        await restored.accessToken();
      } on ZagrosException catch (error) {
        if (error.kind == ZagrosErrorKind.authentication) {
          await _dropToLogin(WhiteLabelError.sessionExpired);
          return;
        }
        rethrow;
      }
      await _loadData(restored);
      _phase = WhiteLabelPhase.ready;
    } on ClientSecureStorageException {
      _error = WhiteLabelError.storageUnavailable;
      _phase = _session == null
          ? WhiteLabelPhase.needsEnrollment
          : WhiteLabelPhase.needsLogin;
    } on ZagrosException catch (error) {
      await _applyReadError(error);
    } catch (_) {
      _error = WhiteLabelError.unknown;
      _phase = _session == null
          ? WhiteLabelPhase.needsEnrollment
          : WhiteLabelPhase.needsLogin;
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  Future<void> refreshData() async {
    final session = _session;
    if (_working || session == null || _phase != WhiteLabelPhase.ready) {
      return;
    }
    _working = true;
    _error = WhiteLabelError.none;
    notifyListeners();
    try {
      await _loadData(session);
    } on ClientSecureStorageException {
      _error = WhiteLabelError.storageUnavailable;
    } on ZagrosException catch (error) {
      await _applyReadError(error);
    } catch (_) {
      _error = WhiteLabelError.unknown;
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  /// Device enrollment with username+password only: the app proves its
  /// build with the embedded signing key — the user never enters a code.
  Future<bool> enroll({
    required String username,
    required String password,
  }) async {
    final user = username.trim();
    if (user.isEmpty ||
        password.isEmpty ||
        user.length > _maxUsernameLength ||
        password.length > _maxPasswordLength) {
      _error = WhiteLabelError.invalidInput;
      notifyListeners();
      return false;
    }
    if (_enrolling) return false;
    _enrolling = true;
    _error = WhiteLabelError.none;
    notifyListeners();
    try {
      final session = await service.auth.enroll(
        credentials: ApplicationCredentials(username: user, password: password),
      );
      _session = session;
      try {
        await _loadData(session);
      } on ZagrosException catch (error) {
        // Enrollment succeeded but the follow-up reads failed; the session
        // context is authenticated from here on.
        await _applyReadError(error);
        return false;
      }
      _phase = WhiteLabelPhase.ready;
      return true;
    } on ClientSecureStorageException {
      _error = WhiteLabelError.storageUnavailable;
      return false;
    } on ZagrosException catch (error) {
      // The enroll call itself failed: credentials/ticket feedback stays on
      // the enrollment form instead of dropping to an unauthenticated login.
      if (error.kind == ZagrosErrorKind.authentication) {
        _error = WhiteLabelError.invalidCredentials;
      } else if (error.kind == ZagrosErrorKind.enrollmentRequired) {
        _error = WhiteLabelError.enrollmentRequired;
      } else {
        await _applyReadError(error);
      }
      return false;
    } catch (_) {
      _error = WhiteLabelError.unknown;
      return false;
    } finally {
      _enrolling = false;
      notifyListeners();
    }
  }

  Future<bool> login({
    required String username,
    required String password,
  }) async {
    final user = username.trim();
    if (user.isEmpty ||
        password.isEmpty ||
        user.length > _maxUsernameLength ||
        password.length > _maxPasswordLength) {
      _error = WhiteLabelError.invalidInput;
      notifyListeners();
      return false;
    }
    if (_authenticating) return false;
    _authenticating = true;
    _error = WhiteLabelError.none;
    notifyListeners();
    try {
      final session = await service.auth.login(
        ApplicationCredentials(username: user, password: password),
      );
      _session = session;
      try {
        await _loadData(session);
      } on ZagrosException catch (error) {
        await _applyReadError(error);
        return false;
      }
      _phase = WhiteLabelPhase.ready;
      return true;
    } on ClientSecureStorageException {
      _error = WhiteLabelError.storageUnavailable;
      return false;
    } on ZagrosException catch (error) {
      if (error.kind == ZagrosErrorKind.authentication) {
        _error = WhiteLabelError.invalidCredentials;
      } else if (error.kind == ZagrosErrorKind.enrollmentRequired) {
        // Password-only re-login is impossible once the device identity is
        // gone/revoked: ask for the activation code instead of a dead end.
        _error = WhiteLabelError.enrollmentRequired;
        _phase = WhiteLabelPhase.needsEnrollment;
      } else {
        await _applyReadError(error);
      }
      return false;
    } catch (_) {
      _error = WhiteLabelError.unknown;
      return false;
    } finally {
      _authenticating = false;
      notifyListeners();
    }
  }

  /// Drops local enrollment so the user can enter a different activation
  /// code. The active connection, if any, is torn down first.
  Future<void> reEnroll() async {
    if (_active != null) await disconnect();
    try {
      await service.auth.forgetEnrollment();
    } catch (_) {
      _error = WhiteLabelError.storageUnavailable;
      notifyListeners();
      return;
    }
    _session = null;
    _clearData();
    _phase = WhiteLabelPhase.needsEnrollment;
    _error = WhiteLabelError.none;
    notifyListeners();
  }

  Future<WhiteLabelConnectResult> connect(ConfigSelector selector) async {
    if (_active != null) {
      _connectResult = WhiteLabelConnectResult.alreadyConnected;
      notifyListeners();
      return WhiteLabelConnectResult.alreadyConnected;
    }
    final adapter = tunnelAdapter;
    if (adapter == null) {
      _connectResult = WhiteLabelConnectResult.adapterUnavailable;
      notifyListeners();
      return WhiteLabelConnectResult.adapterUnavailable;
    }
    final session = _session;
    if (session == null || _phase != WhiteLabelPhase.ready || _connecting) {
      _connectResult = WhiteLabelConnectResult.failed;
      notifyListeners();
      return WhiteLabelConnectResult.failed;
    }
    _connecting = true;
    _error = WhiteLabelError.none;
    _connectResult = null;
    _lastErrorMessage = null;
    _lastTunnelFailure = null;
    _protocolUnavailableReason = null;
    _attemptedProtocol = selector.protocol;
    notifyListeners();
    try {
      final capabilities = await adapter.capabilities();
      _tunnelCapabilities = capabilities;
      if (!capabilities.supports(selector.protocol)) {
        _protocolUnavailableReason =
            capabilities.unavailableReasons[selector.protocol.toLowerCase()];
        _lastErrorMessage = _protocolUnavailableReason ?? 'این پروتکل در دستگاه شما پشتیبانی نمی‌شود.';
        _connectResult = WhiteLabelConnectResult.protocolUnavailable;
        return WhiteLabelConnectResult.protocolUnavailable;
      }
      if (!selector.connectable) {
        _lastErrorMessage = 'پیکربندی انتخاب‌شده در سرور غیرفعال است.';
        _connectResult = WhiteLabelConnectResult.failed;
        return WhiteLabelConnectResult.failed;
      }
      // Only after the native capability check does the controller touch
      // network acquisition or runtime config bytes.
      final acquired = await _acquire(session, selector);
      try {
        final snapshot = await adapter.connect(
          TunnelConnectRequest(
            requestId:
                'whitelabel-${DateTime.now().toUtc().microsecondsSinceEpoch}',
            connectionId: acquired.lifecycle.connection.connectionId,
            config: acquired.normalized,
            productMode: productMode,
            dnsServers: settings?.effectiveDnsServers ?? const <String>[],
            fakeDns: settings?.fakeDns ?? false,
            perAppMode:
                (settings?.perAppEnabled ?? false) ? settings!.perAppMode : 'off',
            perAppPackages:
                (settings?.perAppEnabled ?? false) ? settings!.perAppPackages : const <String>[],
          ),
        );
        if (snapshot.state == TunnelState.failed) {
          await _releaseAcquired(acquired);
          _error = WhiteLabelError.unknown;
          _lastTunnelFailure = snapshot.failure;
          _lastErrorMessage = _mapTunnelFailure(snapshot.failure?.code);
          _connectResult = WhiteLabelConnectResult.failed;
          return WhiteLabelConnectResult.failed;
        }
        _tunnelSnapshot = snapshot;
        _active = _ActiveWhiteLabelConnection(
          selector: selector,
          acquired: acquired,
        );
        _activeSelector = selector;
        final result = snapshot.state == TunnelState.connected
            ? WhiteLabelConnectResult.connected
            : WhiteLabelConnectResult.requestAccepted;
        _connectResult = result;
        return result;
      } catch (_) {
        await _releaseAcquired(acquired);
        rethrow;
      }
    } on TunnelFailure catch (failure) {
      _lastTunnelFailure = failure;
      _lastErrorMessage = _mapTunnelFailure(failure.code);
      if (failure.code == 'protocol_unavailable') {
        _connectResult = WhiteLabelConnectResult.protocolUnavailable;
        return WhiteLabelConnectResult.protocolUnavailable;
      }
      _error = WhiteLabelError.unknown;
      _connectResult = WhiteLabelConnectResult.failed;
      return WhiteLabelConnectResult.failed;
    } on ZagrosException catch (error) {
      _lastErrorMessage = error.message.isNotEmpty ? error.message : null;
      await _applyReadError(error);
      _connectResult = WhiteLabelConnectResult.failed;
      return WhiteLabelConnectResult.failed;
    } on ClientSecureStorageException {
      _lastErrorMessage = 'حافظه امن سیستم‌عامل در دسترس نیست.';
      _error = WhiteLabelError.storageUnavailable;
      _connectResult = WhiteLabelConnectResult.failed;
      return WhiteLabelConnectResult.failed;
    } catch (e) {
      _lastErrorMessage = 'خطا در برقراری ارتباط: $e';
      _error = WhiteLabelError.unknown;
      _connectResult = WhiteLabelConnectResult.failed;
      return WhiteLabelConnectResult.failed;
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    if (_disconnecting) return;
    _disconnecting = true;
    notifyListeners();
    try {
      if (_active != null) {
        await _releaseActive(reason: 'user');
      } else {
        // Reopened app: the native tunnel is live (probe-restored UI) but
        // this instance never started it, so [_active] is null. The OFF
        // button must still tear the REAL tunnel down — otherwise it is a
        // silent no-op and the button looks dead.
        final adapter = tunnelAdapter;
        if (adapter != null) {
          try {
            _tunnelSnapshot = await adapter.disconnect(reason: 'user');
          } catch (_) {
            _tunnelSnapshot = const TunnelSnapshot(
              state: TunnelState.failed,
              sequence: 0,
            );
          }
          _activeSelector = null;
        }
      }
    } finally {
      _disconnecting = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    if (_active != null) await disconnect();
    try {
      await service.auth.logout();
    } on ClientSecureStorageException {
      await _dropToLogin(WhiteLabelError.storageUnavailable);
      notifyListeners();
      return;
    } catch (_) {
      // The SDK always clears local tokens; a transport failure only skips
      // the best-effort server call, so local logout still proceeds.
    }
    await _dropToLogin(WhiteLabelError.none);
    notifyListeners();
  }

  @override
  void dispose() {
    _nativeResyncTimer?.cancel();
    unawaited(_tunnelSubscription?.cancel());
    final active = _active;
    _active = null;
    if (active != null) {
      // No network on dispose: stop renewal and wipe runtime config bytes.
      active.acquired.lifecycle.detach();
      active.acquired.disposeRuntimeConfig();
    }
    super.dispose();
  }

  Future<void> _loadData(ApplicationSession session) async {
    final token = await session.accessToken();
    final deviceId = session.deviceId;
    _profile = await service.api.profile(deviceId, token);
    final selectors = await service.api.listConfigs(deviceId, token);
    _selectors = List<ConfigSelector>.unmodifiable(selectors);
    _usage = await service.api.usageSummary(deviceId, token);

    try {
      final savedBytes = await service.auth.identityStorage.read('zagros.selected.config.id.v1');
      if (savedBytes != null) {
        final savedKey = utf8.decode(savedBytes, allowMalformed: true);
        for (final s in _selectors) {
          final key = '${s.protocol}:${s.coreId}:${s.displayName}';
          if ((key == savedKey || (s.configId != null && s.configId == savedKey)) && s.connectable) {
            _selectedSelector = s;
            _selectedConfigId = key;
            break;
          }
        }
      }
    } catch (_) {
      // Ignore read error
    }
    if ((_selectedSelector == null || !_selectedSelector!.connectable) && _selectors.isNotEmpty) {
      _selectedSelector = _selectors.firstWhere(
        (s) => s.connectable && const ['vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria2', 'tuic', 'wireguard'].contains(s.protocol),
        orElse: () => _selectors.firstWhere(
          (s) => s.connectable,
          orElse: () => _selectors.first,
        ),
      );
    }
  }

  /// Maps read-path failures. Authentication drops to login, an unknown
  /// server-side device drops to enrollment, everything else stays on the
  /// current phase with a safe banner.
  Future<void> _applyReadError(ZagrosException error) async {
    switch (error.kind) {
      case ZagrosErrorKind.authentication:
        await _dropToLogin(WhiteLabelError.sessionExpired);
      case ZagrosErrorKind.enrollmentRequired:
        await _dropToEnrollment();
      case ZagrosErrorKind.activationTicketInvalid:
        _error = WhiteLabelError.ticketInvalid;
      case ZagrosErrorKind.authorization:
        _error = WhiteLabelError.accessDenied;
      case ZagrosErrorKind.rateLimited:
        _error = WhiteLabelError.rateLimited;
      case ZagrosErrorKind.transport:
        _error = WhiteLabelError.networkUnreachable;
      case ZagrosErrorKind.applicationNotFound ||
          ZagrosErrorKind.applicationGrantNotFound ||
          ZagrosErrorKind.applicationKeyNotFound:
        _error = WhiteLabelError.accessDenied;
      default:
        _error = _mapError(error);
    }
    if (_phase == WhiteLabelPhase.initializing) {
      _phase = _session == null
          ? WhiteLabelPhase.needsEnrollment
          : WhiteLabelPhase.needsLogin;
    }
  }

  WhiteLabelError _mapError(ZagrosException error) => switch (error.kind) {
    ZagrosErrorKind.authentication => WhiteLabelError.invalidCredentials,
    ZagrosErrorKind.activationTicketInvalid => WhiteLabelError.ticketInvalid,
    ZagrosErrorKind.authorization => WhiteLabelError.accessDenied,
    ZagrosErrorKind.enrollmentRequired => WhiteLabelError.enrollmentRequired,
    ZagrosErrorKind.rateLimited => WhiteLabelError.rateLimited,
    ZagrosErrorKind.transport => WhiteLabelError.networkUnreachable,
    _ => WhiteLabelError.unknown,
  };

  Future<void> _dropToLogin(WhiteLabelError error) async {
    var mapped = error;
    try {
      await _session?.clear();
    } catch (_) {
      mapped = WhiteLabelError.storageUnavailable;
    }
    _session = null;
    _clearData();
    _phase = WhiteLabelPhase.needsLogin;
    _error = mapped;
  }

  Future<void> _dropToEnrollment() async {
    if (_active != null) await disconnect();
    try {
      await service.auth.forgetEnrollment();
    } catch (_) {
      // Local state is dropped below regardless; the banner reports that
      // a new activation code is required.
    }
    _session = null;
    _clearData();
    _phase = WhiteLabelPhase.needsEnrollment;
    _error = WhiteLabelError.enrollmentRequired;
  }

  String _mapTunnelFailure(String? code) => switch (code?.toLowerCase()) {
    'vpn_permission_denied' => 'مجوز ایجاد تونل VPN توسط کاربر تایید نشد.',
    'engine_failed' => 'راه‌اندازی هسته اتصال با خطا مواجه شد.',
    'invalid_config' => 'پیکربندی سرور نامعتبر است.',
    'endpoint_resolution_failed' => 'آدرس سرور در دسترس نیست.',
    'backend_unavailable' || 'protocol_unavailable' => 'این پروتکل در دستگاه شما پشتیبانی نمی‌شود.',
    'operation_in_progress' => 'عملیات دیگری در حال اجرا است.',
    _ => 'برقراری اتصال با خطا مواجه شد.',
  };

  void _clearData() {
    _profile = null;
    _selectors = const <ConfigSelector>[];
    _usage = null;
    _connectResult = null;
    _lastErrorMessage = null;
    _lastTunnelFailure = null;
    _protocolUnavailableReason = null;
    _attemptedProtocol = null;
    _activeSelector = null;
  }

  /// Stops the server lease (best effort) and always wipes runtime config.
  Future<void> _releaseAcquired(AcquiredConfig acquired) async {
    try {
      await acquired.lifecycle.stop();
    } catch (_) {
      acquired.lifecycle.detach();
    } finally {
      acquired.disposeRuntimeConfig();
    }
  }

  Future<void> _releaseActive({required String reason}) async {
    if (_releasing) return;
    final active = _active;
    if (active == null) return;
    _releasing = true;
    try {
      final adapter = tunnelAdapter;
      if (adapter != null) {
        try {
          _tunnelSnapshot = await adapter.disconnect(reason: reason);
        } catch (_) {
          _tunnelSnapshot = const TunnelSnapshot(
            state: TunnelState.failed,
            sequence: 0,
          );
        }
      }
      try {
        await active.acquired.lifecycle.stop();
      } on ZagrosException catch (error) {
        if (error.kind == ZagrosErrorKind.authentication) {
          await _dropToLogin(WhiteLabelError.sessionExpired);
        }
        active.acquired.lifecycle.detach();
      } catch (_) {
        active.acquired.lifecycle.detach();
      } finally {
        active.acquired.disposeRuntimeConfig();
      }
    } finally {
      _active = null;
      _activeSelector = null;
      _releasing = false;
      notifyListeners();
    }
  }

  void _onTunnelSnapshot(TunnelSnapshot snapshot) {
    _tunnelSnapshot = snapshot;
    notifyListeners();
    if (_active == null || _releasing) return;
    if (snapshot.state == TunnelState.disconnected ||
        snapshot.state == TunnelState.failed) {
      // Externally observed teardown also releases the server lease and
      // wipes runtime config; the guard inside [_releaseActive] prevents
      // reentrancy with an explicit user disconnect.
      unawaited(_releaseActive(reason: 'external'));
    }
  }
}
