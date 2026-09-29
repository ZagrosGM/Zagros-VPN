import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_fa.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('fa')
  ];

  /// No description provided for @home.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get home;

  /// No description provided for @configs.
  ///
  /// In en, this message translates to:
  /// **'Configs'**
  String get configs;

  /// No description provided for @logs.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get logs;

  /// No description provided for @overview.
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get overview;

  /// No description provided for @library.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get library;

  /// No description provided for @account.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get account;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @officialProduct.
  ///
  /// In en, this message translates to:
  /// **'Official client'**
  String get officialProduct;

  /// No description provided for @whiteLabelProduct.
  ///
  /// In en, this message translates to:
  /// **'Application client'**
  String get whiteLabelProduct;

  /// No description provided for @foundationTitle.
  ///
  /// In en, this message translates to:
  /// **'Secure client services'**
  String get foundationTitle;

  /// No description provided for @foundationBody.
  ///
  /// In en, this message translates to:
  /// **'Product policy, OS-protected storage, localization, and native tunnel orchestration are composed from one shared source tree.'**
  String get foundationBody;

  /// No description provided for @libraryBody.
  ///
  /// In en, this message translates to:
  /// **'Official subscriptions and manual configurations are managed here under SDK policy.'**
  String get libraryBody;

  /// No description provided for @accountBody.
  ///
  /// In en, this message translates to:
  /// **'Application enrollment and authenticated access are available only in White-label mode.'**
  String get accountBody;

  /// No description provided for @settingsBody.
  ///
  /// In en, this message translates to:
  /// **'Review security, platform capability, and open-source information without exposing runtime configuration.'**
  String get settingsBody;

  /// No description provided for @openSourceLicenses.
  ///
  /// In en, this message translates to:
  /// **'Open-source licenses'**
  String get openSourceLicenses;

  /// No description provided for @openSourceLicensesBody.
  ///
  /// In en, this message translates to:
  /// **'Review notices and licenses for Flutter and native tunnel components.'**
  String get openSourceLicensesBody;

  /// No description provided for @configurationError.
  ///
  /// In en, this message translates to:
  /// **'This build configuration is invalid.'**
  String get configurationError;

  /// No description provided for @modeLabel.
  ///
  /// In en, this message translates to:
  /// **'Product mode'**
  String get modeLabel;

  /// No description provided for @secureStorageLabel.
  ///
  /// In en, this message translates to:
  /// **'Secure storage'**
  String get secureStorageLabel;

  /// No description provided for @secureStorageReady.
  ///
  /// In en, this message translates to:
  /// **'OS-protected adapter configured'**
  String get secureStorageReady;

  /// No description provided for @nativeTunnelLabel.
  ///
  /// In en, this message translates to:
  /// **'Native tunnel'**
  String get nativeTunnelLabel;

  /// No description provided for @nativeTunnelPending.
  ///
  /// In en, this message translates to:
  /// **'Protocol availability is discovered from the installed native platform adapter.'**
  String get nativeTunnelPending;

  /// No description provided for @libraryUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Official library unavailable'**
  String get libraryUnavailableTitle;

  /// No description provided for @libraryUnavailableBody.
  ///
  /// In en, this message translates to:
  /// **'This product policy does not provide the Official profile repository.'**
  String get libraryUnavailableBody;

  /// No description provided for @libraryLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open the protected library'**
  String get libraryLoadFailed;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @libraryEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No profiles yet'**
  String get libraryEmptyTitle;

  /// No description provided for @libraryEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Add a subscription or paste a supported manual configuration. Secrets are stored only through OS-protected storage.'**
  String get libraryEmptyBody;

  /// No description provided for @libraryTitle.
  ///
  /// In en, this message translates to:
  /// **'VPN profiles'**
  String get libraryTitle;

  /// No description provided for @libraryDescription.
  ///
  /// In en, this message translates to:
  /// **'Manage Official subscriptions and manual configurations parsed by the Zagros SDK.'**
  String get libraryDescription;

  /// No description provided for @tunnelUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection unavailable'**
  String get tunnelUnavailableTitle;

  /// No description provided for @tunnelUnavailableBody.
  ///
  /// In en, this message translates to:
  /// **'The installed native adapter does not support this configuration on the current platform.'**
  String get tunnelUnavailableBody;

  /// No description provided for @addSubscription.
  ///
  /// In en, this message translates to:
  /// **'Add subscription'**
  String get addSubscription;

  /// No description provided for @addManualConfig.
  ///
  /// In en, this message translates to:
  /// **'Add manual config'**
  String get addManualConfig;

  /// No description provided for @subscriptionRefreshed.
  ///
  /// In en, this message translates to:
  /// **'Subscription refreshed.'**
  String get subscriptionRefreshed;

  /// No description provided for @deleteProfileTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete profile?'**
  String get deleteProfileTitle;

  /// No description provided for @deleteProfileBody.
  ///
  /// In en, this message translates to:
  /// **'Delete “{name}” and its protected configurations?'**
  String deleteProfileBody(String name);

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @deleted.
  ///
  /// In en, this message translates to:
  /// **'Profile deleted.'**
  String get deleted;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @saved.
  ///
  /// In en, this message translates to:
  /// **'Profile saved.'**
  String get saved;

  /// No description provided for @subscriptionProfile.
  ///
  /// In en, this message translates to:
  /// **'Subscription'**
  String get subscriptionProfile;

  /// No description provided for @manualProfile.
  ///
  /// In en, this message translates to:
  /// **'Manual configuration'**
  String get manualProfile;

  /// No description provided for @profileConfigCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No configurations} =1{1 configuration} other{{count} configurations}}'**
  String profileConfigCount(int count);

  /// No description provided for @subscriptionHost.
  ///
  /// In en, this message translates to:
  /// **'Source: {host}'**
  String subscriptionHost(String host);

  /// No description provided for @protocolWarningPresent.
  ///
  /// In en, this message translates to:
  /// **'Protocol warning'**
  String get protocolWarningPresent;

  /// No description provided for @configFileBadge.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get configFileBadge;

  /// No description provided for @subscriptionFilesUnavailable.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 downloaded file is unavailable} other{{count} downloaded files are unavailable}}'**
  String subscriptionFilesUnavailable(int count);

  /// No description provided for @profileName.
  ///
  /// In en, this message translates to:
  /// **'Profile name'**
  String get profileName;

  /// No description provided for @subscriptionUrl.
  ///
  /// In en, this message translates to:
  /// **'Subscription URL'**
  String get subscriptionUrl;

  /// No description provided for @rawConfiguration.
  ///
  /// In en, this message translates to:
  /// **'Raw configuration'**
  String get rawConfiguration;

  /// No description provided for @subscriptionUrlHelp.
  ///
  /// In en, this message translates to:
  /// **'HTTPS is required. HTTP is accepted only for a loopback development server.'**
  String get subscriptionUrlHelp;

  /// No description provided for @manualConfigHelp.
  ///
  /// In en, this message translates to:
  /// **'Paste a share link list, WireGuard, OpenVPN, Clash, or sing-box configuration.'**
  String get manualConfigHelp;

  /// No description provided for @editProfile.
  ///
  /// In en, this message translates to:
  /// **'Edit profile'**
  String get editProfile;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @subscriptionUsage.
  ///
  /// In en, this message translates to:
  /// **'Used {used} of {total}'**
  String subscriptionUsage(String used, String total);

  /// No description provided for @unlimited.
  ///
  /// In en, this message translates to:
  /// **'unlimited'**
  String get unlimited;

  /// No description provided for @viewRawConfig.
  ///
  /// In en, this message translates to:
  /// **'View raw'**
  String get viewRawConfig;

  /// No description provided for @connect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connect;

  /// No description provided for @disconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// No description provided for @rawConfigTitle.
  ///
  /// In en, this message translates to:
  /// **'Raw configuration'**
  String get rawConfigTitle;

  /// No description provided for @rawConfigSecretWarning.
  ///
  /// In en, this message translates to:
  /// **'This configuration contains credentials. Do not share it with anyone you do not trust.'**
  String get rawConfigSecretWarning;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @export.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get export;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Configuration copied.'**
  String get copied;

  /// No description provided for @rawActionFailed.
  ///
  /// In en, this message translates to:
  /// **'The protected raw-config action failed.'**
  String get rawActionFailed;

  /// No description provided for @exportRawTitle.
  ///
  /// In en, this message translates to:
  /// **'Export plaintext configuration?'**
  String get exportRawTitle;

  /// No description provided for @exportRawWarning.
  ///
  /// In en, this message translates to:
  /// **'Export writes credentials to a plaintext file at a user-accessible location. Protect or delete that file after use.'**
  String get exportRawWarning;

  /// No description provided for @exported.
  ///
  /// In en, this message translates to:
  /// **'Configuration exported.'**
  String get exported;

  /// No description provided for @legacyProtocolWarning.
  ///
  /// In en, this message translates to:
  /// **'PPTP is legacy and insecure, and is unavailable on modern iOS and Android systems.'**
  String get legacyProtocolWarning;

  /// No description provided for @platformProtocolWarning.
  ///
  /// In en, this message translates to:
  /// **'L2TP support depends on the operating system and is limited on modern iOS and Android systems.'**
  String get platformProtocolWarning;

  /// No description provided for @genericProtocolWarning.
  ///
  /// In en, this message translates to:
  /// **'Review this protocol warning before connecting.'**
  String get genericProtocolWarning;

  /// No description provided for @libraryValidationFailed.
  ///
  /// In en, this message translates to:
  /// **'The profile name, URL, or configuration is invalid.'**
  String get libraryValidationFailed;

  /// No description provided for @libraryAccessDenied.
  ///
  /// In en, this message translates to:
  /// **'The server or product policy denied this operation.'**
  String get libraryAccessDenied;

  /// No description provided for @libraryNetworkFailed.
  ///
  /// In en, this message translates to:
  /// **'The subscription could not be reached. The previous profile was kept.'**
  String get libraryNetworkFailed;

  /// No description provided for @libraryStorageFailed.
  ///
  /// In en, this message translates to:
  /// **'OS-protected storage is unavailable. No plaintext fallback was used.'**
  String get libraryStorageFailed;

  /// No description provided for @libraryMalformedFailed.
  ///
  /// In en, this message translates to:
  /// **'The configuration or protected catalog is malformed.'**
  String get libraryMalformedFailed;

  /// No description provided for @libraryUnknownFailed.
  ///
  /// In en, this message translates to:
  /// **'The operation could not be completed.'**
  String get libraryUnknownFailed;

  /// No description provided for @protocolUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Protocol unavailable'**
  String get protocolUnavailableTitle;

  /// No description provided for @protocolUnavailableBody.
  ///
  /// In en, this message translates to:
  /// **'The installed tunnel adapter does not support {protocol}.'**
  String protocolUnavailableBody(String protocol);

  /// No description provided for @connectionRequestedTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection requested'**
  String get connectionRequestedTitle;

  /// No description provided for @connectionRequestedBody.
  ///
  /// In en, this message translates to:
  /// **'The native adapter accepted the request but has not confirmed a connected state.'**
  String get connectionRequestedBody;

  /// No description provided for @connectedTitle.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connectedTitle;

  /// No description provided for @connectedBody.
  ///
  /// In en, this message translates to:
  /// **'The native adapter confirmed the tunnel connection.'**
  String get connectedBody;

  /// No description provided for @connectionFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get connectionFailedTitle;

  /// No description provided for @connectionFailedBody.
  ///
  /// In en, this message translates to:
  /// **'The native tunnel adapter rejected the request.'**
  String get connectionFailedBody;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @enrollTitle.
  ///
  /// In en, this message translates to:
  /// **'Enroll this device'**
  String get enrollTitle;

  /// No description provided for @loginTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get loginTitle;

  /// No description provided for @usernameLabel.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get usernameLabel;

  /// No description provided for @passwordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get passwordLabel;

  /// No description provided for @activationCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Activation code'**
  String get activationCodeLabel;

  /// No description provided for @enrollAction.
  ///
  /// In en, this message translates to:
  /// **'Enroll device'**
  String get enrollAction;

  /// No description provided for @loginAction.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get loginAction;

  /// No description provided for @logoutAction.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get logoutAction;

  /// No description provided for @reEnrollAction.
  ///
  /// In en, this message translates to:
  /// **'Use a different activation code'**
  String get reEnrollAction;

  /// No description provided for @configsTitle.
  ///
  /// In en, this message translates to:
  /// **'Connections'**
  String get configsTitle;

  /// No description provided for @usageTitle.
  ///
  /// In en, this message translates to:
  /// **'Usage'**
  String get usageTitle;

  /// No description provided for @available.
  ///
  /// In en, this message translates to:
  /// **'Available'**
  String get available;

  /// No description provided for @unavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get unavailable;

  /// No description provided for @activeConnectionsCount.
  ///
  /// In en, this message translates to:
  /// **'Active connections: {count}'**
  String activeConnectionsCount(int count);

  /// No description provided for @signedInAs.
  ///
  /// In en, this message translates to:
  /// **'Signed in as {username}'**
  String signedInAs(String username);

  /// No description provided for @noConfigsTitle.
  ///
  /// In en, this message translates to:
  /// **'No connections available'**
  String get noConfigsTitle;

  /// No description provided for @noConfigsBody.
  ///
  /// In en, this message translates to:
  /// **'The server returned no connectable configurations for this account.'**
  String get noConfigsBody;

  /// No description provided for @serviceUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Account unavailable'**
  String get serviceUnavailableTitle;

  /// No description provided for @serviceUnavailableBody.
  ///
  /// In en, this message translates to:
  /// **'The Application service could not start. OS-protected storage may be unavailable.'**
  String get serviceUnavailableBody;

  /// No description provided for @alreadyConnectedTitle.
  ///
  /// In en, this message translates to:
  /// **'Already connected'**
  String get alreadyConnectedTitle;

  /// No description provided for @alreadyConnectedBody.
  ///
  /// In en, this message translates to:
  /// **'Disconnect the active connection before starting another.'**
  String get alreadyConnectedBody;

  /// No description provided for @errorEnrollInput.
  ///
  /// In en, this message translates to:
  /// **'Enter a username, password, and activation code.'**
  String get errorEnrollInput;

  /// No description provided for @errorLoginInput.
  ///
  /// In en, this message translates to:
  /// **'Enter a username and password.'**
  String get errorLoginInput;

  /// No description provided for @errorInvalidCredentials.
  ///
  /// In en, this message translates to:
  /// **'The username or password is incorrect.'**
  String get errorInvalidCredentials;

  /// No description provided for @errorTicketInvalid.
  ///
  /// In en, this message translates to:
  /// **'The activation code is invalid or expired.'**
  String get errorTicketInvalid;

  /// No description provided for @errorAccessDenied.
  ///
  /// In en, this message translates to:
  /// **'This account or device is not allowed to connect.'**
  String get errorAccessDenied;

  /// No description provided for @errorSessionExpired.
  ///
  /// In en, this message translates to:
  /// **'The session expired. Sign in again.'**
  String get errorSessionExpired;

  /// No description provided for @errorEnrollmentRequired.
  ///
  /// In en, this message translates to:
  /// **'This device is no longer enrolled. Enter a new activation code.'**
  String get errorEnrollmentRequired;

  /// No description provided for @errorNetwork.
  ///
  /// In en, this message translates to:
  /// **'The server could not be reached. Check the connection and retry.'**
  String get errorNetwork;

  /// No description provided for @errorRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Wait a moment and retry.'**
  String get errorRateLimited;

  /// No description provided for @errorStorage.
  ///
  /// In en, this message translates to:
  /// **'OS-protected storage is unavailable. No plaintext fallback was used.'**
  String get errorStorage;

  /// No description provided for @errorUnknown.
  ///
  /// In en, this message translates to:
  /// **'The operation could not be completed.'**
  String get errorUnknown;

  /// No description provided for @speedDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get speedDownload;

  /// No description provided for @speedUpload.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get speedUpload;

  /// No description provided for @statusDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get statusDisconnected;

  /// No description provided for @statusConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting...'**
  String get statusConnecting;

  /// No description provided for @statusConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get statusConnected;

  /// No description provided for @statusDisconnecting.
  ///
  /// In en, this message translates to:
  /// **'Disconnecting...'**
  String get statusDisconnecting;

  /// No description provided for @statusFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection Failed'**
  String get statusFailed;

  /// No description provided for @noActiveConfig.
  ///
  /// In en, this message translates to:
  /// **'No configuration selected'**
  String get noActiveConfig;

  /// No description provided for @selectConfigToConnect.
  ///
  /// In en, this message translates to:
  /// **'Select a configuration to connect'**
  String get selectConfigToConnect;

  /// No description provided for @comingSoon.
  ///
  /// In en, this message translates to:
  /// **'Coming Soon'**
  String get comingSoon;

  /// No description provided for @unsupportedProtocol.
  ///
  /// In en, this message translates to:
  /// **'Unsupported'**
  String get unsupportedProtocol;

  /// No description provided for @protocolNotImplemented.
  ///
  /// In en, this message translates to:
  /// **'This protocol engine is not packaged in this release and will be available in future updates.'**
  String get protocolNotImplemented;

  /// No description provided for @clearLogs.
  ///
  /// In en, this message translates to:
  /// **'Clear logs'**
  String get clearLogs;

  /// No description provided for @copyLogs.
  ///
  /// In en, this message translates to:
  /// **'Copy logs'**
  String get copyLogs;

  /// No description provided for @logsCopied.
  ///
  /// In en, this message translates to:
  /// **'Logs copied to clipboard.'**
  String get logsCopied;

  /// No description provided for @noLogsYet.
  ///
  /// In en, this message translates to:
  /// **'No connection logs recorded yet.'**
  String get noLogsYet;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @persian.
  ///
  /// In en, this message translates to:
  /// **'فارسی'**
  String get persian;

  /// No description provided for @english.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get english;

  /// No description provided for @dnsSettings.
  ///
  /// In en, this message translates to:
  /// **'DNS Settings'**
  String get dnsSettings;

  /// No description provided for @dnsSystem.
  ///
  /// In en, this message translates to:
  /// **'System Default'**
  String get dnsSystem;

  /// No description provided for @dnsCloudflare.
  ///
  /// In en, this message translates to:
  /// **'Cloudflare (1.1.1.1)'**
  String get dnsCloudflare;

  /// No description provided for @dnsGoogle.
  ///
  /// In en, this message translates to:
  /// **'Google (8.8.8.8)'**
  String get dnsGoogle;

  /// No description provided for @dnsCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom DNS'**
  String get dnsCustom;

  /// No description provided for @customDnsAddress.
  ///
  /// In en, this message translates to:
  /// **'Custom DNS Server'**
  String get customDnsAddress;

  /// No description provided for @fakeDnsTitle.
  ///
  /// In en, this message translates to:
  /// **'Fake DNS'**
  String get fakeDnsTitle;

  /// No description provided for @fakeDnsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Domains answer from a synthetic pool for faster connects; real addresses are restored inside the tunnel.'**
  String get fakeDnsSubtitle;

  /// No description provided for @perAppTitle.
  ///
  /// In en, this message translates to:
  /// **'Per-app proxy'**
  String get perAppTitle;

  /// No description provided for @perAppSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose which apps go through the VPN tunnel.'**
  String get perAppSubtitle;

  /// No description provided for @perAppAllowMode.
  ///
  /// In en, this message translates to:
  /// **'Only selected apps use the VPN'**
  String get perAppAllowMode;

  /// No description provided for @perAppDenyMode.
  ///
  /// In en, this message translates to:
  /// **'Selected apps bypass the VPN'**
  String get perAppDenyMode;

  /// No description provided for @perAppSelectApps.
  ///
  /// In en, this message translates to:
  /// **'Select apps'**
  String get perAppSelectApps;

  /// No description provided for @perAppSearch.
  ///
  /// In en, this message translates to:
  /// **'Search apps'**
  String get perAppSearch;

  /// No description provided for @perAppSelectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String perAppSelectedCount(int count);

  /// No description provided for @perAppNoApps.
  ///
  /// In en, this message translates to:
  /// **'No apps found'**
  String get perAppNoApps;

  /// No description provided for @perAppClearAll.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get perAppClearAll;

  /// No description provided for @perAppAppliesNextConnect.
  ///
  /// In en, this message translates to:
  /// **'Applies on the next connection.'**
  String get perAppAppliesNextConnect;

  /// No description provided for @ping.
  ///
  /// In en, this message translates to:
  /// **'Ping'**
  String get ping;

  /// No description provided for @ms.
  ///
  /// In en, this message translates to:
  /// **'ms'**
  String get ms;

  /// No description provided for @accountInfo.
  ///
  /// In en, this message translates to:
  /// **'Account Information'**
  String get accountInfo;

  /// No description provided for @tapToConnect.
  ///
  /// In en, this message translates to:
  /// **'Tap to connect'**
  String get tapToConnect;

  /// No description provided for @tapToDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Tap to disconnect'**
  String get tapToDisconnect;

  /// No description provided for @activeConfigLabel.
  ///
  /// In en, this message translates to:
  /// **'Active Server'**
  String get activeConfigLabel;

  /// No description provided for @subscriptionsSection.
  ///
  /// In en, this message translates to:
  /// **'Subscriptions'**
  String get subscriptionsSection;

  /// No description provided for @localConfigsSection.
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get localConfigsSection;

  /// No description provided for @subscriptionRemaining.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, =0{Expires today} =1{1 day remaining} other{{days} days remaining}}'**
  String subscriptionRemaining(int days);

  /// No description provided for @subscriptionExpires.
  ///
  /// In en, this message translates to:
  /// **'Expires {date}'**
  String subscriptionExpires(String date);

  /// No description provided for @subscriptionUpdateInterval.
  ///
  /// In en, this message translates to:
  /// **'Suggested refresh interval: {hours, plural, =1{1 hour} other{{hours} hours}}'**
  String subscriptionUpdateInterval(int hours);

  /// No description provided for @subscriptionLastRefreshed.
  ///
  /// In en, this message translates to:
  /// **'Last refreshed {date}'**
  String subscriptionLastRefreshed(String date);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'fa'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'fa':
      return AppLocalizationsFa();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
