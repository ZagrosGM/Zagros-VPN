#include "include/tunnel_interface/zagros_tunnel_plugin.h"

#include <gio/gio.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "include/tunnel_interface/tunnel_api.g.h"
#include "network_manager_settings.h"
#include "wireguard_config.h"

namespace {

constexpr char kNetworkManagerName[] = "org.freedesktop.NetworkManager";
constexpr char kNetworkManagerPath[] = "/org/freedesktop/NetworkManager";
constexpr char kNetworkManagerInterface[] = "org.freedesktop.NetworkManager";
constexpr char kInterfaceName[] = "zgvpn0";
constexpr char kConnectionProfileId[] = "Zagros Runtime WireGuard";
constexpr char kConnectionProfileUuid[] = "7fb51e72-8e80-4e3a-9d14-91db73c6d85f";
constexpr char kSettingsPath[] = "/org/freedesktop/NetworkManager/Settings";
constexpr char kSettingsInterface[] = "org.freedesktop.NetworkManager.Settings";
constexpr size_t kMaximumConfigBytes = 256 * 1024;

bool SafeIdentifier(const char* value) {
  if (value == nullptr) return false;
  const size_t length = std::strlen(value);
  if (length == 0 || length > 128 || !g_ascii_isalnum(value[0])) return false;
  for (size_t i = 1; i < length; ++i) {
    const char c = value[i];
    if (!(g_ascii_isalnum(c) || c == '.' || c == '_' || c == ':' || c == '-')) return false;
  }
  return true;
}

bool SafeReason(const char* value) {
  if (value == nullptr) return false;
  const size_t length = std::strlen(value);
  if (length == 0 || length > 64) return false;
  for (size_t i = 0; i < length; ++i) {
    if (!(g_ascii_islower(value[i]) || g_ascii_isdigit(value[i]) || value[i] == '_')) return false;
  }
  return true;
}

GDBusConnection* OpenPrivateSystemBus() {
  g_autoptr(GError) error = nullptr;
  g_autofree gchar* address = g_dbus_address_get_for_bus_sync(
      G_BUS_TYPE_SYSTEM, nullptr, &error);
  if (address == nullptr) return nullptr;
  return g_dbus_connection_new_for_address_sync(
      address,
      static_cast<GDBusConnectionFlags>(
          G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
          G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
      nullptr, nullptr, &error);
}

void ClosePrivateBus(GDBusConnection* bus) {
  if (bus == nullptr || g_dbus_connection_is_closed(bus)) return;
  g_dbus_connection_close(bus, nullptr, nullptr, nullptr);
}

gchar* FindWireGuardTool() {
  for (const char* candidate : {"/usr/bin/wg", "/bin/wg"}) {
    if (g_file_test(candidate, G_FILE_TEST_IS_REGULAR) &&
        g_file_test(candidate, G_FILE_TEST_IS_EXECUTABLE)) {
      return g_strdup(candidate);
    }
  }
  return nullptr;
}

bool NetworkManagerAvailable() {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GDBusConnection) bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nullptr, &error);
  if (bus == nullptr) return false;
  g_autoptr(GVariant) result = g_dbus_connection_call_sync(
      bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "NameHasOwner", g_variant_new("(s)", kNetworkManagerName),
      G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, 1500, nullptr, &error);
  if (result == nullptr) return false;
  gboolean owned = FALSE;
  g_variant_get(result, "(b)", &owned);
  return owned;
}

bool SettingsProfileIsActive(GDBusConnection* bus, const char* settings_path) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) result = g_dbus_connection_call_sync(
      bus, kNetworkManagerName, kNetworkManagerPath, "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", kNetworkManagerInterface, "ActiveConnections"),
      G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 1500, nullptr, &error);
  if (result == nullptr) return true;
  g_autoptr(GVariant) boxed = nullptr;
  g_variant_get(result, "(@v)", &boxed);
  g_autoptr(GVariant) active_paths = g_variant_get_variant(boxed);
  if (!g_variant_is_of_type(active_paths, G_VARIANT_TYPE("ao"))) return true;
  GVariantIter iterator;
  g_variant_iter_init(&iterator, active_paths);
  const gchar* active_path = nullptr;
  while (g_variant_iter_next(&iterator, "&o", &active_path)) {
    error = nullptr;
    g_autoptr(GVariant) connection_result = g_dbus_connection_call_sync(
        bus, kNetworkManagerName, active_path, "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", "org.freedesktop.NetworkManager.Connection.Active",
                      "Connection"),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 1500, nullptr, &error);
    if (connection_result == nullptr) return true;
    g_autoptr(GVariant) connection_boxed = nullptr;
    g_variant_get(connection_result, "(@v)", &connection_boxed);
    g_autoptr(GVariant) connection_path = g_variant_get_variant(connection_boxed);
    if (g_variant_is_of_type(connection_path, G_VARIANT_TYPE_OBJECT_PATH) &&
        g_strcmp0(g_variant_get_string(connection_path, nullptr), settings_path) == 0) {
      return true;
    }
  }
  return false;
}

