#include "wireguard_config.h"

#include <algorithm>
#include <charconv>
#include <cctype>
#include <set>
#include <string_view>

namespace zagros_tunnel_linux {
namespace {

constexpr size_t kMaximumConfigBytes = 256 * 1024;
constexpr size_t kMaximumLineBytes = 8192;
constexpr size_t kMaximumPeers = 64;
constexpr size_t kMaximumValues = 128;

enum class Section { kNone, kInterface, kPeer };

void ClearString(std::string* value) {
  volatile char* data = value->empty() ? nullptr : value->data();
  for (size_t i = 0; i < value->size(); ++i) data[i] = 0;
  value->clear();
  value->shrink_to_fit();
}

std::string_view Trim(std::string_view value) {
  while (!value.empty() && std::isspace(static_cast<unsigned char>(value.front())))
    value.remove_prefix(1);
  while (!value.empty() && std::isspace(static_cast<unsigned char>(value.back())))
    value.remove_suffix(1);
  return value;
}

std::string Lower(std::string_view value) {
  std::string result(value);
  std::transform(result.begin(), result.end(), result.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return result;
}

bool IsSafeScalar(std::string_view value) {
  if (value.empty() || value.size() > 4096) return false;
  return std::all_of(value.begin(), value.end(), [](unsigned char c) {
    return c >= 0x20 && c != 0x7f;
  });
}

bool IsBase64Key(std::string_view value) {
  if (value.size() != 44 || value.back() != '=') return false;
  for (size_t i = 0; i + 1 < value.size(); ++i) {
    const unsigned char c = value[i];
    if (!(std::isalnum(c) || c == '+' || c == '/')) return false;
  }
  return true;
}

bool ParseInteger(std::string_view value,
                  uint32_t minimum,
                  uint32_t maximum,
                  uint32_t* output) {
  uint32_t parsed = 0;
  const auto result = std::from_chars(value.data(), value.data() + value.size(), parsed);
  if (result.ec != std::errc() || result.ptr != value.data() + value.size() ||
      parsed < minimum || parsed > maximum) {
    return false;
  }
  *output = parsed;
  return true;
}

bool SplitValues(std::string_view value, std::vector<std::string>* output) {
  size_t offset = 0;
  while (offset <= value.size()) {
    const size_t comma = value.find(',', offset);
    const auto item = Trim(value.substr(
        offset, comma == std::string_view::npos ? value.size() - offset : comma - offset));
    if (!IsSafeScalar(item) || output->size() >= kMaximumValues) return false;
    output->emplace_back(item);
    if (comma == std::string_view::npos) break;
    offset = comma + 1;
  }
  return !output->empty();
}

bool Fail(std::string* error, const char* code) {
  *error = code;
  return false;
}

}  // namespace

bool ParseWireGuardConfig(const uint8_t* bytes,
                          size_t length,
                          WireGuardConfig* output,
                          std::string* safe_error_code) {
  if (output == nullptr || safe_error_code == nullptr) return false;
  SecureClear(output);
  if (bytes == nullptr || length == 0 || length > kMaximumConfigBytes) {
    return Fail(safe_error_code, "invalid_config_size");
  }
  WireGuardConfig parsed;
  Section section = Section::kNone;
  WireGuardPeer* peer = nullptr;
  std::set<std::string> interface_keys;
  std::set<std::string> peer_keys;
  size_t start = 0;
  while (start <= length) {
    size_t end = start;
    while (end < length && bytes[end] != '\n') ++end;
    if (end - start > kMaximumLineBytes) {
      SecureClear(&parsed);
      return Fail(safe_error_code, "line_too_long");
    }
    std::string_view line(reinterpret_cast<const char*>(bytes + start), end - start);
    if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
    line = Trim(line);
    if (!line.empty() && line.front() != '#' && line.front() != ';') {
      if (line == "[Interface]") {
        if (section != Section::kNone) {
          SecureClear(&parsed);
          return Fail(safe_error_code, "duplicate_interface");
        }
        section = Section::kInterface;
      } else if (line == "[Peer]") {
        if (section == Section::kNone || parsed.peers.size() >= kMaximumPeers) {
          SecureClear(&parsed);
          return Fail(safe_error_code, "invalid_peer_count");
        }
        section = Section::kPeer;
        parsed.peers.emplace_back();
        peer = &parsed.peers.back();
        peer_keys.clear();
      } else {
        const size_t equals = line.find('=');
        if (equals == std::string_view::npos || section == Section::kNone) {
          SecureClear(&parsed);
          return Fail(safe_error_code, "invalid_directive");
        }
        const std::string key = Lower(Trim(line.substr(0, equals)));
        const std::string_view value = Trim(line.substr(equals + 1));
        if (!IsSafeScalar(value)) {
          SecureClear(&parsed);
          return Fail(safe_error_code, "invalid_value");
        }
        if (section == Section::kInterface) {
          if (!interface_keys.insert(key).second) {
            SecureClear(&parsed);
            return Fail(safe_error_code, "duplicate_directive");
          }
          if (key == "privatekey" && IsBase64Key(value)) {
            parsed.private_key.assign(value);
          } else if (key == "address") {
            if (!SplitValues(value, &parsed.addresses)) {
              SecureClear(&parsed);
              return Fail(safe_error_code, "invalid_address");
            }
          } else if (key == "dns") {
            if (!SplitValues(value, &parsed.dns)) {
              SecureClear(&parsed);
              return Fail(safe_error_code, "invalid_dns");
            }
          } else if (key == "listenport") {
            if (!ParseInteger(value, 1, 65535, &parsed.listen_port)) {
              SecureClear(&parsed);
              return Fail(safe_error_code, "invalid_listen_port");
            }
          } else if (key == "mtu") {
            if (!ParseInteger(value, 576, 65535, &parsed.mtu)) {
              SecureClear(&parsed);
              return Fail(safe_error_code, "invalid_mtu");
            }
          } else {
            SecureClear(&parsed);
            return Fail(safe_error_code, "unsupported_directive");
          }
        } else {
          if (peer == nullptr || !peer_keys.insert(key).second) {
            SecureClear(&parsed);
            return Fail(safe_error_code, "duplicate_peer_directive");
          }
          if (key == "publickey" && IsBase64Key(value)) {
            peer->public_key.assign(value);
          } else if (key == "presharedkey" && IsBase64Key(value)) {
            peer->preshared_key.assign(value);
          } else if (key == "endpoint") {
            peer->endpoint.assign(value);
          } else if (key == "allowedips") {
            if (!SplitValues(value, &peer->allowed_ips)) {
              SecureClear(&parsed);
              return Fail(safe_error_code, "invalid_allowed_ips");
            }
          } else if (key == "persistentkeepalive") {
            if (!ParseInteger(value, 0, 65535, &peer->persistent_keepalive)) {
              SecureClear(&parsed);
              return Fail(safe_error_code, "invalid_keepalive");
            }
          } else {
            SecureClear(&parsed);
            return Fail(safe_error_code, "unsupported_peer_directive");
          }
        }
      }
    }
    if (end == length) break;
    start = end + 1;
  }
  if (parsed.private_key.empty() || parsed.addresses.empty() || parsed.peers.empty()) {
    SecureClear(&parsed);
    return Fail(safe_error_code, "incomplete_config");
  }
  for (const auto& item : parsed.peers) {
    if (item.public_key.empty() || item.endpoint.empty() || item.allowed_ips.empty()) {
      SecureClear(&parsed);
      return Fail(safe_error_code, "incomplete_peer");
    }
  }
  *output = std::move(parsed);
  safe_error_code->clear();
  return true;
}

void SecureClear(WireGuardConfig* config) {
  if (config == nullptr) return;
  ClearString(&config->private_key);
  for (auto& value : config->addresses) ClearString(&value);
  for (auto& value : config->dns) ClearString(&value);
  for (auto& peer : config->peers) {
    ClearString(&peer.public_key);
    ClearString(&peer.preshared_key);
    ClearString(&peer.endpoint);
    for (auto& value : peer.allowed_ips) ClearString(&value);
    peer.persistent_keepalive = 0;
  }
  config->addresses.clear();
  config->dns.clear();
  config->peers.clear();
  config->listen_port = 0;
  config->mtu = 0;
}

}  // namespace zagros_tunnel_linux
