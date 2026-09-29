#include "../network_manager_settings.h"
#include "../wireguard_config.h"

#include <cassert>
#include <cstdint>
#include <cstring>
#include <string>

using zagros_tunnel_linux::BuildNetworkManagerSettings;
using zagros_tunnel_linux::ParseWireGuardConfig;
using zagros_tunnel_linux::SecureClear;
using zagros_tunnel_linux::WireGuardConfig;

namespace {

constexpr char kKey[] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
constexpr char kProfileId[] = "Zagros Runtime WireGuard";
constexpr char kProfileUuid[] = "7fb51e72-8e80-4e3a-9d14-91db73c6d85f";

bool Parse(const std::string& value, WireGuardConfig* config) {
  std::string error;
  return ParseWireGuardConfig(reinterpret_cast<const uint8_t*>(value.data()),
                              value.size(), config, &error);
}

}  // namespace

int main() {
  const std::string input =
      std::string("[Interface]\nPrivateKey = ") + kKey +
      "\nAddress = 10.0.0.2/32, fd00::2/128\nDNS = 1.1.1.1, 2606:4700:4700::1111\n"
      "MTU = 1280\n[Peer]\nPublicKey = " + kKey +
      "\nPresharedKey = " + kKey +
      "\nEndpoint = 192.0.2.1:51820\nAllowedIPs = 0.0.0.0/0, ::/0\n"
      "PersistentKeepalive = 25\n";
  WireGuardConfig config;
  assert(Parse(input, &config));

  bool valid = false;
  g_autoptr(GVariant) settings = BuildNetworkManagerSettings(
      config, kProfileId, kProfileUuid, "zgvpn0", &valid);
  assert(valid);
  assert(settings != nullptr);
  assert(g_variant_is_of_type(settings, G_VARIANT_TYPE("a{sa{sv}}")));

  g_autoptr(GVariant) connection =
      g_variant_lookup_value(settings, "connection", G_VARIANT_TYPE("a{sv}"));
  assert(connection != nullptr);
  const gchar* id = nullptr;
  const gchar* uuid = nullptr;
  const gchar* type = nullptr;
  const gchar* interface_name = nullptr;
  gboolean autoconnect = TRUE;
  assert(g_variant_lookup(connection, "id", "&s", &id));
  assert(std::strcmp(id, kProfileId) == 0);
  assert(g_variant_lookup(connection, "uuid", "&s", &uuid));
  assert(std::strcmp(uuid, kProfileUuid) == 0);
  assert(g_variant_lookup(connection, "type", "&s", &type));
  assert(std::strcmp(type, "wireguard") == 0);
  assert(g_variant_lookup(connection, "interface-name", "&s", &interface_name));
  assert(std::strcmp(interface_name, "zgvpn0") == 0);
  assert(g_variant_lookup(connection, "autoconnect", "b", &autoconnect));
  assert(!autoconnect);

  g_autoptr(GVariant) wireguard =
      g_variant_lookup_value(settings, "wireguard", G_VARIANT_TYPE("a{sv}"));
  assert(wireguard != nullptr);
  const gchar* private_key = nullptr;
  gboolean peer_routes = FALSE;
  assert(g_variant_lookup(wireguard, "private-key", "&s", &private_key));
  assert(std::strcmp(private_key, kKey) == 0);
  assert(g_variant_lookup(wireguard, "peer-routes", "b", &peer_routes));
  assert(peer_routes);
  g_autoptr(GVariant) peers =
      g_variant_lookup_value(wireguard, "peers", G_VARIANT_TYPE("aa{sv}"));
  assert(peers != nullptr);
  assert(g_variant_n_children(peers) == 1);

  for (const char* family : {"ipv4", "ipv6"}) {
    g_autoptr(GVariant) ip =
        g_variant_lookup_value(settings, family, G_VARIANT_TYPE("a{sv}"));
    assert(ip != nullptr);
    const gchar* method = nullptr;
    assert(g_variant_lookup(ip, "method", "&s", &method));
    assert(std::strcmp(method, "manual") == 0);
    g_autoptr(GVariant) addresses =
        g_variant_lookup_value(ip, "address-data", G_VARIANT_TYPE("aa{sv}"));
    assert(addresses != nullptr);
    assert(g_variant_n_children(addresses) == 1);
    gint32 dns_priority = 0;
    assert(g_variant_lookup(ip, "dns-priority", "i", &dns_priority));
    assert(dns_priority == -50);
  }

  SecureClear(&config);
  config.private_key = kKey;
  config.addresses = {"10.0.0.2/32"};
  config.dns = {"dns-name-is-not-permitted.example"};
  config.peers.emplace_back();
  config.peers[0].public_key = kKey;
  config.peers[0].endpoint = "192.0.2.1:51820";
  config.peers[0].allowed_ips = {"0.0.0.0/0"};
  valid = true;
  g_autoptr(GVariant) rejected = BuildNetworkManagerSettings(
      config, kProfileId, kProfileUuid, "zgvpn0", &valid);
  assert(rejected != nullptr);
  assert(!valid);
  SecureClear(&config);
  return 0;
}