bool CleanupOwnedNetworkManagerProfile() {
  g_autoptr(GDBusConnection) bus = OpenPrivateSystemBus();
  if (bus == nullptr) return false;
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) result = g_dbus_connection_call_sync(
      bus, kNetworkManagerName, kSettingsPath, kSettingsInterface, "ListConnections",
      nullptr, G_VARIANT_TYPE("(ao)"), G_DBUS_CALL_FLAGS_NONE, 3000, nullptr, &error);
  if (result == nullptr) {
    g_dbus_connection_close_sync(bus, nullptr, nullptr);
    return false;
  }
  g_autoptr(GVariant) paths = nullptr;
  g_variant_get(result, "(@ao)", &paths);
  GVariantIter iterator;
  g_variant_iter_init(&iterator, paths);
  const gchar* path = nullptr;
  while (g_variant_iter_next(&iterator, "&o", &path)) {
    error = nullptr;
    g_autoptr(GVariant) settings_result = g_dbus_connection_call_sync(
        bus, kNetworkManagerName, path,
        "org.freedesktop.NetworkManager.Settings.Connection", "GetSettings", nullptr,
        G_VARIANT_TYPE("(a{sa{sv}})"), G_DBUS_CALL_FLAGS_NONE, 3000, nullptr, &error);
    if (settings_result == nullptr) {
      g_dbus_connection_close_sync(bus, nullptr, nullptr);
      return false;
    }
    g_autoptr(GVariant) settings = nullptr;
    g_variant_get(settings_result, "(@a{sa{sv}})", &settings);
    g_autoptr(GVariant) connection =
        g_variant_lookup_value(settings, "connection", G_VARIANT_TYPE("a{sv}"));
    if (connection == nullptr) continue;
    const gchar* id = nullptr;
    const gchar* uuid = nullptr;
    const gchar* type = nullptr;
    const gchar* interface_name = nullptr;
    const bool has_id = g_variant_lookup(connection, "id", "&s", &id);
    const bool has_uuid = g_variant_lookup(connection, "uuid", "&s", &uuid);
    const bool has_type = g_variant_lookup(connection, "type", "&s", &type);
    const bool has_interface =
        g_variant_lookup(connection, "interface-name", "&s", &interface_name);
    const bool claims_reserved_identity =
        (has_id && g_strcmp0(id, kConnectionProfileId) == 0) ||
        (has_uuid && g_strcmp0(uuid, kConnectionProfileUuid) == 0) ||
        (has_interface && g_strcmp0(interface_name, kInterfaceName) == 0);
    const bool owned =
        has_id && has_uuid && has_type && has_interface &&
        g_strcmp0(id, kConnectionProfileId) == 0 &&
        g_strcmp0(uuid, kConnectionProfileUuid) == 0 &&
        g_strcmp0(type, "wireguard") == 0 &&
        g_strcmp0(interface_name, kInterfaceName) == 0;
    if (!owned) {
      if (claims_reserved_identity) {
        g_dbus_connection_close_sync(bus, nullptr, nullptr);
        return false;
      }
      continue;
    }
    bool active = true;
    for (int attempt = 0; attempt < 8 && active; ++attempt) {
      active = SettingsProfileIsActive(bus, path);
      if (active) std::this_thread::sleep_for(std::chrono::milliseconds(250));
    }
    if (active) {
      g_dbus_connection_close_sync(bus, nullptr, nullptr);
      return false;
    }
    error = nullptr;
    g_autoptr(GVariant) deleted = g_dbus_connection_call_sync(
        bus, kNetworkManagerName, path,
        "org.freedesktop.NetworkManager.Settings.Connection", "Delete", nullptr, nullptr,
        G_DBUS_CALL_FLAGS_NONE, 5000, nullptr, &error);
    if (deleted == nullptr) {
      g_dbus_connection_close_sync(bus, nullptr, nullptr);
      return false;
    }
  }
  const bool closed = g_dbus_connection_close_sync(bus, nullptr, nullptr);
  return closed;
}

bool QueryActiveState(GDBusConnection* bus, const char* path, uint32_t* state) {
  if (bus == nullptr || path == nullptr) return false;
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) result = g_dbus_connection_call_sync(
      bus, kNetworkManagerName, path, "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", "org.freedesktop.NetworkManager.Connection.Active", "State"),
      G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 1500, nullptr, &error);
  if (result == nullptr) return false;
  g_autoptr(GVariant) value = nullptr;
  g_variant_get(result, "(@v)", &value);
  g_autoptr(GVariant) inner = g_variant_get_variant(value);
  if (!g_variant_is_of_type(inner, G_VARIANT_TYPE_UINT32)) return false;
  *state = g_variant_get_uint32(inner);
  return true;
}

