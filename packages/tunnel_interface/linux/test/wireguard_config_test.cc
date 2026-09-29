#include "../wireguard_config.h"

#include <cassert>
#include <cstdint>
#include <string>

using zagros_tunnel_linux::ParseWireGuardConfig;
using zagros_tunnel_linux::SecureClear;
using zagros_tunnel_linux::WireGuardConfig;

namespace {

constexpr char kKey[] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

bool Parse(const std::string& value, WireGuardConfig* config, std::string* error) {
  return ParseWireGuardConfig(reinterpret_cast<const uint8_t*>(value.data()),
                              value.size(), config, error);
}

}  // namespace

int main() {
  const std::string valid =
      std::string("[Interface]\nPrivateKey = ") + kKey +
      "\nAddress = 10.0.0.2/32\nDNS = 1.1.1.1\nMTU = 1280\n"
      "\n[Peer]\nPublicKey = " + kKey +
      "\nPresharedKey = " + kKey +
      "\nEndpoint = 192.0.2.1:51820\nAllowedIPs = 0.0.0.0/0, ::/0\n"
      "PersistentKeepalive = 25\n";
  WireGuardConfig config;
  std::string error;
  assert(Parse(valid, &config, &error));
  assert(error.empty());
  assert(config.private_key == kKey);
  assert(config.addresses.size() == 1);
  assert(config.peers.size() == 1);
  assert(config.peers[0].allowed_ips.size() == 2);
  SecureClear(&config);
  assert(config.private_key.empty());
  assert(config.peers.empty());
  assert(config.listen_port == 0);
  assert(config.mtu == 0);

  // A failed reparse must erase data already held by the destination object.
  config.private_key = kKey;
  config.peers.emplace_back();
  config.peers[0].preshared_key = kKey;
  config.peers[0].persistent_keepalive = 25;

  const std::string script =
      std::string("[Interface]\nPrivateKey = ") + kKey +
      "\nAddress = 10.0.0.2/32\nPostUp = echo unsafe\n"
      "[Peer]\nPublicKey = " + kKey +
      "\nEndpoint = 192.0.2.1:51820\nAllowedIPs = 0.0.0.0/0\n";
  assert(!Parse(script, &config, &error));
  assert(error == "unsupported_directive");
  assert(config.private_key.empty());
  assert(config.peers.empty());

  std::string oversized(256 * 1024 + 1, 'A');
  assert(!Parse(oversized, &config, &error));
  assert(error == "invalid_config_size");

  const std::string duplicate =
      std::string("[Interface]\nPrivateKey = ") + kKey +
      "\nPrivateKey = " + kKey +
      "\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = " + kKey +
      "\nEndpoint = 192.0.2.1:51820\nAllowedIPs = 0.0.0.0/0\n";
  assert(!Parse(duplicate, &config, &error));
  assert(error == "duplicate_directive");

  return 0;
}
