#include "network_manager_settings.h"

#include <cstdlib>
#include <string>
#include <vector>

namespace zagros_tunnel_linux {
namespace {

void AddSetting(GVariantBuilder* outer, const char* name, GVariantBuilder* inner) {
  g_variant_builder_add(outer, "{s@a{sv}}", name, g_variant_builder_end(inner));
}

bool SplitCidr(const std::string& cidr, std::string* address, uint32_t* prefix) {
  const size_t slash = cidr.rfind('/');
  if (slash == std::string::npos || slash == 0 || slash + 1 >= cidr.size()) return false;
  *address = cidr.substr(0, slash);
  char* end = nullptr;
  const unsigned long parsed = std::strtoul(cidr.c_str() + slash + 1, &end, 10);
  if (end == nullptr || *end != '\0') return false;
  g_autoptr(GInetAddress) inet = g_inet_address_new_from_string(address->c_str());
  if (inet == nullptr) return false;
  const uint32_t maximum =
      g_inet_address_get_family(inet) == G_SOCKET_FAMILY_IPV4 ? 32 : 128;
  if (parsed > maximum) return false;
  *prefix = static_cast<uint32_t>(parsed);
  return true;
}

GVariant* BuildAddressData(const std::vector<std::string>& addresses,
                           GSocketFamily family,
                           bool* valid) {
  GVariantBuilder array;
  g_variant_builder_init(&array, G_VARIANT_TYPE("aa{sv}"));
  for (const auto& cidr : addresses) {
    std::string address;
    uint32_t prefix = 0;
    if (!SplitCidr(cidr, &address, &prefix)) {
      *valid = false;
      break;
    }
    g_autoptr(GInetAddress) inet = g_inet_address_new_from_string(address.c_str());
    if (inet == nullptr || g_inet_address_get_family(inet) != family) continue;
    GVariantBuilder item;
    g_variant_builder_init(&item, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&item, "{sv}", "address", g_variant_new_string(address.c_str()));
    g_variant_builder_add(&item, "{sv}", "prefix", g_variant_new_uint32(prefix));
    g_variant_builder_add_value(&array, g_variant_builder_end(&item));
  }
  return g_variant_builder_end(&array);
}

GVariant* BuildDnsData(const std::vector<std::string>& dns,
                       GSocketFamily family,
                       bool* valid) {
  GVariantBuilder array;
  g_variant_builder_init(&array, G_VARIANT_TYPE("as"));
  for (const auto& value : dns) {
    g_autoptr(GInetAddress) inet = g_inet_address_new_from_string(value.c_str());
    if (inet == nullptr) {
      *valid = false;
      break;
    }
    if (g_inet_address_get_family(inet) == family) {
      g_variant_builder_add(&array, "s", value.c_str());
    }
  }
  return g_variant_builder_end(&array);
}

}  // namespace

GVariant* BuildNetworkManagerSettings(const WireGuardConfig& config,
                                      const char* profile_id,
                                      const char* profile_uuid,
                                      const char* interface_name,
                                      bool* valid) {
  if (profile_id == nullptr || profile_uuid == nullptr ||
      !g_uuid_string_is_valid(profile_uuid) || interface_name == nullptr ||
      valid == nullptr) {
    return nullptr;
  }
  *valid = true;
  GVariantBuilder outer;
  g_variant_builder_init(&outer, G_VARIANT_TYPE("a{sa{sv}}"));

  GVariantBuilder connection;
  g_variant_builder_init(&connection, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&connection, "{sv}", "id", g_variant_new_string(profile_id));
  g_variant_builder_add(&connection, "{sv}", "uuid", g_variant_new_string(profile_uuid));
  g_variant_builder_add(&connection, "{sv}", "type", g_variant_new_string("wireguard"));
  g_variant_builder_add(&connection, "{sv}", "interface-name",
                        g_variant_new_string(interface_name));
  g_variant_builder_add(&connection, "{sv}", "autoconnect", g_variant_new_boolean(FALSE));
  AddSetting(&outer, "connection", &connection);

  GVariantBuilder wireguard;
  g_variant_builder_init(&wireguard, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&wireguard, "{sv}", "private-key",
                        g_variant_new_string(config.private_key.c_str()));
  g_variant_builder_add(&wireguard, "{sv}", "private-key-flags", g_variant_new_uint32(0));
  g_variant_builder_add(&wireguard, "{sv}", "peer-routes", g_variant_new_boolean(TRUE));
  if (config.listen_port != 0) {
    g_variant_builder_add(&wireguard, "{sv}", "listen-port",
                          g_variant_new_uint32(config.listen_port));
  }
  if (config.mtu != 0) {
    g_variant_builder_add(&wireguard, "{sv}", "mtu", g_variant_new_uint32(config.mtu));
  }

  GVariantBuilder peers;
  g_variant_builder_init(&peers, G_VARIANT_TYPE("aa{sv}"));
  for (const auto& peer : config.peers) {
    GVariantBuilder item;
    g_variant_builder_init(&item, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&item, "{sv}", "public-key",
                          g_variant_new_string(peer.public_key.c_str()));
    g_variant_builder_add(&item, "{sv}", "endpoint",
                          g_variant_new_string(peer.endpoint.c_str()));
    if (!peer.preshared_key.empty()) {
      g_variant_builder_add(&item, "{sv}", "preshared-key",
                            g_variant_new_string(peer.preshared_key.c_str()));
      g_variant_builder_add(&item, "{sv}", "preshared-key-flags",
                            g_variant_new_uint32(0));
    }
    if (peer.persistent_keepalive != 0) {
      g_variant_builder_add(&item, "{sv}", "persistent-keepalive",
                            g_variant_new_uint32(peer.persistent_keepalive));
    }
    GVariantBuilder allowed;
    g_variant_builder_init(&allowed, G_VARIANT_TYPE("as"));
    for (const auto& value : peer.allowed_ips) {
      std::string address;
      uint32_t prefix = 0;
      if (!SplitCidr(value, &address, &prefix)) *valid = false;
      g_variant_builder_add(&allowed, "s", value.c_str());
    }
    g_variant_builder_add(&item, "{sv}", "allowed-ips",
                          g_variant_builder_end(&allowed));
    g_variant_builder_add_value(&peers, g_variant_builder_end(&item));
  }
  g_variant_builder_add(&wireguard, "{sv}", "peers", g_variant_builder_end(&peers));
  AddSetting(&outer, "wireguard", &wireguard);

  for (const auto family : {G_SOCKET_FAMILY_IPV4, G_SOCKET_FAMILY_IPV6}) {
    const bool ipv4 = family == G_SOCKET_FAMILY_IPV4;
    GVariantBuilder ip;
    g_variant_builder_init(&ip, G_VARIANT_TYPE("a{sv}"));
    g_autoptr(GVariant) addresses = BuildAddressData(config.addresses, family, valid);
    const bool has_addresses = g_variant_n_children(addresses) > 0;
    g_variant_builder_add(&ip, "{sv}", "method",
                          g_variant_new_string(has_addresses ? "manual" : "disabled"));
    if (has_addresses) {
      g_variant_builder_add(&ip, "{sv}", "address-data", g_steal_pointer(&addresses));
    }
    g_autoptr(GVariant) dns = BuildDnsData(config.dns, family, valid);
    const bool has_dns = g_variant_n_children(dns) > 0;
    if (has_dns) {
      g_variant_builder_add(&ip, "{sv}", "dns-data", g_steal_pointer(&dns));
      // A negative priority excludes DNS from other active connections when
      // NetworkManager selects this full-device WireGuard route.
      g_variant_builder_add(&ip, "{sv}", "dns-priority", g_variant_new_int32(-50));
    }
    AddSetting(&outer, ipv4 ? "ipv4" : "ipv6", &ip);
  }
  return g_variant_ref_sink(g_variant_builder_end(&outer));
}

}  // namespace zagros_tunnel_linux