bool QueryWireGuard(gint64 handshake_not_before,
                    bool* handshake,
                    int64_t* uplink,
                    int64_t* downlink) {
  *handshake = false;
  *uplink = 0;
  *downlink = 0;
  g_autofree gchar* wg = FindWireGuardTool();
  if (wg == nullptr) return false;
  gchar* handshake_output = nullptr;
  gchar* transfer_output = nullptr;
  gint exit_status = 0;
  g_autoptr(GError) error = nullptr;
  gchar* handshake_args[] = {wg, const_cast<gchar*>("show"), const_cast<gchar*>(kInterfaceName),
                             const_cast<gchar*>("latest-handshakes"), nullptr};
  if (!g_spawn_sync(nullptr, handshake_args, nullptr, G_SPAWN_DEFAULT, nullptr, nullptr,
                    &handshake_output, nullptr, &exit_status, &error) ||
      !g_spawn_check_wait_status(exit_status, nullptr)) {
    g_free(handshake_output);
    return false;
  }
  g_auto(GStrv) lines = g_strsplit(handshake_output, "\n", -1);
  g_free(handshake_output);
  const gint64 now = g_get_real_time() / G_USEC_PER_SEC;
  for (gchar** line = lines; line != nullptr && *line != nullptr; ++line) {
    gchar* tab = std::strrchr(*line, '\t');
    if (tab == nullptr) continue;
    gchar* end = nullptr;
    const gint64 timestamp = g_ascii_strtoll(tab + 1, &end, 10);
    if (end != tab + 1 && timestamp >= handshake_not_before &&
        timestamp <= now + 300) {
      *handshake = true;
    }
  }
  error = nullptr;
  gchar* transfer_args[] = {wg, const_cast<gchar*>("show"), const_cast<gchar*>(kInterfaceName),
                            const_cast<gchar*>("transfer"), nullptr};
  if (!g_spawn_sync(nullptr, transfer_args, nullptr, G_SPAWN_DEFAULT, nullptr, nullptr,
                    &transfer_output, nullptr, &exit_status, &error) ||
      !g_spawn_check_wait_status(exit_status, nullptr)) {
    g_free(transfer_output);
    return true;
  }
  g_auto(GStrv) transfer_lines = g_strsplit(transfer_output, "\n", -1);
  g_free(transfer_output);
  for (gchar** line = transfer_lines; line != nullptr && *line != nullptr; ++line) {
    g_auto(GStrv) fields = g_strsplit(*line, "\t", 3);
    if (g_strv_length(fields) != 3) continue;
    gchar* rx_end = nullptr;
    gchar* tx_end = nullptr;
    const gint64 rx = g_ascii_strtoll(fields[1], &rx_end, 10);
    const gint64 tx = g_ascii_strtoll(fields[2], &tx_end, 10);
    if (rx_end != fields[1] && *rx_end == '\0' && tx_end != fields[2] &&
        *tx_end == '\0' && rx >= 0 && tx >= 0 &&
        rx <= std::numeric_limits<gint64>::max() - *downlink &&
        tx <= std::numeric_limits<gint64>::max() - *uplink) {
      *downlink += rx;
      *uplink += tx;
    }
  }
  return true;
}

}  // namespace

struct _ZagrosTunnelPlugin {
  GObject parent_instance;
  FlBinaryMessenger* messenger;
  zagros_tunnelNativeTunnelFlutterApi* flutter_api;
  GDBusConnection* system_bus;
  GMutex mutex;
  gint64 sequence;
  zagros_tunnelNativeTunnelState state;
  gint64 uplink;
  gint64 downlink;
  gint64 connected_at;
  gchar* connection_id;
  gchar* active_path;
  gchar* settings_path;
  guint monitor_source;
  gboolean busy;
  gboolean monitor_busy;
  gboolean capability_checked;
  gboolean wireguard_available;
  guint monitor_failures;
  gint64 handshake_not_before;
  gint64 handshake_deadline_monotonic;
};

G_DEFINE_TYPE(ZagrosTunnelPlugin, zagros_tunnel_plugin, G_TYPE_OBJECT)

static zagros_tunnelNativeTunnelStatus* make_status(ZagrosTunnelPlugin* self,
                                                     gboolean increment,
                                                     const char* failure_code = nullptr) {
  g_mutex_lock(&self->mutex);
  if (increment) ++self->sequence;
  gint64* connected_at = failure_code == nullptr &&
                                 self->state == TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_CONNECTED &&
                                 self->connected_at > 0
                             ? &self->connected_at
                             : nullptr;
  auto* status = zagros_tunnel_native_tunnel_status_new(
      failure_code == nullptr ? self->state : TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_FAILED,
      self->sequence, self->uplink, self->downlink, self->connection_id,
      self->connection_id == nullptr ? nullptr : "wireguard", connected_at, failure_code,
      failure_code == nullptr ? nullptr : "The Linux tunnel failed safely.");
  g_mutex_unlock(&self->mutex);
  return status;
}

static void publish_status(ZagrosTunnelPlugin* self,
                           zagros_tunnelNativeTunnelState state,
                           const char* failure_code = nullptr) {
  g_mutex_lock(&self->mutex);
  self->state = state;
  ++self->sequence;
  if (state == TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_CONNECTED && self->connected_at == 0)
    self->connected_at = g_get_real_time() / 1000;
  if (state == TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_DISCONNECTED) {
    self->uplink = 0;
    self->downlink = 0;
    self->connected_at = 0;
  }
  gint64* connected_at = failure_code == nullptr &&
                                 state == TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_CONNECTED &&
                                 self->connected_at > 0
                             ? &self->connected_at
                             : nullptr;
  auto* status = zagros_tunnel_native_tunnel_status_new(
      failure_code == nullptr ? state : TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_FAILED,
      self->sequence, self->uplink, self->downlink, self->connection_id,
      self->connection_id == nullptr ? nullptr : "wireguard", connected_at, failure_code,
      failure_code == nullptr ? nullptr : "The Linux tunnel failed safely.");
  g_mutex_unlock(&self->mutex);
  zagros_tunnel_native_tunnel_flutter_api_on_status_changed(
      self->flutter_api, status, nullptr, nullptr, nullptr);
  g_object_unref(status);
}

