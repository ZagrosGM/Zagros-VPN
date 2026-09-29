import Foundation
import NetworkExtension
import Security
#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// Real IKEv2 adapter backed by Apple's built-in Personal VPN transport.
/// Secret values are held in this-device-only Keychain items required by
/// NetworkExtension and are removed with the transient Zagros VPN preference.
public final class ZagrosTunnelPlugin: NSObject, FlutterPlugin, NativeTunnelHostApi {
  private let manager = NEVPNManager.shared()
  private var flutterApi: NativeTunnelFlutterApi?
  private var sequence: Int64 = 0
  private var connectionId: String?
  private var connectedAt: Int64?
  private var keychainAccounts: [String] = []
  private var operationInProgress = true
  private var startupReady = false
  private var observer: NSObjectProtocol?
  private var lastStatus = NativeTunnelStatus(
    state: .disconnected,
    sequence: 0,
    uplinkBytes: 0,
    downlinkBytes: 0
  )

  public static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = ZagrosTunnelPlugin()
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    plugin.flutterApi = NativeTunnelFlutterApi(binaryMessenger: messenger)
    NativeTunnelHostApiSetup.setUp(binaryMessenger: messenger, api: plugin)
    plugin.observer = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange,
      object: nil,
      queue: .main
    ) { [weak plugin] _ in
      Task { @MainActor in plugin?.handleStatusChange() }
    }
    Task { @MainActor in
      await plugin.prepareRuntimeOwnership()
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  func getCapabilities() throws -> NativeTunnelCapabilities {
    var reasons: [String: String] = [
      "wireguard": "WireGuardKit and its signed packet-tunnel extension are not linked in this build.",
      "openvpn": "A reviewed OpenVPN packet-tunnel engine is not packaged.",
      "ovpn": "A reviewed OpenVPN packet-tunnel engine is not packaged.",
      "xray": "A reviewed Xray packet-tunnel engine is not packaged.",
      "sing-box": "A reviewed sing-box packet-tunnel engine is not packaged.",
      "vless": "No reviewed Xray or sing-box VLESS engine is packaged.",
      "vmess": "No reviewed Xray or sing-box VMess engine is packaged.",
      "trojan": "No reviewed Xray or sing-box Trojan engine is packaged.",
      "shadowsocks": "No reviewed Xray or sing-box Shadowsocks engine is packaged.",
      "hysteria2": "No reviewed sing-box Hysteria2 engine is packaged.",
      "tuic": "No reviewed sing-box TUIC engine is packaged.",
      "anytls": "No reviewed sing-box AnyTLS engine is packaged.",
      "socks": "No reviewed SOCKS-to-packet-tunnel engine is packaged.",
      "http": "No reviewed HTTP-proxy-to-packet-tunnel engine is packaged.",
      "https": "No reviewed HTTPS-proxy-to-packet-tunnel engine is packaged.",
      "softether": "A reviewed native SoftEther packet-tunnel engine is not packaged.",
      "ssh": "A reviewed device-tunnel SSH engine is not packaged.",
      "pptp": "PPTP is unsupported by modern Apple systems.",
      "l2tp": "One-button embedded L2TP support is not established on this platform.",
      "l2tp+ipsec": "One-button embedded L2TP/IPsec support is not established on this platform."
    ]
    if !startupReady {
      reasons["ikev2"] = "The Apple VPN ownership cleanup has not completed."
    }
    return NativeTunnelCapabilities(
      platform: Self.platformName,
      protocols: startupReady ? ["ikev2"] : [],
      canProtectEntireDevice: startupReady,
      canReportTraffic: false,
      unavailableReasons: reasons
    )
  }

  func getStatus() throws -> NativeTunnelStatus {
    guard startupReady, !operationInProgress else { return lastStatus }
    let osStatus = manager.connection.status
    if (osStatus == .disconnected || osStatus == .invalid), connectionId != nil {
      handleStatusChange()
      return lastStatus
    }
    return statusFor(osStatus, increment: false)
  }

  func connect(request: NativeTunnelRequest) async throws -> NativeTunnelStatus {
    var payload = request.configPayload.data
    defer { payload.resetBytes(in: 0..<payload.count) }
    guard startupReady else { throw rejection("backend_unavailable") }
    guard !request.whiteLabel else {
      throw rejection("runtime_profile_policy")
    }
    guard request.protocol == "ikev2",
          request.engine == "system",
          Self.safeIdentifier(request.requestId),
          Self.safeIdentifier(request.connectionId),
          !payload.isEmpty,
          payload.count <= Self.maximumConfigBytes,
          let configuration = Self.decode(payload)
    else {
      throw rejection("invalid_request")
    }
    guard !operationInProgress else { throw rejection("operation_in_progress") }
    guard manager.connection.status == .disconnected || manager.connection.status == .invalid else {
      throw rejection("operation_in_progress")
    }
    operationInProgress = true
    defer { operationInProgress = false }
    guard await removeOwnedConfiguration() else { return fail("cleanup_failed") }
    connectionId = request.connectionId
    connectedAt = nil
    publish(state: .preparing)

    do {
      try await manager.loadFromPreferences()
      guard manager.localizedDescription == nil,
            manager.protocolConfiguration == nil else {
        return fail("ownership_conflict")
      }
      let vpnProtocol = NEVPNProtocolIKEv2()
      vpnProtocol.serverAddress = configuration.server
      vpnProtocol.remoteIdentifier = configuration.remoteIdentifier
      vpnProtocol.localIdentifier = configuration.localIdentifier
      vpnProtocol.disconnectOnSleep = false
      vpnProtocol.enablePFS = true
      vpnProtocol.enableRevocationCheck = true
      vpnProtocol.deadPeerDetectionRate = .medium

      if let username = configuration.username, let password = configuration.password {
        vpnProtocol.username = username
        vpnProtocol.useExtendedAuthentication = true
        vpnProtocol.passwordReference = try storeSecret(
          password,
          account: "password-\(request.connectionId)"
        )
      }
      if let sharedSecret = configuration.sharedSecret {
        vpnProtocol.authenticationMethod = .sharedSecret
        vpnProtocol.sharedSecretReference = try storeSecret(
          sharedSecret,
          account: "shared-secret-\(request.connectionId)"
        )
      } else {
        vpnProtocol.authenticationMethod = .none
      }

      manager.protocolConfiguration = vpnProtocol
      manager.localizedDescription = "Zagros VPN"
      manager.isEnabled = true
      try await manager.saveToPreferences()
      try await manager.loadFromPreferences()
      try manager.connection.startVPNTunnel()
      publish(state: .connecting)
      let established = await waitForStatus(
        { $0 == .connected || $0 == .disconnected || $0 == .invalid },
        attempts: 120
      )
      if established == .connected {
        connectedAt = Int64(Date().timeIntervalSince1970 * 1000)
        return publish(state: .connected)
      }
      if established == nil || established == .connecting || established == .reasserting {
        let removed = await stopAndRemoveOwnedConfiguration(attempts: 80)
        return removed ? fail("activation_timeout") : fail("teardown_failed")
      }
      let removed = await removeOwnedConfiguration()
      return removed ? fail("engine_rejected") : fail("cleanup_failed")
    } catch {
      let removed = await stopAndRemoveOwnedConfiguration(attempts: 80)
      return removed ? fail("engine_failed") : fail("teardown_failed")
    }
  }

  @MainActor
  func disconnect(reason: String) async throws -> NativeTunnelStatus {
    guard Self.safeReason(reason) else { throw rejection("invalid_disconnect_reason") }
    guard !operationInProgress else { throw rejection("operation_in_progress") }
    operationInProgress = true
    defer { operationInProgress = false }
    if manager.connection.status == .connected ||
       manager.connection.status == .connecting ||
       manager.connection.status == .reasserting ||
       manager.connection.status == .disconnecting {
      publish(state: .disconnecting)
    }
    guard await stopAndRemoveOwnedConfiguration(attempts: 80) else {
      return fail("teardown_failed")
    }
    connectionId = nil
    connectedAt = nil
    return publish(state: .disconnected)
  }

  private func prepareRuntimeOwnership() async {
    do {
      try await manager.loadFromPreferences()
      if manager.localizedDescription == "Zagros VPN" {
        if manager.connection.status == .connected ||
           manager.connection.status == .connecting ||
           manager.connection.status == .reasserting ||
           manager.connection.status == .disconnecting {
          manager.connection.stopVPNTunnel()
          let stopped = await waitForStatus(
            { $0 == .disconnected || $0 == .invalid },
            attempts: 80
          )
          guard stopped == .disconnected || stopped == .invalid else {
            throw AdapterError.startupCleanupFailure
          }
        }
        try await manager.removeFromPreferences()
        manager.protocolConfiguration = nil
        manager.localizedDescription = nil
        manager.isEnabled = false
      } else if manager.protocolConfiguration != nil || manager.localizedDescription != nil {
        // This application owns only profiles bearing its fixed marker. Never
        // overwrite or delete an unrecognized Personal VPN configuration.
        throw AdapterError.ownershipConflict
      }
      guard deleteAllOwnedSecrets() else {
        throw AdapterError.startupCleanupFailure
      }
      connectionId = nil
      connectedAt = nil
      startupReady = true
      operationInProgress = false
      _ = publish(state: .disconnected)
    } catch {
      startupReady = false
      operationInProgress = false
      _ = fail("startup_cleanup_failed")
    }
  }

  private func handleStatusChange() {
    // Connect, disconnect, and startup publish their own ordered states. Ignore
    // intermediate notifications while one of those operations owns the manager.
    guard startupReady, !operationInProgress else { return }
    let osStatus = manager.connection.status
    if (osStatus == .disconnected || osStatus == .invalid), connectionId != nil {
      operationInProgress = true
      Task { @MainActor [weak self] in
        guard let self else { return }
        if await self.removeOwnedConfiguration() {
          self.connectionId = nil
          self.connectedAt = nil
          self.operationInProgress = false
          _ = self.publish(state: .disconnected)
        } else {
          self.operationInProgress = false
          _ = self.fail("cleanup_failed")
        }
      }
      return
    }
    publishCurrentStatus()
  }

  private func publishCurrentStatus() {
    guard startupReady, !operationInProgress else { return }
    let next = statusFor(manager.connection.status, increment: true)
    lastStatus = next
    guard let flutterApi else { return }
    Task { try? await flutterApi.onStatusChanged(status: next) }
  }

  @discardableResult
  private func publish(state: NativeTunnelState) -> NativeTunnelStatus {
    sequence += 1
    let next = NativeTunnelStatus(
      state: state,
      sequence: sequence,
      uplinkBytes: 0,
      downlinkBytes: 0,
      connectionId: state == .disconnected ? nil : connectionId,
      protocol: state == .disconnected ? nil : "ikev2",
      connectedAtEpochMs: state == .connected ? connectedAt : nil
    )
    lastStatus = next
    guard let flutterApi else { return next }
    Task { try? await flutterApi.onStatusChanged(status: next) }
    return next
  }

  private func statusFor(_ status: NEVPNStatus, increment: Bool) -> NativeTunnelStatus {
    if increment { sequence += 1 }
    let state: NativeTunnelState
    switch status {
    case .invalid, .disconnected: state = .disconnected
    case .connecting, .reasserting: state = .connecting
    case .connected:
      state = .connected
      if connectedAt == nil { connectedAt = Int64(Date().timeIntervalSince1970 * 1000) }
    case .disconnecting: state = .disconnecting
    @unknown default: state = .failed
    }
    return NativeTunnelStatus(
      state: state,
      sequence: sequence,
      uplinkBytes: 0,
      downlinkBytes: 0,
      connectionId: state == .disconnected ? nil : connectionId,
      protocol: state == .disconnected ? nil : "ikev2",
      connectedAtEpochMs: state == .connected ? connectedAt : nil,
      failureCode: state == .failed ? "unknown_native_state" : nil,
      safeFailureMessage: state == .failed ? "The Apple tunnel failed safely." : nil
    )
  }

  private func rejection(_ code: String) -> PigeonError {
    PigeonError(
      code: code,
      message: "The Apple tunnel request was rejected safely.",
      details: nil
    )
  }

  private func fail(_ code: String) -> NativeTunnelStatus {
    sequence += 1
    let next = NativeTunnelStatus(
      state: .failed,
      sequence: sequence,
      uplinkBytes: 0,
      downlinkBytes: 0,
      connectionId: connectionId,
      protocol: connectionId == nil ? nil : "ikev2",
      failureCode: code,
      safeFailureMessage: "The Apple tunnel failed safely."
    )
    lastStatus = next
    if let flutterApi { Task { try? await flutterApi.onStatusChanged(status: next) } }
    return next
  }

  private func waitForStatus(
    _ accepted: @escaping (NEVPNStatus) -> Bool,
    attempts: Int
  ) async -> NEVPNStatus? {
    for _ in 0..<attempts {
      let status = manager.connection.status
      if accepted(status) { return status }
      try? await Task.sleep(nanoseconds: 250_000_000)
    }
    return nil
  }

  private func storeSecret(_ secret: String, account: String) throws -> Data {
    guard var bytes = secret.data(using: .utf8), bytes.count <= 4096 else {
      throw AdapterError.invalidSecret
    }
    defer { bytes.resetBytes(in: 0..<bytes.count) }
    guard deleteSecret(account) else { throw AdapterError.keychainFailure }
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.keychainService,
      kSecAttrAccount: account,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData: bytes,
      kSecReturnPersistentRef: true
    ]
    var result: CFTypeRef?
    guard SecItemAdd(query as CFDictionary, &result) == errSecSuccess,
          let reference = result as? Data else {
      throw AdapterError.keychainFailure
    }
    keychainAccounts.append(account)
    return reference
  }

  private func deleteSecret(_ account: String) -> Bool {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.keychainService,
      kSecAttrAccount: account
    ]
    let result = SecItemDelete(query as CFDictionary)
    return result == errSecSuccess || result == errSecItemNotFound
  }

  private func deleteAllOwnedSecrets() -> Bool {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.keychainService
    ]
    let result = SecItemDelete(query as CFDictionary)
    let removed = result == errSecSuccess || result == errSecItemNotFound
    if removed { keychainAccounts.removeAll(keepingCapacity: false) }
    return removed
  }

  private func stopAndRemoveOwnedConfiguration(attempts: Int) async -> Bool {
    let status = manager.connection.status
    if status == .connected || status == .connecting ||
       status == .reasserting || status == .disconnecting {
      manager.connection.stopVPNTunnel()
      let stopped = await waitForStatus(
        { $0 == .disconnected || $0 == .invalid },
        attempts: attempts
      )
      guard stopped == .disconnected || stopped == .invalid else { return false }
    }
    return await removeOwnedConfiguration()
  }

  @MainActor
  private func removeOwnedConfiguration() async -> Bool {
    if manager.localizedDescription == "Zagros VPN" {
      do {
        try await manager.removeFromPreferences()
        manager.protocolConfiguration = nil
        manager.localizedDescription = nil
        manager.isEnabled = false
      } catch {
        return false
      }
    } else if manager.protocolConfiguration != nil || manager.localizedDescription != nil {
      // Never treat an unrecognized app-scoped Personal VPN configuration as
      // absent and then overwrite it during a later load/save sequence.
      return false
    }
    return deleteAllOwnedSecrets()
  }

  private enum AdapterError: Error {
    case invalidSecret
    case keychainFailure
    case startupCleanupFailure
    case ownershipConflict
  }

  private struct SystemVpnConfiguration {
    let server: String
    let username: String?
    let password: String?
    let sharedSecret: String?
    let remoteIdentifier: String
    let localIdentifier: String?
  }

  private static func decode(_ data: Data) -> SystemVpnConfiguration? {
    let allowedKeys: Set<String> = [
      "version", "server", "port", "username", "password", "shared_secret",
      "remote_identifier", "local_identifier"
    ]
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          root.count <= allowedKeys.count,
          Set(root.keys).isSubset(of: allowedKeys),
          root["version"] as? Int == 1,
          root["port"] as? Int == 500,
          let server = scalar(root["server"], maximum: 253),
          let remoteIdentifier = scalar(root["remote_identifier"], maximum: 1024)
    else { return nil }
    let username = optionalScalar(root["username"], maximum: 1024)
    let password = optionalScalar(root["password"], maximum: 4096)
    let sharedSecret = optionalScalar(root["shared_secret"], maximum: 4096)
    let localIdentifier = optionalScalar(root["local_identifier"], maximum: 1024)
    guard (username == nil) == (password == nil), password != nil || sharedSecret != nil else {
      return nil
    }
    return SystemVpnConfiguration(
      server: server,
      username: username,
      password: password,
      sharedSecret: sharedSecret,
      remoteIdentifier: remoteIdentifier,
      localIdentifier: localIdentifier
    )
  }

  private static func scalar(_ value: Any?, maximum: Int) -> String? {
    guard let value = value as? String,
          !value.isEmpty,
          value.utf8.count <= maximum,
          value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
    else { return nil }
    return value
  }

  private static func optionalScalar(_ value: Any?, maximum: Int) -> String? {
    guard value != nil else { return nil }
    return scalar(value, maximum: maximum)
  }

  private static func safeIdentifier(_ value: String) -> Bool {
    value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", options: .regularExpression) != nil
  }

  private static func safeReason(_ value: String) -> Bool {
    value.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) != nil
  }

  private static var platformName: String {
    #if os(iOS)
    return "ios"
    #else
    return "macos"
    #endif
  }

  private static let keychainService = "ai.zagros.tunnel.runtime"
  private static let maximumConfigBytes = 256 * 1024
}
