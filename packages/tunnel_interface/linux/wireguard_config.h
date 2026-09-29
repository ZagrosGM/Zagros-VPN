#ifndef ZAGROS_TUNNEL_WIREGUARD_CONFIG_H_
#define ZAGROS_TUNNEL_WIREGUARD_CONFIG_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace zagros_tunnel_linux {

struct WireGuardPeer {
  std::string public_key;
  std::string preshared_key;
  std::string endpoint;
  std::vector<std::string> allowed_ips;
  uint32_t persistent_keepalive = 0;
};

struct WireGuardConfig {
  std::string private_key;
  std::vector<std::string> addresses;
  std::vector<std::string> dns;
  uint32_t listen_port = 0;
  uint32_t mtu = 0;
  std::vector<WireGuardPeer> peers;
};

bool ParseWireGuardConfig(const uint8_t* bytes,
                          size_t length,
                          WireGuardConfig* output,
                          std::string* safe_error_code);
void SecureClear(WireGuardConfig* config);

}  // namespace zagros_tunnel_linux

#endif  // ZAGROS_TUNNEL_WIREGUARD_CONFIG_H_