bool TeardownConnection(GDBusConnection* bus,
                        const std::string& active_path,
                        const std::string& settings_path) {
  if (bus == nullptr) return false;
  bool success = true;
  g_autoptr(GError) error = nullptr;
  if (!active_path.empty()) {
    g_autoptr(GVariant) result = g_dbus_connection_call_sync(
        bus, kNetworkManagerName, kNetworkManagerPath, kNetworkManagerInterface,
        "DeactivateConnection", g_variant_new("(o)", active_path.c_str()), nullptr,
        G_DBUS_CALL_FLAGS_NONE, 15000, nullptr, &error);
    (void)result;
    bool deactivated = false;
    for (int attempt = 0; attempt < 40; ++attempt) {
      uint32_t state = 0;
      if (!QueryActiveState(bus, active_path.c_str(), &state) || state == 4) {
        deactivated = true;
        break;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(250));
    }
    success = deactivated;
  }
  if (!settings_path.empty()) {
    error = nullptr;
    g_autoptr(GVariant) result = g_dbus_connection_call_sync(
        bus, kNetworkManagerName, settings_path.c_str(),
        "org.freedesktop.NetworkManager.Settings.Connection", "Delete", nullptr, nullptr,
        G_DBUS_CALL_FLAGS_NONE, 5000, nullptr, &error);
    success = result != nullptr && success;
  }
  g_dbus_connection_close_sync(bus, nullptr, nullptr);
  return success;
}

struct AutomaticTeardownWork {
  ZagrosTunnelPlugin* plugin;
  GDBusConnection* system_bus;
  std::string active_path;
  std::string settings_path;
  std::string failure;
  bool success = false;
};

static gboolean complete_automatic_teardown(gpointer user_data) {
  std::unique_ptr<AutomaticTeardownWork> work(
      static_cast<AutomaticTeardownWork*>(user_data));
  auto* self = work->plugin;
  g_mutex_lock(&self->mutex);
  const bool same_connection = self->active_path != nullptr &&
                               work->active_path == self->active_path;
  if (same_connection) {
    if (work->success) {
      g_clear_pointer(&self->active_path, g_free);
      g_clear_pointer(&self->settings_path, g_free);
      g_clear_object(&self->system_bus);
    } else {
      g_clear_object(&self->system_bus);
      self->system_bus = work->system_bus;
      work->system_bus = nullptr;
    }
    self->busy = FALSE;
    self->monitor_busy = FALSE;
    self->state = TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_FAILED;
  }
  g_mutex_unlock(&self->mutex);
  if (same_connection) {
    publish_status(self, TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_FAILED,
                   work->success ? work->failure.c_str() : "teardown_failed");
  }
  g_clear_object(&work->system_bus);
  g_object_unref(self);
  return G_SOURCE_REMOVE;
}

static void run_automatic_teardown(AutomaticTeardownWork* work) {
  work->success = TeardownConnection(
      work->system_bus, work->active_path, work->settings_path);
  if (!work->success) {
    g_clear_object(&work->system_bus);
    work->system_bus = OpenPrivateSystemBus();
  }
  g_main_context_invoke(nullptr, complete_automatic_teardown, work);
}

static void start_automatic_teardown(ZagrosTunnelPlugin* self, const char* failure) {
  g_mutex_lock(&self->mutex);
  if (self->busy || self->active_path == nullptr || self->system_bus == nullptr) {
    g_mutex_unlock(&self->mutex);
    return;
  }
  self->busy = TRUE;
  if (self->monitor_source != 0) {
    g_source_remove(self->monitor_source);
    self->monitor_source = 0;
  }
  auto* work = new AutomaticTeardownWork{
      ZAGROS_TUNNEL_PLUGIN(g_object_ref(self)),
      G_DBUS_CONNECTION(g_object_ref(self->system_bus)),
      self->active_path,
      self->settings_path == nullptr ? "" : self->settings_path,
      failure};
  g_mutex_unlock(&self->mutex);
  std::thread(run_automatic_teardown, work).detach();
}

struct MonitorWork {
  ZagrosTunnelPlugin* plugin;
  GDBusConnection* system_bus;
  std::string active_path;
  gint64 handshake_not_before;
  bool state_known = false;
  uint32_t active_state = 0;
  bool wireguard_known = false;
  bool handshake = false;
  int64_t uplink = 0;
  int64_t downlink = 0;
};

static gboolean complete_monitor(gpointer user_data) {
  std::unique_ptr<MonitorWork> work(static_cast<MonitorWork*>(user_data));
  auto* self = work->plugin;
  bool same_connection = false;
  bool connected_transition = false;
  bool publish_accounting = false;
  bool externally_disconnected = false;
  bool fail_status = false;
  bool fail_handshake = false;
  g_mutex_lock(&self->mutex);
  same_connection = self->active_path != nullptr && work->active_path == self->active_path;
  if (same_connection) {
    self->monitor_busy = FALSE;
    if (!work->state_known) {
      ++self->monitor_failures;
    } else if (work->active_state == 4) {
      externally_disconnected = true;
    } else if (work->active_state == 2 && work->wireguard_known) {
      self->monitor_failures = 0;
      publish_accounting = self->uplink != work->uplink || self->downlink != work->downlink;
      self->uplink = work->uplink;
      self->downlink = work->downlink;
      connected_transition = work->handshake &&
          self->state != TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_CONNECTED;
      fail_handshake = !work->handshake &&
          self->state != TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_CONNECTED &&
          g_get_monotonic_time() >= self->handshake_deadline_monotonic;
    } else if (work->active_state == 2) {
      ++self->monitor_failures;
    }
    fail_status = self->monitor_failures >= 3;
  }
  g_mutex_unlock(&self->mutex);

  if (same_connection && externally_disconnected) {
    start_automatic_teardown(self, "transport_lost");
  } else if (same_connection && connected_transition) {
    publish_status(self, TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_CONNECTED);
  } else if (same_connection && publish_accounting && work->handshake) {
    publish_status(self, TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_CONNECTED);
  }
  if (same_connection && fail_handshake) {
    start_automatic_teardown(self, "handshake_timeout");
  } else if (same_connection && fail_status) {
    start_automatic_teardown(self, "status_failed");
  }
  g_clear_object(&work->system_bus);
  g_object_unref(self);
  return G_SOURCE_REMOVE;
}

