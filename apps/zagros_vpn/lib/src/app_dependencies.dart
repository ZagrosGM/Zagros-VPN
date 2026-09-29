import 'package:tunnel_interface/tunnel_interface.dart';
import 'package:zagros_vpn_sdk/zagros_vpn_sdk.dart';

import 'account/white_label_service.dart';
import 'logs/diagnostic_logs_service.dart';
import 'platform/raw_config_actions.dart';
import 'settings/app_settings_controller.dart';
import 'storage/secure_storage.dart';

class AppDependencies {
  const AppDependencies({
    required this.secureStores,
    required this.tunnelAdapter,
    this.officialProfiles,
    this.rawConfigActions,
    this.whiteLabel,
    this.logsService,
    this.settingsController,
  });

  final ClientSecureStores secureStores;

  /// Present only when Official policy permits protected raw persistence.
  final OfficialProfileRepository? officialProfiles;

  /// Present only when Official policy permits explicit copy/export actions.
  final RawConfigActions? rawConfigActions;

  /// Present only when policy permits Application login and the service
  /// could be built over OS-protected storage. Null means the account
  /// destination must render an unavailable state, never a login form.
  final WhiteLabelService? whiteLabel;

  /// Production injects the one shared native adapter for both product modes.
  /// Nullable construction remains only for isolated fail-closed UI tests.
  final TunnelAdapter? tunnelAdapter;

  /// Live diagnostic logs buffer.
  final DiagnosticLogsService? logsService;

  /// Reactive settings controller (DNS, Locale).
  final AppSettingsController? settingsController;

  Future<void> dispose() async {
    officialProfiles?.close();
    await whiteLabel?.close();
    // The native tunnel adapter is intentionally NOT disposed here. This
    // dispose runs when the root widget tree tears down (e.g. the activity
    // is swiped from recents), and disposing the adapter issues
    // disconnect('adapter_disposed') on the native side — killing a live VPN
    // even though the foreground service must keep it running. Explicit
    // disconnect (UI power button / logout) remains the only teardown path.
    logsService?.dispose();
    settingsController?.dispose();
  }
}
