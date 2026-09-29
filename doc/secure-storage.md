# Secure storage and plaintext policy

## Stored records

The Flutter bridge implements SDK `SecureValueStore` and `SecureTokenStore` over `flutter_secure_storage` 11.0.0. Keys are bounded and namespaced (`zagros.official` or `zagros.whitelabel`); invalid namespaces and keys fail closed. Identity values are limited to 64 KiB and token state to 16 KiB. Both are encoded before reaching the plugin and have pre-decode and post-decode bounds.

Encoding is not an independent confidentiality layer. Confidentiality at rest comes from the platform backend. Backend read/write/delete errors become safe client exceptions and never fall back to preferences, files, SQLite, caches, or temporary plaintext.

Raw White-label `NormalizedConfig`, opened envelopes, and native `configPayload` are intentionally absent from the storage adapter. They may exist only in runtime memory for immediate tunnel handoff.

## Platform configuration

### Android

- The Flutter 3.47 foundation currently sets the application minimum to Android API 24 (the storage plugin itself requires at least API 23).
- The plugin uses RSA-OAEP key wrapping plus AES-GCM storage by default.
- Algorithm migration is enabled with crash-resistant encrypted backup records; these are not Android cloud backups.
- Auto Backup is disabled with `android:allowBackup="false"`.
- Legacy backup and Android 12+ data-extraction rules exclude root, files, databases, shared preferences, and external app data.
- Cleartext application traffic is disabled.
- Storage uses the fixed `zagros_vpn` plugin namespace; product record prefixes remain separate.

Release acceptance still requires an Android SDK, Java 17–25 for the generated Gradle version, a signed build, and on-device uninstall/reinstall/backup behavior tests.

### iOS and macOS

Both Debug/Profile and Release entitlements include Keychain Sharing configuration. The client uses account name `ai.zagros.vpn`, non-synchronizing records, and `unlocked_this_device` accessibility. Records therefore are not intended to sync or migrate between devices. macOS also enables outbound client networking in the app sandbox.

Debug/Profile and Release source entitlements now also declare Personal VPN (`com.apple.developer.networking.vpn.api` / `allow-vpn`) for the built-in IKEv2 adapter. This source declaration is not provisioning evidence. Actual signed entitlements must be inspected on final products (`codesign` and provisioning profiles), and Keychain plus VPN profile create/connect/remove/relaunch behavior must run on real Apple targets. The adapter's this-device-only IKEv2 secret items are separate from SDK storage and are deleted on teardown/startup ownership cleanup.

### Windows

The selected plugin stores an AES-GCM encrypted file and keeps its encryption key in Windows Credential Manager; backward compatibility is disabled. Building requires a supported Windows worker, Visual Studio C++ tooling, CMake, and the C++ ATL optional component. Final acceptance requires a signed package and real Credential Manager round-trip/failure tests.

### Linux

The selected plugin uses Secret Service through `libsecret`. Build hosts require `libsecret` development headers, and packaged applications require the runtime library plus an available, unlocked keyring service (for example GNOME Keyring or KDE Wallet). There is no plaintext fallback for a headless or unavailable keyring. Final acceptance requires packaging metadata and real keyring integration tests.

## Limits

OS secure storage does not prevent extraction by a device owner controlling the operating system or runtime. Plaintext necessarily exists in process memory while used. Root/jailbreak, debugging, memory inspection, compromised accessibility, and compromised build/signing systems remain relevant threats; documentation and UI must never claim client secrets are impossible to extract.