static void run_monitor(MonitorWork* work) {
  work->state_known = QueryActiveState(
      work->system_bus, work->active_path.c_str(), &work->active_state);
  if (work->state_known && work->active_state == 2) {
    work->wireguard_known = QueryWireGuard(
        work->handshake_not_before, &work->handshake, &work->uplink,
        &work->downlink);
  }
  g_main_context_invoke(nullptr, complete_monitor, work);
}

static gboolean monitor_tunnel(gpointer user_data) {
  auto* self = ZAGROS_TUNNEL_PLUGIN(user_data);
  g_mutex_lock(&self->mutex);
  if (self->monitor_busy || self->busy || self->active_path == nullptr ||
      self->system_bus == nullptr) {
    g_mutex_unlock(&self->mutex);
    return G_SOURCE_CONTINUE;
  }
  self->monitor_busy = TRUE;
  auto* work = new MonitorWork{
      ZAGROS_TUNNEL_PLUGIN(g_object_ref(self)),
      G_DBUS_CONNECTION(g_object_ref(self->system_bus)),
      self->active_path,
      self->handshake_not_before};
  g_mutex_unlock(&self->mutex);
  std::thread(run_monitor, work).detach();
  return G_SOURCE_CONTINUE;
}

struct ConnectWork {
  ZagrosTunnelPlugin* plugin;
  zagros_tunnelNativeTunnelHostApiResponseHandle* response;
  GDBusConnection* system_bus = nullptr;
  zagros_tunnel_linux::WireGuardConfig config;
  std::string connection_id;
  std::string active_path;
  std::string settings_path;
  std::string failure;
  gint64 handshake_not_before = 0;
  bool activated = false;
  bool cleanup_required = false;
};

static gboolean complete_connect(gpointer user_data) {
  std::unique_ptr<ConnectWork> work(static_cast<ConnectWork*>(user_data));
  auto* self = work->plugin;
  zagros_tunnel_linux::SecureClear(&work->config);
  g_mutex_lock(&self->mutex);
  self->busy = FALSE;
  if (work->activated || work->cleanup_required) {
    g_free(self->connection_id);
    g_free(self->active_path);
    g_free(self->settings_path);
    self->connection_id = g_strdup(work->connection_id.c_str());
    self->active_path = g_strdup(work->active_path.c_str());
    self->settings_path = g_strdup(work->settings_path.c_str());
    g_clear_object(&self->system_bus);
    self->system_bus = work->system_bus;
    work->system_bus = nullptr;
    self->state = work->activated ? TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_CONNECTING
                                  : TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_FAILED;
    self->uplink = 0;
    self->downlink = 0;
    self->connected_at = 0;
    self->monitor_failures = 0;
    self->handshake_not_before = work->handshake_not_before;
    self->handshake_deadline_monotonic =
        g_get_monotonic_time() + 30 * G_USEC_PER_SEC;
  }
  g_mutex_unlock(&self->mutex);
  if (work->activated) {
    publish_status(self, TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_CONNECTING);
    if (self->monitor_source == 0)
      self->monitor_source = g_timeout_add_seconds_full(
          G_PRIORITY_DEFAULT, 1, monitor_tunnel, self, nullptr);
    auto* status = make_status(self, FALSE);
    zagros_tunnel_native_tunnel_host_api_respond_connect(work->response, status);
    g_object_unref(status);
  } else {
    publish_status(self, TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_FAILED,
                   work->failure.empty() ? "engine_failed" : work->failure.c_str());
    auto* status = make_status(self, FALSE,
                               work->failure.empty() ? "engine_failed" : work->failure.c_str());
    zagros_tunnel_native_tunnel_host_api_respond_connect(work->response, status);
    g_object_unref(status);
  }
  g_clear_object(&work->system_bus);
  g_object_unref(work->response);
  g_object_unref(self);
  return G_SOURCE_REMOVE;
}

