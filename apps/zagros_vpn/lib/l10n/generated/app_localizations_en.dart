// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get home => 'Home';

  @override
  String get configs => 'Configs';

  @override
  String get logs => 'Logs';

  @override
  String get overview => 'Overview';

  @override
  String get library => 'Library';

  @override
  String get account => 'Account';

  @override
  String get settings => 'Settings';

  @override
  String get officialProduct => 'Official client';

  @override
  String get whiteLabelProduct => 'Application client';

  @override
  String get foundationTitle => 'Secure client services';

  @override
  String get foundationBody =>
      'Product policy, OS-protected storage, localization, and native tunnel orchestration are composed from one shared source tree.';

  @override
  String get libraryBody =>
      'Official subscriptions and manual configurations are managed here under SDK policy.';

  @override
  String get accountBody =>
      'Application enrollment and authenticated access are available only in White-label mode.';

  @override
  String get settingsBody =>
      'Review security, platform capability, and open-source information without exposing runtime configuration.';

  @override
  String get openSourceLicenses => 'Open-source licenses';

  @override
  String get openSourceLicensesBody =>
      'Review notices and licenses for Flutter and native tunnel components.';

  @override
  String get configurationError => 'This build configuration is invalid.';

  @override
  String get modeLabel => 'Product mode';

  @override
  String get secureStorageLabel => 'Secure storage';

  @override
  String get secureStorageReady => 'OS-protected adapter configured';

  @override
  String get nativeTunnelLabel => 'Native tunnel';

  @override
  String get nativeTunnelPending =>
      'Protocol availability is discovered from the installed native platform adapter.';

  @override
  String get libraryUnavailableTitle => 'Official library unavailable';

  @override
  String get libraryUnavailableBody =>
      'This product policy does not provide the Official profile repository.';

  @override
  String get libraryLoadFailed => 'Could not open the protected library';

  @override
  String get retry => 'Retry';

  @override
  String get libraryEmptyTitle => 'No profiles yet';

  @override
  String get libraryEmptyBody =>
      'Add a subscription or paste a supported manual configuration. Secrets are stored only through OS-protected storage.';

  @override
  String get libraryTitle => 'VPN profiles';

  @override
  String get libraryDescription =>
      'Manage Official subscriptions and manual configurations parsed by the Zagros SDK.';

  @override
  String get tunnelUnavailableTitle => 'Connection unavailable';

  @override
  String get tunnelUnavailableBody =>
      'The installed native adapter does not support this configuration on the current platform.';

  @override
  String get addSubscription => 'Add subscription';

  @override
  String get addManualConfig => 'Add manual config';

  @override
  String get subscriptionRefreshed => 'Subscription refreshed.';

  @override
  String get deleteProfileTitle => 'Delete profile?';

  @override
  String deleteProfileBody(String name) {
    return 'Delete “$name” and its protected configurations?';
  }

  @override
  String get cancel => 'Cancel';

  @override
  String get delete => 'Delete';

  @override
  String get deleted => 'Profile deleted.';

  @override
  String get edit => 'Edit';

  @override
  String get refresh => 'Refresh';

  @override
  String get saved => 'Profile saved.';

  @override
  String get subscriptionProfile => 'Subscription';

  @override
  String get manualProfile => 'Manual configuration';

  @override
  String profileConfigCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count configurations',
      one: '1 configuration',
      zero: 'No configurations',
    );
    return '$_temp0';
  }

  @override
  String subscriptionHost(String host) {
    return 'Source: $host';
  }

  @override
  String get protocolWarningPresent => 'Protocol warning';

  @override
  String get configFileBadge => 'File';

  @override
  String subscriptionFilesUnavailable(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count downloaded files are unavailable',
      one: '1 downloaded file is unavailable',
    );
    return '$_temp0';
  }

  @override
  String get profileName => 'Profile name';

  @override
  String get subscriptionUrl => 'Subscription URL';

  @override
  String get rawConfiguration => 'Raw configuration';

  @override
  String get subscriptionUrlHelp =>
      'HTTPS is required. HTTP is accepted only for a loopback development server.';

  @override
  String get manualConfigHelp =>
      'Paste a share link list, WireGuard, OpenVPN, Clash, or sing-box configuration.';

  @override
  String get editProfile => 'Edit profile';

  @override
  String get save => 'Save';

  @override
  String get close => 'Close';

  @override
  String subscriptionUsage(String used, String total) {
    return 'Used $used of $total';
  }

  @override
  String get unlimited => 'unlimited';

  @override
  String get viewRawConfig => 'View raw';

  @override
  String get connect => 'Connect';

  @override
  String get disconnect => 'Disconnect';

  @override
  String get rawConfigTitle => 'Raw configuration';

  @override
  String get rawConfigSecretWarning =>
      'This configuration contains credentials. Do not share it with anyone you do not trust.';

  @override
  String get copy => 'Copy';

  @override
  String get export => 'Export';

  @override
  String get copied => 'Configuration copied.';

  @override
  String get rawActionFailed => 'The protected raw-config action failed.';

  @override
  String get exportRawTitle => 'Export plaintext configuration?';

  @override
  String get exportRawWarning =>
      'Export writes credentials to a plaintext file at a user-accessible location. Protect or delete that file after use.';

  @override
  String get exported => 'Configuration exported.';

  @override
  String get legacyProtocolWarning =>
      'PPTP is legacy and insecure, and is unavailable on modern iOS and Android systems.';

  @override
  String get platformProtocolWarning =>
      'L2TP support depends on the operating system and is limited on modern iOS and Android systems.';

  @override
  String get genericProtocolWarning =>
      'Review this protocol warning before connecting.';

  @override
  String get libraryValidationFailed =>
      'The profile name, URL, or configuration is invalid.';

  @override
  String get libraryAccessDenied =>
      'The server or product policy denied this operation.';

  @override
  String get libraryNetworkFailed =>
      'The subscription could not be reached. The previous profile was kept.';

  @override
  String get libraryStorageFailed =>
      'OS-protected storage is unavailable. No plaintext fallback was used.';

  @override
  String get libraryMalformedFailed =>
      'The configuration or protected catalog is malformed.';

  @override
  String get libraryUnknownFailed => 'The operation could not be completed.';

  @override
  String get protocolUnavailableTitle => 'Protocol unavailable';

  @override
  String protocolUnavailableBody(String protocol) {
    return 'The installed tunnel adapter does not support $protocol.';
  }

  @override
  String get connectionRequestedTitle => 'Connection requested';

  @override
  String get connectionRequestedBody =>
      'The native adapter accepted the request but has not confirmed a connected state.';

  @override
  String get connectedTitle => 'Connected';

  @override
  String get connectedBody =>
      'The native adapter confirmed the tunnel connection.';

  @override
  String get connectionFailedTitle => 'Connection failed';

  @override
  String get connectionFailedBody =>
      'The native tunnel adapter rejected the request.';

  @override
  String get ok => 'OK';

  @override
  String get enrollTitle => 'Enroll this device';

  @override
  String get loginTitle => 'Sign in';

  @override
  String get usernameLabel => 'Username';

  @override
  String get passwordLabel => 'Password';

  @override
  String get activationCodeLabel => 'Activation code';

  @override
  String get enrollAction => 'Enroll device';

  @override
  String get loginAction => 'Sign in';

  @override
  String get logoutAction => 'Sign out';

  @override
  String get reEnrollAction => 'Use a different activation code';

  @override
  String get configsTitle => 'Connections';

  @override
  String get usageTitle => 'Usage';

  @override
  String get available => 'Available';

  @override
  String get unavailable => 'Unavailable';

  @override
  String activeConnectionsCount(int count) {
    return 'Active connections: $count';
  }

  @override
  String signedInAs(String username) {
    return 'Signed in as $username';
  }

  @override
  String get noConfigsTitle => 'No connections available';

  @override
  String get noConfigsBody =>
      'The server returned no connectable configurations for this account.';

  @override
  String get serviceUnavailableTitle => 'Account unavailable';

  @override
  String get serviceUnavailableBody =>
      'The Application service could not start. OS-protected storage may be unavailable.';

  @override
  String get alreadyConnectedTitle => 'Already connected';

  @override
  String get alreadyConnectedBody =>
      'Disconnect the active connection before starting another.';

  @override
  String get errorEnrollInput =>
      'Enter a username, password, and activation code.';

  @override
  String get errorLoginInput => 'Enter a username and password.';

  @override
  String get errorInvalidCredentials =>
      'The username or password is incorrect.';

  @override
  String get errorTicketInvalid => 'The activation code is invalid or expired.';

  @override
  String get errorAccessDenied =>
      'This account or device is not allowed to connect.';

  @override
  String get errorSessionExpired => 'The session expired. Sign in again.';

  @override
  String get errorEnrollmentRequired =>
      'This device is no longer enrolled. Enter a new activation code.';

  @override
  String get errorNetwork =>
      'The server could not be reached. Check the connection and retry.';

  @override
  String get errorRateLimited => 'Too many attempts. Wait a moment and retry.';

  @override
  String get errorStorage =>
      'OS-protected storage is unavailable. No plaintext fallback was used.';

  @override
  String get errorUnknown => 'The operation could not be completed.';

  @override
  String get speedDownload => 'Download';

  @override
  String get speedUpload => 'Upload';

  @override
  String get statusDisconnected => 'Disconnected';

  @override
  String get statusConnecting => 'Connecting...';

  @override
  String get statusConnected => 'Connected';

  @override
  String get statusDisconnecting => 'Disconnecting...';

  @override
  String get statusFailed => 'Connection Failed';

  @override
  String get noActiveConfig => 'No configuration selected';

  @override
  String get selectConfigToConnect => 'Select a configuration to connect';

  @override
  String get comingSoon => 'Coming Soon';

  @override
  String get unsupportedProtocol => 'Unsupported';

  @override
  String get protocolNotImplemented =>
      'This protocol engine is not packaged in this release and will be available in future updates.';

  @override
  String get clearLogs => 'Clear logs';

  @override
  String get copyLogs => 'Copy logs';

  @override
  String get logsCopied => 'Logs copied to clipboard.';

  @override
  String get noLogsYet => 'No connection logs recorded yet.';

  @override
  String get language => 'Language';

  @override
  String get persian => 'فارسی';

  @override
  String get english => 'English';

  @override
  String get dnsSettings => 'DNS Settings';

  @override
  String get dnsSystem => 'System Default';

  @override
  String get dnsCloudflare => 'Cloudflare (1.1.1.1)';

  @override
  String get dnsGoogle => 'Google (8.8.8.8)';

  @override
  String get dnsCustom => 'Custom DNS';

  @override
  String get customDnsAddress => 'Custom DNS Server';

  @override
  String get fakeDnsTitle => 'Fake DNS';

  @override
  String get fakeDnsSubtitle =>
      'Domains answer from a synthetic pool for faster connects; real addresses are restored inside the tunnel.';

  @override
  String get perAppTitle => 'Per-app proxy';

  @override
  String get perAppSubtitle => 'Choose which apps go through the VPN tunnel.';

  @override
  String get perAppAllowMode => 'Only selected apps use the VPN';

  @override
  String get perAppDenyMode => 'Selected apps bypass the VPN';

  @override
  String get perAppSelectApps => 'Select apps';

  @override
  String get perAppSearch => 'Search apps';

  @override
  String perAppSelectedCount(int count) {
    return '$count selected';
  }

  @override
  String get perAppNoApps => 'No apps found';

  @override
  String get perAppClearAll => 'Clear';

  @override
  String get perAppAppliesNextConnect => 'Applies on the next connection.';

  @override
  String get ping => 'Ping';

  @override
  String get ms => 'ms';

  @override
  String get accountInfo => 'Account Information';

  @override
  String get tapToConnect => 'Tap to connect';

  @override
  String get tapToDisconnect => 'Tap to disconnect';

  @override
  String get activeConfigLabel => 'Active Server';

  @override
  String get subscriptionsSection => 'Subscriptions';

  @override
  String get localConfigsSection => 'Local';

  @override
  String subscriptionRemaining(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days remaining',
      one: '1 day remaining',
      zero: 'Expires today',
    );
    return '$_temp0';
  }

  @override
  String subscriptionExpires(String date) {
    return 'Expires $date';
  }

  @override
  String subscriptionUpdateInterval(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '$hours hours',
      one: '1 hour',
    );
    return 'Suggested refresh interval: $_temp0';
  }

  @override
  String subscriptionLastRefreshed(String date) {
    return 'Last refreshed $date';
  }
}
