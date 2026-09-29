#ifndef ZAGROS_TUNNEL_NETWORK_MANAGER_SETTINGS_H_
#define ZAGROS_TUNNEL_NETWORK_MANAGER_SETTINGS_H_

#include <gio/gio.h>

#include "wireguard_config.h"

namespace zagros_tunnel_linux {

// Returns a full a{sa{sv}} NetworkManager settings dictionary with one owned
// reference. The dictionary contains runtime secrets and must never be logged.
GVariant* BuildNetworkManagerSettings(const WireGuardConfig& config,
                                      const char* profile_id,
                                      const char* profile_uuid,
                                      const char* interface_name,
                                      bool* valid);

}  // namespace zagros_tunnel_linux

#endif  // ZAGROS_TUNNEL_NETWORK_MANAGER_SETTINGS_H_