static void run_connect(ConnectWork* work) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GDBusConnection) bus = OpenPrivateSystemBus();
  bool valid = false;
  g_autoptr(GVariant) settings = zagros_tunnel_linux::BuildNetworkManagerSettings(
      work->config, kConnectionProfileId, kConnectionProfileUuid,
      kInterfaceName, &valid);
  // The immutable D-Bus settings value must live through the activation call,
  // but our mutable parser-owned copies are no longer needed after construction.
  zagros_tunnel_linux::SecureClear(&work->config);
  if (bus == nullptr || !valid) {
    work->failure = valid ? "backend_unavailable" : "invalid_config";
    ClosePrivateBus(bus);
    g_main_context_invoke(nullptr, complete_connect, work);
    return;
  }
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&options, "{sv}", "persist", g_variant_new_string("volatile"));
  g_variant_builder_add(&options, "{sv}", "bind-activation", g_variant_new_string("dbus-client"));
  g_autoptr(GVariant) result = g_dbus_connection_call_sync(
      bus, kNetworkManagerName, kNetworkManagerPath, kNetworkManagerInterface,
      "AddAndActivateConnection2",
      g_variant_new("(@a{sa{sv}}oo@a{sv})", g_steal_pointer(&settings), "/", "/",
                    g_variant_builder_end(&options)),
      G_VARIANT_TYPE("(ooa{sv})"), G_DBUS_CALL_FLAGS_NONE, 30000, nullptr, &error);
  if (result == nullptr) {
    work->failure = "activation_failed";
    ClosePrivateBus(bus);
    g_main_context_invoke(nullptr, complete_connect, work);
    return;
  }
  const gchar* settings_path = nullptr;
  const gchar* active_path = nullptr;
  g_autoptr(GVariant) ignored = nullptr;
  g_variant_get(result, "(&o&o@a{sv})", &settings_path, &active_path, &ignored);
  work->settings_path = settings_path;
  work->active_path = active_path;
  work->system_bus = G_DBUS_CONNECTION(g_object_ref(bus));
  for (int attempt = 0; attempt < 80; ++attempt) {
    uint32_t state = 0;
    if (QueryActiveState(bus, active_path, &state)) {
      if (state == 2) {
        work->activated = true;
        break;
      }
      if (state == 4) break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
  }
  if (!work->activated) {
    work->failure = "activation_failed";
    if (!TeardownConnection(bus, work->active_path, work->settings_path)) {
      work->cleanup_required = true;
      work->failure = "cleanup_failed";
      g_clear_object(&work->system_bus);
      work->system_bus = OpenPrivateSystemBus();
      if (work->system_bus == nullptr) work->failure = "teardown_failed";
    }
  }
  g_main_context_invoke(nullptr, complete_connect, work);
}

struct CapabilityWork {
  ZagrosTunnelPlugin* plugin;
  bool available = false;
};

static gboolean complete_capability_check(gpointer user_data) {
  std::unique_ptr<CapabilityWork> work(static_cast<CapabilityWork*>(user_data));
  g_mutex_lock(&work->plugin->mutex);
  work->plugin->capability_checked = TRUE;
  work->plugin->wireguard_available = work->available;
  g_mutex_unlock(&work->plugin->mutex);
  g_object_unref(work->plugin);
  return G_SOURCE_REMOVE;
}

static void run_capability_check(CapabilityWork* work) {
  g_autofree gchar* wg_path = FindWireGuardTool();
  work->available = wg_path != nullptr && NetworkManagerAvailable() &&
                    CleanupOwnedNetworkManagerProfile();
  g_main_context_invoke(nullptr, complete_capability_check, work);
}

static zagros_tunnelNativeTunnelHostApiGetCapabilitiesResponse* handle_capabilities(
    gpointer user_data) {
  auto* self = ZAGROS_TUNNEL_PLUGIN(user_data);
  g_mutex_lock(&self->mutex);
  const bool checked = self->capability_checked;
  const bool available = self->wireguard_available;
  g_mutex_unlock(&self->mutex);
  g_autoptr(FlValue) protocols = fl_value_new_list();
  if (available) fl_value_append_take(protocols, fl_value_new_string("wireguard"));
  g_autoptr(FlValue) reasons = fl_value_new_map();
  auto reason = [reasons](const char* protocol, const char* message) {
    fl_value_set_string_take(reasons, protocol, fl_value_new_string(message));
  };
  if (!checked)
    reason("wireguard", "Linux WireGuard capability discovery is still in progress.");
  else if (!available)
    reason("wireguard", "NetworkManager WireGuard and wg status support are unavailable.");
  reason("openvpn", "A reviewed OpenVPN backend is not packaged.");
  reason("ovpn", "A reviewed OpenVPN backend is not packaged.");
  reason("xray", "A reviewed Xray backend is not packaged.");
  reason("sing-box", "A reviewed sing-box backend is not packaged.");
  reason("vless", "No reviewed Xray or sing-box VLESS backend is packaged.");
  reason("vmess", "No reviewed Xray or sing-box VMess backend is packaged.");
  reason("trojan", "No reviewed Xray or sing-box Trojan backend is packaged.");
  reason("shadowsocks", "No reviewed Xray or sing-box Shadowsocks backend is packaged.");
  reason("hysteria2", "No reviewed sing-box Hysteria2 backend is packaged.");
  reason("tuic", "No reviewed sing-box TUIC backend is packaged.");
  reason("anytls", "No reviewed sing-box AnyTLS backend is packaged.");
  reason("socks", "No reviewed SOCKS-to-device-tunnel backend is packaged.");
  reason("http", "No reviewed HTTP-proxy-to-device-tunnel backend is packaged.");
  reason("https", "No reviewed HTTPS-proxy-to-device-tunnel backend is packaged.");
  reason("softether", "A reviewed native SoftEther backend is not packaged.");
  reason("ssh", "A reviewed device-tunnel SSH backend is not packaged.");
  reason("ikev2", "A reviewed Linux IKEv2 backend is not packaged.");
  reason("pptp", "Legacy PPTP is not enabled by this secure adapter.");
  reason("l2tp", "A reviewed L2TP/IPsec backend is not packaged.");
  reason("l2tp+ipsec", "A reviewed L2TP/IPsec backend is not packaged.");
  auto* capabilities = zagros_tunnel_native_tunnel_capabilities_new(
      "linux", protocols, available, available, reasons);
  auto* response =
      zagros_tunnel_native_tunnel_host_api_get_capabilities_response_new(capabilities);
  g_object_unref(capabilities);
  return response;
}

static zagros_tunnelNativeTunnelHostApiGetStatusResponse* handle_status(gpointer user_data) {
  auto* self = ZAGROS_TUNNEL_PLUGIN(user_data);
  // The one-second background monitor owns blocking D-Bus and wg queries. This
  // platform-thread handler returns its latest authoritative observation.
  auto* status = make_status(self, TRUE);
  auto* response = zagros_tunnel_native_tunnel_host_api_get_status_response_new(status);
  g_object_unref(status);
  return response;
}

static void handle_connect(zagros_tunnelNativeTunnelRequest* request,
                           zagros_tunnelNativeTunnelHostApiResponseHandle* response,
                           gpointer user_data) {
  auto* self = ZAGROS_TUNNEL_PLUGIN(user_data);
  size_t payload_length = 0;
  const uint8_t* payload =
      zagros_tunnel_native_tunnel_request_get_config_payload(request, &payload_length);
  const char* protocol = zagros_tunnel_native_tunnel_request_get_protocol(request);
  const char* engine = zagros_tunnel_native_tunnel_request_get_engine(request);
  const char* request_id = zagros_tunnel_native_tunnel_request_get_request_id(request);
  const char* connection_id = zagros_tunnel_native_tunnel_request_get_connection_id(request);
  auto fail_immediately = [response](const char* code) {
    zagros_tunnel_native_tunnel_host_api_respond_error_connect(
        response, code, "The Linux tunnel request was rejected safely.", nullptr);
  };
  if (protocol == nullptr || std::strcmp(protocol, "wireguard") != 0 ||
      engine == nullptr || std::strcmp(engine, "wireguard") != 0 ||
      !SafeIdentifier(request_id) || !SafeIdentifier(connection_id) || payload == nullptr ||
      payload_length == 0 || payload_length > kMaximumConfigBytes) {
    fail_immediately("invalid_request");
    return;
  }
  g_mutex_lock(&self->mutex);
  const bool unavailable = self->busy || self->active_path != nullptr;
  if (!unavailable) self->busy = TRUE;
  g_mutex_unlock(&self->mutex);
  if (unavailable) {
    fail_immediately("operation_in_progress");
    return;
  }
  auto* work = new ConnectWork{ZAGROS_TUNNEL_PLUGIN(g_object_ref(self)),
                               ZAGROS_TUNNEL_NATIVE_TUNNEL_HOST_API_RESPONSE_HANDLE(
                                   g_object_ref(response))};
  work->connection_id = connection_id;
  work->handshake_not_before = g_get_real_time() / G_USEC_PER_SEC;
  std::string safe_error;
  if (!zagros_tunnel_linux::ParseWireGuardConfig(
          payload, payload_length, &work->config, &safe_error)) {
    g_mutex_lock(&self->mutex);
    self->busy = FALSE;
    g_mutex_unlock(&self->mutex);
    zagros_tunnel_native_tunnel_host_api_respond_error_connect(
        work->response, "invalid_config",
        "The Linux tunnel configuration was rejected safely.",
        nullptr);
    zagros_tunnel_linux::SecureClear(&work->config);
    g_object_unref(work->response);
    g_object_unref(work->plugin);
    delete work;
    return;
  }
  publish_status(self, TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_PREPARING);
  std::thread(run_connect, work).detach();
}

struct DisconnectWork {
  ZagrosTunnelPlugin* plugin;
  zagros_tunnelNativeTunnelHostApiResponseHandle* response;
  GDBusConnection* system_bus;
  std::string active_path;
  std::string settings_path;
  bool success = true;
};

static gboolean complete_disconnect(gpointer user_data) {
  std::unique_ptr<DisconnectWork> work(static_cast<DisconnectWork*>(user_data));
  auto* self = work->plugin;
  g_mutex_lock(&self->mutex);
  self->busy = FALSE;
  if (work->success) {
    g_clear_pointer(&self->active_path, g_free);
    g_clear_pointer(&self->settings_path, g_free);
    g_clear_pointer(&self->connection_id, g_free);
    g_clear_object(&self->system_bus);
    self->state = TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_DISCONNECTED;
  } else {
    g_clear_object(&self->system_bus);
    self->system_bus = work->system_bus;
    work->system_bus = nullptr;
    self->state = TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_FAILED;
  }
  g_mutex_unlock(&self->mutex);
  if (work->success) {
    if (self->monitor_source != 0) {
      g_source_remove(self->monitor_source);
      self->monitor_source = 0;
    }
    publish_status(self, TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_DISCONNECTED);
  }
  auto* status = work->success ? make_status(self, FALSE)
                               : make_status(self, TRUE, "disconnect_failed");
  zagros_tunnel_native_tunnel_host_api_respond_disconnect(work->response, status);
  g_object_unref(status);
  g_clear_object(&work->system_bus);
  g_object_unref(work->response);
  g_object_unref(self);
  return G_SOURCE_REMOVE;
}

static void run_disconnect(DisconnectWork* work) {
  if (work->system_bus == nullptr || g_dbus_connection_is_closed(work->system_bus)) {
    g_clear_object(&work->system_bus);
    work->system_bus = OpenPrivateSystemBus();
  }
  work->success = TeardownConnection(
      work->system_bus, work->active_path, work->settings_path);
  if (!work->success) {
    g_clear_object(&work->system_bus);
    work->system_bus = OpenPrivateSystemBus();
  }
  g_main_context_invoke(nullptr, complete_disconnect, work);
}

static void handle_disconnect(const gchar* reason,
                              zagros_tunnelNativeTunnelHostApiResponseHandle* response,
                              gpointer user_data) {
  auto* self = ZAGROS_TUNNEL_PLUGIN(user_data);
  if (!SafeReason(reason)) {
    zagros_tunnel_native_tunnel_host_api_respond_error_disconnect(
        response, "invalid_disconnect_reason",
        "The Linux tunnel disconnect request was rejected safely.", nullptr);
    return;
  }
  g_mutex_lock(&self->mutex);
  if (self->busy) {
    g_mutex_unlock(&self->mutex);
    zagros_tunnel_native_tunnel_host_api_respond_error_disconnect(
        response, "operation_in_progress",
        "The Linux tunnel disconnect request was rejected safely.", nullptr);
    return;
  }
  if (self->active_path == nullptr) {
    g_clear_pointer(&self->connection_id, g_free);
    self->connected_at = 0;
    self->uplink = 0;
    self->downlink = 0;
    ClosePrivateBus(self->system_bus);
    g_clear_object(&self->system_bus);
    g_mutex_unlock(&self->mutex);
    publish_status(self, TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_DISCONNECTED);
    auto* status = make_status(self, FALSE);
    zagros_tunnel_native_tunnel_host_api_respond_disconnect(response, status);
    g_object_unref(status);
    return;
  }
  self->busy = TRUE;
  auto* work = new DisconnectWork{
      ZAGROS_TUNNEL_PLUGIN(g_object_ref(self)),
      ZAGROS_TUNNEL_NATIVE_TUNNEL_HOST_API_RESPONSE_HANDLE(g_object_ref(response)),
      self->system_bus == nullptr
          ? nullptr
          : G_DBUS_CONNECTION(g_object_ref(self->system_bus)),
      self->active_path,
      self->settings_path == nullptr ? "" : self->settings_path};
  g_mutex_unlock(&self->mutex);
  publish_status(self, TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_DISCONNECTING);
  std::thread(run_disconnect, work).detach();
}

static const zagros_tunnelNativeTunnelHostApiVTable kHostApiVTable = {
    handle_capabilities, handle_status, handle_connect, handle_disconnect};

static void zagros_tunnel_plugin_dispose(GObject* object) {
  auto* self = ZAGROS_TUNNEL_PLUGIN(object);
  if (self->monitor_source != 0) {
    g_source_remove(self->monitor_source);
    self->monitor_source = 0;
  }
  if (self->messenger != nullptr)
    zagros_tunnel_native_tunnel_host_api_clear_method_handlers(self->messenger, nullptr);
  g_clear_object(&self->flutter_api);
  g_clear_object(&self->messenger);
  ClosePrivateBus(self->system_bus);
  g_clear_object(&self->system_bus);
  g_clear_pointer(&self->connection_id, g_free);
  g_clear_pointer(&self->active_path, g_free);
  g_clear_pointer(&self->settings_path, g_free);
  G_OBJECT_CLASS(zagros_tunnel_plugin_parent_class)->dispose(object);
}

static void zagros_tunnel_plugin_finalize(GObject* object) {
  auto* self = ZAGROS_TUNNEL_PLUGIN(object);
  g_mutex_clear(&self->mutex);
  G_OBJECT_CLASS(zagros_tunnel_plugin_parent_class)->finalize(object);
}

static void zagros_tunnel_plugin_class_init(ZagrosTunnelPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = zagros_tunnel_plugin_dispose;
  G_OBJECT_CLASS(klass)->finalize = zagros_tunnel_plugin_finalize;
}

static void zagros_tunnel_plugin_init(ZagrosTunnelPlugin* self) {
  g_mutex_init(&self->mutex);
  self->state = TUNNEL_INTERFACE_NATIVE_TUNNEL_STATE_DISCONNECTED;
}

FLUTTER_PLUGIN_EXPORT void zagros_tunnel_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  auto* plugin = ZAGROS_TUNNEL_PLUGIN(
      g_object_new(zagros_tunnel_plugin_get_type(), nullptr));
  plugin->messenger = FL_BINARY_MESSENGER(
      g_object_ref(fl_plugin_registrar_get_messenger(registrar)));
  plugin->flutter_api =
      zagros_tunnel_native_tunnel_flutter_api_new(plugin->messenger, nullptr);
  zagros_tunnel_native_tunnel_host_api_set_method_handlers(
      plugin->messenger, nullptr, &kHostApiVTable, g_object_ref(plugin), g_object_unref);
  auto* capability_work = new CapabilityWork{
      ZAGROS_TUNNEL_PLUGIN(g_object_ref(plugin))};
  std::thread(run_capability_check, capability_work).detach();
  g_object_unref(plugin);
}
