#include "tunnel_interface_plugin.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <lmcons.h>
#include <ras.h>
#include <raserror.h>
#include <strsafe.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/base.h>

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <cwctype>
#include <functional>
#include <iterator>
#include <limits>
#include <mutex>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace tunnel_interface {
namespace {

using zagros_tunnel::ErrorOr;
using zagros_tunnel::NativeTunnelCapabilities;
using zagros_tunnel::NativeTunnelRequest;
using zagros_tunnel::NativeTunnelState;
using zagros_tunnel::NativeTunnelStatus;

constexpr size_t kMaximumConfigBytes = 256 * 1024;
constexpr wchar_t kEntryName[] = L"Zagros Runtime";
constexpr wchar_t kWindowClass[] = L"ZagrosTunnelRasMessageWindow";
constexpr UINT_PTR kStatusTimer = 1;
constexpr DWORD kWindowNotifierType = 0xFFFFFFFF;
constexpr UINT kOperationPollMilliseconds = 250;
constexpr UINT kConnectedPollMilliseconds = 1000;
constexpr int kConnectPollLimit = 120;
constexpr int kTeardownPollLimit = 40;

void SecureClear(std::string* value) {
  if (!value->empty()) SecureZeroMemory(value->data(), value->size());
  value->clear();
}

void SecureClear(std::wstring* value) {
  if (!value->empty()) SecureZeroMemory(value->data(), value->size() * sizeof(wchar_t));
  value->clear();
}

bool SafeIdentifier(std::string_view value) {
  if (value.empty() || value.size() > 128 ||
      !std::isalnum(static_cast<unsigned char>(value[0]))) {
    return false;
  }
  return std::all_of(value.begin() + 1, value.end(), [](unsigned char c) {
    return std::isalnum(c) || c == '.' || c == '_' || c == ':' || c == '-';
  });
}

bool SafeReason(std::string_view value) {
  if (value.empty() || value.size() > 64) return false;
  return std::all_of(value.begin(), value.end(), [](unsigned char c) {
    return std::islower(c) || std::isdigit(c) || c == '_';
  });
}

bool SafeScalar(std::wstring_view value, size_t maximum) {
  if (value.empty() || value.size() > maximum) return false;
  return std::all_of(value.begin(), value.end(), [](wchar_t c) {
    return c >= 0x20 && c != 0x7f;
  });
}

bool AllowedConfigurationKey(std::wstring_view key) {
  constexpr std::wstring_view allowed[] = {
      L"version", L"server", L"port", L"username", L"password",
      L"shared_secret", L"remote_identifier", L"local_identifier"};
  return std::find(std::begin(allowed), std::end(allowed), key) !=
         std::end(allowed);
}

struct SystemVpnConfiguration {
  std::wstring server;
  std::wstring username;
  std::wstring password;

  ~SystemVpnConfiguration() {
    SecureClear(&server);
    SecureClear(&username);
    SecureClear(&password);
  }
};

bool ReadRequiredString(const winrt::Windows::Data::Json::JsonObject& object,
                        std::wstring_view key,
                        size_t maximum,
                        std::wstring* output) {
  if (!object.HasKey(key)) return false;
  try {
    *output = object.GetNamedString(key);
    return SafeScalar(*output, maximum);
  } catch (...) {
    return false;
  }
}

bool Decode(const std::vector<uint8_t>& payload, SystemVpnConfiguration* output) {
  if (payload.empty() || payload.size() > kMaximumConfigBytes) return false;
  std::string json(reinterpret_cast<const char*>(payload.data()), payload.size());
  try {
    const auto object = winrt::Windows::Data::Json::JsonObject::Parse(winrt::to_hstring(json));
    SecureClear(&json);
    if (object.Size() > 8 || object.GetNamedNumber(L"version", 0) != 1 ||
        object.GetNamedNumber(L"port", 0) != 500) {
      return false;
    }
    for (const auto& entry : object) {
      if (!AllowedConfigurationKey(entry.Key().c_str())) return false;
    }
    if (!ReadRequiredString(object, L"server", 253, &output->server) ||
        !ReadRequiredString(object, L"username", UNLEN, &output->username) ||
        !ReadRequiredString(object, L"password", PWLEN, &output->password)) {
      return false;
    }
    // This adapter deliberately supports only IKEv2 EAP username/password.
    // PSK and certificate variants are unavailable until separately reviewed.
    return true;
  } catch (...) {
    SecureClear(&json);
    return false;
  }
}

::flutter::EncodableMap UnavailableReasons(bool ikev2_available) {
  ::flutter::EncodableMap reasons = {
      {::flutter::EncodableValue("wireguard"),
       ::flutter::EncodableValue("The reviewed WireGuard embeddable service is not packaged.")},
      {::flutter::EncodableValue("openvpn"),
       ::flutter::EncodableValue("A reviewed OpenVPN engine is not packaged.")},
      {::flutter::EncodableValue("ovpn"),
       ::flutter::EncodableValue("A reviewed OpenVPN engine is not packaged.")},
      {::flutter::EncodableValue("xray"),
       ::flutter::EncodableValue("A reviewed Xray engine is not packaged.")},
      {::flutter::EncodableValue("sing-box"),
       ::flutter::EncodableValue("A reviewed sing-box engine is not packaged.")},
      {::flutter::EncodableValue("vless"),
       ::flutter::EncodableValue("No reviewed Xray or sing-box VLESS engine is packaged.")},
      {::flutter::EncodableValue("vmess"),
       ::flutter::EncodableValue("No reviewed Xray or sing-box VMess engine is packaged.")},
      {::flutter::EncodableValue("trojan"),
       ::flutter::EncodableValue("No reviewed Xray or sing-box Trojan engine is packaged.")},
      {::flutter::EncodableValue("shadowsocks"),
       ::flutter::EncodableValue("No reviewed Xray or sing-box Shadowsocks engine is packaged.")},
      {::flutter::EncodableValue("hysteria2"),
       ::flutter::EncodableValue("No reviewed sing-box Hysteria2 engine is packaged.")},
      {::flutter::EncodableValue("tuic"),
       ::flutter::EncodableValue("No reviewed sing-box TUIC engine is packaged.")},
      {::flutter::EncodableValue("anytls"),
       ::flutter::EncodableValue("No reviewed sing-box AnyTLS engine is packaged.")},
      {::flutter::EncodableValue("socks"),
       ::flutter::EncodableValue("No reviewed SOCKS-to-device-tunnel engine is packaged.")},
      {::flutter::EncodableValue("http"),
       ::flutter::EncodableValue("No reviewed HTTP-proxy-to-device-tunnel engine is packaged.")},
      {::flutter::EncodableValue("https"),
       ::flutter::EncodableValue("No reviewed HTTPS-proxy-to-device-tunnel engine is packaged.")},
      {::flutter::EncodableValue("softether"),
       ::flutter::EncodableValue("A reviewed native SoftEther engine is not packaged.")},
      {::flutter::EncodableValue("ssh"),
       ::flutter::EncodableValue("A reviewed device-tunnel SSH engine is not packaged.")},
      {::flutter::EncodableValue("pptp"),
       ::flutter::EncodableValue("Legacy PPTP is not enabled by this secure adapter.")},
      {::flutter::EncodableValue("l2tp"),
       ::flutter::EncodableValue("A reviewed L2TP/IPsec path is not enabled.")},
      {::flutter::EncodableValue("l2tp+ipsec"),
       ::flutter::EncodableValue("A reviewed L2TP/IPsec path is not enabled.")},
  };
  if (!ikev2_available) {
    reasons.emplace(::flutter::EncodableValue("ikev2"),
                    ::flutter::EncodableValue("Windows IKEv2 RAS or ownership cleanup is unavailable."));
  }
  return reasons;
}

std::wstring FindIkev2RasDevice() {
  DWORD bytes = sizeof(RASDEVINFOW);
  DWORD count = 0;
  std::vector<RASDEVINFOW> storage(1);
  storage[0].dwSize = sizeof(RASDEVINFOW);
  DWORD error = RasEnumDevicesW(storage.data(), &bytes, &count);
  if (error == ERROR_BUFFER_TOO_SMALL) {
    storage.assign((bytes + sizeof(RASDEVINFOW) - 1) / sizeof(RASDEVINFOW),
                   RASDEVINFOW{});
    storage[0].dwSize = sizeof(RASDEVINFOW);
    error = RasEnumDevicesW(storage.data(), &bytes, &count);
  }
  const auto* devices = storage.data();
  if (error != ERROR_SUCCESS) return {};
  for (DWORD index = 0; index < count; ++index) {
    if (std::wstring_view(devices[index].szDeviceType) != RASDT_Vpn) continue;
    std::wstring folded_name = devices[index].szDeviceName;
    std::transform(folded_name.begin(), folded_name.end(), folded_name.begin(),
                   [](wchar_t value) { return static_cast<wchar_t>(std::towlower(value)); });
    if (folded_name.find(L"ikev2") != std::wstring::npos) {
      return devices[index].szDeviceName;
    }
  }
  return {};
}

HRASCONN FindOwnedConnection() {
  DWORD bytes = sizeof(RASCONNW);
  DWORD count = 0;
  std::vector<RASCONNW> connections(1);
  connections[0].dwSize = sizeof(RASCONNW);
  DWORD error = RasEnumConnectionsW(connections.data(), &bytes, &count);
  if (error == ERROR_BUFFER_TOO_SMALL) {
    connections.assign((bytes + sizeof(RASCONNW) - 1) / sizeof(RASCONNW), RASCONNW{});
    connections[0].dwSize = sizeof(RASCONNW);
    error = RasEnumConnectionsW(connections.data(), &bytes, &count);
  }
  if (error != ERROR_SUCCESS) return nullptr;
  for (DWORD index = 0; index < count; ++index) {
    if (std::wstring_view(connections[index].szEntryName) == kEntryName) {
      return connections[index].hrasconn;
    }
  }
  return nullptr;
}

enum class EntryOwnership { kMissing, kOwned, kForeignOrUnreadable };

EntryOwnership InspectOwnedPhonebookEntry() {
  RASENTRYW entry{};
  entry.dwSize = sizeof(entry);
  DWORD entry_bytes = sizeof(entry);
  DWORD device_bytes = 0;
  const DWORD error = RasGetEntryPropertiesW(nullptr, kEntryName, &entry, &entry_bytes,
                                             nullptr, &device_bytes);
  if (error == ERROR_CANNOT_FIND_PHONEBOOK_ENTRY) return EntryOwnership::kMissing;
  if (error != ERROR_SUCCESS) return EntryOwnership::kForeignOrUnreadable;
  const bool owned =
      entry.dwType == RASET_Vpn && entry.dwVpnStrategy == VS_Ikev2Only &&
      std::wstring_view(entry.szDeviceType) == RASDT_Vpn &&
      (entry.dwfOptions & RASEO_RemoteDefaultGateway) != 0 &&
      (entry.dwfOptions & RASEO_RequireDataEncryption) != 0 &&
      (entry.dwfOptions & RASEO_RequireMsCHAP2) != 0;
  SecureZeroMemory(&entry, sizeof(entry));
  return owned ? EntryOwnership::kOwned : EntryOwnership::kForeignOrUnreadable;
}

bool DeleteOwnedPhonebookEntry() {
  const EntryOwnership ownership = InspectOwnedPhonebookEntry();
  if (ownership == EntryOwnership::kMissing) return true;
  if (ownership != EntryOwnership::kOwned) return false;
  const DWORD error = RasDeleteEntryW(nullptr, kEntryName);
  return error == ERROR_SUCCESS || error == ERROR_CANNOT_FIND_PHONEBOOK_ENTRY;
}

int64_t UnixMilliseconds() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

}  // namespace

class ZagrosTunnelPlugin::State {
 public:
  using ResultCallback = std::function<void(ErrorOr<NativeTunnelStatus>)>;
  using PublishCallback = std::function<void(const NativeTunnelStatus&)>;

  explicit State(PublishCallback publish) : publish_(std::move(publish)) {
    ras_message_ = RegisterWindowMessageW(L"RasDialEvent");
    if (ras_message_ == 0) ras_message_ = WM_RASDIALEVENT;

    static std::once_flag register_once;
    std::call_once(register_once, [] {
      WNDCLASSW window_class{};
      window_class.lpfnWndProc = &State::WindowProcedure;
      window_class.hInstance = GetModuleHandleW(nullptr);
      window_class.lpszClassName = kWindowClass;
      if (RegisterClassW(&window_class) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        return;
      }
    });
    window_ = CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                              nullptr, GetModuleHandleW(nullptr), this);
    ras_device_name_ = FindIkev2RasDevice();
    const bool runtime_present = window_ != nullptr && !ras_device_name_.empty();
    if (!runtime_present) return;
    entry_name_ = kEntryName;
    const EntryOwnership ownership = InspectOwnedPhonebookEntry();
    if (ownership == EntryOwnership::kForeignOrUnreadable) {
      failure_code_ = "ownership_conflict";
      SetState(NativeTunnelState::kFailed, false);
      return;
    }
    connection_ = ownership == EntryOwnership::kOwned ? FindOwnedConnection() : nullptr;
    if (connection_ != nullptr) {
      operation_ = Operation::kStartupCleanup;
      RasHangUpW(connection_);
      SetTimer(window_, kStatusTimer, kOperationPollMilliseconds, nullptr);
    } else {
      ras_available_ = DeleteOwnedEntry();
      SetState(ras_available_ ? NativeTunnelState::kDisconnected
                              : NativeTunnelState::kFailed,
               false);
    }
  }

  ~State() {
    pending_result_ = nullptr;
    if (window_ != nullptr) KillTimer(window_, kStatusTimer);
    if (connection_ != nullptr) RasHangUpW(connection_);
    // Never delete a colliding foreign or unreadable phone-book entry during
    // destructor best effort; only the structurally owned fixed entry is ours.
    if (!entry_name_.empty()) DeleteOwnedPhonebookEntry();
    if (window_ != nullptr) DestroyWindow(window_);
    SecureClear(&entry_name_);
    SecureClear(&ras_device_name_);
    SecureClear(&connection_id_);
    SecureClear(&failure_code_);
  }

  bool IsAvailable() const { return ras_available_ && ras_message_ != 0; }

  NativeTunnelStatus GetStatus() {
    if (connection_ != nullptr && operation_ == Operation::kNone) {
      RefreshFromRas(false);
    } else if (connection_ != nullptr) {
      UpdateCounters();
    }
    ++sequence_;
    return Snapshot();
  }

  void BeginConnect(const NativeTunnelRequest& request,
                    SystemVpnConfiguration* config,
                    ResultCallback result) {
    if (!IsAvailable()) {
      CompleteImmediateFailure("backend_unavailable", std::move(result));
      return;
    }
    if (pending_result_ != nullptr || operation_ != Operation::kNone ||
        connection_ != nullptr) {
      CompleteImmediateFailure("operation_in_progress", std::move(result));
      return;
    }

    pending_result_ = std::move(result);
    connection_id_ = request.connection_id();
    entry_name_ = kEntryName;
    // The startup gate and every teardown own this one fixed phone-book entry.
    // A failed deletion is a residue failure, never permission to overwrite it.
    if (!DeleteOwnedEntry()) {
      BeginFailure("cleanup_failed");
      return;
    }
    entry_name_ = kEntryName;
    ResetCounters();
    SetState(NativeTunnelState::kPreparing, true);

    RASENTRYW entry{};
    entry.dwSize = sizeof(entry);
    entry.dwfOptions = RASEO_RemoteDefaultGateway | RASEO_RequireEncryptedPw |
                       RASEO_RequireDataEncryption | RASEO_RequireMsCHAP2;
    entry.dwfOptions2 = RASEO2_IPv6RemoteDefaultGateway;
    entry.dwfNetProtocols = RASNP_Ip | RASNP_Ipv6;
    entry.dwFramingProtocol = RASFP_Ppp;
    entry.dwType = RASET_Vpn;
    entry.dwVpnStrategy = VS_Ikev2Only;
    entry.dwEncryptionType = ET_RequireMax;
    entry.dwRedialCount = 0;
    if (FAILED(StringCchCopyW(entry.szDeviceType, _countof(entry.szDeviceType), RASDT_Vpn)) ||
        FAILED(StringCchCopyW(entry.szDeviceName, _countof(entry.szDeviceName),
                              ras_device_name_.c_str())) ||
        FAILED(StringCchCopyW(entry.szLocalPhoneNumber,
                              _countof(entry.szLocalPhoneNumber), config->server.c_str()))) {
      SecureZeroMemory(&entry, sizeof(entry));
      BeginFailure("invalid_config");
      return;
    }
    const DWORD profile_error = RasSetEntryPropertiesW(
        nullptr, entry_name_.c_str(), &entry, sizeof(entry), nullptr, 0);
    SecureZeroMemory(&entry, sizeof(entry));
    if (profile_error != ERROR_SUCCESS) {
      BeginFailure("profile_failed");
      return;
    }

    RASDIALPARAMSW parameters{};
    parameters.dwSize = sizeof(parameters);
    if (FAILED(StringCchCopyW(parameters.szEntryName, _countof(parameters.szEntryName),
                              entry_name_.c_str())) ||
        FAILED(StringCchCopyW(parameters.szUserName, _countof(parameters.szUserName),
                              config->username.c_str())) ||
        FAILED(StringCchCopyW(parameters.szPassword, _countof(parameters.szPassword),
                              config->password.c_str()))) {
      SecureZeroMemory(&parameters, sizeof(parameters));
      BeginFailure("invalid_config");
      return;
    }

    operation_ = Operation::kConnecting;
    timer_attempts_ = 0;
    SetState(NativeTunnelState::kConnecting, true);
    connection_ = nullptr;
    const DWORD dial_error = RasDialW(nullptr, nullptr, &parameters, kWindowNotifierType,
                                      reinterpret_cast<LPVOID>(window_), &connection_);
    SecureZeroMemory(&parameters, sizeof(parameters));
    if (dial_error != ERROR_SUCCESS || connection_ == nullptr) {
      BeginFailure("activation_failed");
      return;
    }
    SetTimer(window_, kStatusTimer, kOperationPollMilliseconds, nullptr);
  }

  void BeginDisconnect(const std::string& reason, ResultCallback result) {
    if (!SafeReason(reason)) {
      CompleteImmediateFailure("invalid_disconnect_reason", std::move(result));
      return;
    }
    if (pending_result_ != nullptr || operation_ != Operation::kNone) {
      CompleteImmediateFailure("operation_in_progress", std::move(result));
      return;
    }
    pending_result_ = std::move(result);
    if (connection_ == nullptr) {
      connected_at_ = 0;
      ResetCounters();
      if (!DeleteOwnedEntry()) {
        failure_code_ = "cleanup_failed";
        SetState(NativeTunnelState::kFailed, true);
      } else {
        SecureClear(&connection_id_);
        SecureClear(&failure_code_);
        SetState(NativeTunnelState::kDisconnected, true);
      }
      CompletePending(Snapshot());
      return;
    }

    operation_ = Operation::kDisconnecting;
    timer_attempts_ = 0;
    SetState(NativeTunnelState::kDisconnecting, true);
    RasHangUpW(connection_);
    SetTimer(window_, kStatusTimer, kOperationPollMilliseconds, nullptr);
  }

 private:
  enum class Operation {
    kNone,
    kStartupCleanup,
    kConnecting,
    kDisconnecting,
    kFailing,
    kOrphanedTeardown
  };

  static LRESULT CALLBACK WindowProcedure(HWND window,
                                          UINT message,
                                          WPARAM wparam,
                                          LPARAM lparam) {
    State* self = reinterpret_cast<State*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      const auto* create = reinterpret_cast<const CREATESTRUCTW*>(lparam);
      self = static_cast<State*>(create->lpCreateParams);
      SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    }
    if (self != nullptr) return self->HandleWindowMessage(window, message, wparam, lparam);
    return DefWindowProcW(window, message, wparam, lparam);
  }

  LRESULT HandleWindowMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == ras_message_) {
      const auto ras_state = static_cast<RASCONNSTATE>(wparam);
      const DWORD error = static_cast<DWORD>(lparam);
      if (operation_ == Operation::kConnecting) {
        if (error != ERROR_SUCCESS || ras_state == RASCS_Disconnected) {
          BeginFailure("activation_failed");
        } else if (ras_state == RASCS_Connected) {
          CompleteConnected();
        }
      }
      return 0;
    }
    if (message == WM_TIMER && wparam == kStatusTimer) {
      HandleStatusTimer();
      return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
  }

  void HandleStatusTimer() {
    ++timer_attempts_;
    if (operation_ == Operation::kConnecting) {
      RASCONNSTATUSW status{};
      status.dwSize = sizeof(status);
      const DWORD error = connection_ == nullptr
                              ? ERROR_INVALID_HANDLE
                              : RasGetConnectStatusW(connection_, &status);
      if (error != ERROR_SUCCESS || status.rasconnstate == RASCS_Disconnected) {
        BeginFailure("activation_failed");
      } else if (status.rasconnstate == RASCS_Connected) {
        CompleteConnected();
      } else if (timer_attempts_ >= kConnectPollLimit) {
        BeginFailure("activation_timeout");
      }
      return;
    }

    if (operation_ == Operation::kStartupCleanup ||
        operation_ == Operation::kDisconnecting || operation_ == Operation::kFailing ||
        operation_ == Operation::kOrphanedTeardown) {
      RASCONNSTATUSW status{};
      status.dwSize = sizeof(status);
      const DWORD error = connection_ == nullptr
                              ? ERROR_INVALID_HANDLE
                              : RasGetConnectStatusW(connection_, &status);
      if (connection_ == nullptr || error == ERROR_INVALID_HANDLE ||
          (error == ERROR_SUCCESS && status.rasconnstate == RASCS_Disconnected)) {
        CompleteTeardown();
      } else if (timer_attempts_ >= kTeardownPollLimit) {
        RasHangUpW(connection_);
        timer_attempts_ = 0;
        if (operation_ != Operation::kOrphanedTeardown) {
          failure_code_ = "teardown_timeout";
          operation_ = Operation::kOrphanedTeardown;
          SetState(NativeTunnelState::kFailed, true);
          CompletePending(Snapshot());
        }
      }
      return;
    }

    if (operation_ == Operation::kNone && connection_ != nullptr) {
      RefreshFromRas(true);
    } else if (connection_ == nullptr) {
      KillTimer(window_, kStatusTimer);
    }
  }

  void RefreshFromRas(bool publish_change) {
    RASCONNSTATUSW status{};
    status.dwSize = sizeof(status);
    const DWORD status_error = RasGetConnectStatusW(connection_, &status);
    if (status_error != ERROR_SUCCESS) {
      ++status_failures_;
      if (status_failures_ >= 3) {
        failure_code_ = "status_failed";
        operation_ = Operation::kFailing;
        timer_attempts_ = 0;
        RasHangUpW(connection_);
        SetTimer(window_, kStatusTimer, kOperationPollMilliseconds, nullptr);
      }
      return;
    }
    status_failures_ = 0;
    if (status.rasconnstate == RASCS_Disconnected) {
      connection_ = nullptr;
      connected_at_ = 0;
      ResetCounters();
      if (DeleteOwnedEntry()) {
        SecureClear(&connection_id_);
        SecureClear(&failure_code_);
        SetState(NativeTunnelState::kDisconnected, publish_change);
      } else {
        failure_code_ = "cleanup_failed";
        SetState(NativeTunnelState::kFailed, publish_change);
      }
      return;
    }
    if (status.rasconnstate == RASCS_Connected) {
      const int64_t old_uplink = uplink_;
      const int64_t old_downlink = downlink_;
      UpdateCounters();
      const bool changed = state_ != NativeTunnelState::kConnected || old_uplink != uplink_ ||
                           old_downlink != downlink_;
      if (connected_at_ == 0) connected_at_ = UnixMilliseconds();
      SetState(NativeTunnelState::kConnected, publish_change && changed);
    }
  }

  void CompleteConnected() {
    KillTimer(window_, kStatusTimer);
    operation_ = Operation::kNone;
    timer_attempts_ = 0;
    connected_at_ = UnixMilliseconds();
    ResetCounters();
    UpdateCounters();
    SetState(NativeTunnelState::kConnected, true);
    CompletePending(Snapshot());
    SetTimer(window_, kStatusTimer, kConnectedPollMilliseconds, nullptr);
  }

  void BeginFailure(const std::string& code) {
    failure_code_ = code;
    if (connection_ == nullptr) {
      if (!DeleteOwnedEntry()) failure_code_ = "cleanup_failed";
      operation_ = Operation::kNone;
      SetState(NativeTunnelState::kFailed, true);
      CompletePending(Snapshot());
      return;
    }
    operation_ = Operation::kFailing;
    timer_attempts_ = 0;
    RasHangUpW(connection_);
    SetTimer(window_, kStatusTimer, kOperationPollMilliseconds, nullptr);
  }

  void CompleteTeardown() {
    KillTimer(window_, kStatusTimer);
    connection_ = nullptr;
    const Operation completed_operation = operation_;
    const bool removed = DeleteOwnedEntry();
    const bool startup = completed_operation == Operation::kStartupCleanup;
    const bool failed = completed_operation == Operation::kFailing ||
                        completed_operation == Operation::kOrphanedTeardown || !removed;
    operation_ = Operation::kNone;
    timer_attempts_ = 0;
    connected_at_ = 0;
    ResetCounters();
    if (startup) {
      ras_available_ = removed && !ras_device_name_.empty() && window_ != nullptr;
      SecureClear(&connection_id_);
      if (removed)
        SecureClear(&failure_code_);
      else
        failure_code_ = "cleanup_failed";
      SetState(removed ? NativeTunnelState::kDisconnected : NativeTunnelState::kFailed, true);
      return;
    }
    if (failed) {
      if (!removed) failure_code_ = "cleanup_failed";
      SetState(NativeTunnelState::kFailed, true);
      CompletePending(Snapshot());
    } else {
      SecureClear(&connection_id_);
      SecureClear(&failure_code_);
      SetState(NativeTunnelState::kDisconnected, true);
      CompletePending(Snapshot());
    }
  }

  void CompleteImmediateFailure(const std::string& code, ResultCallback result) {
    const std::string safe_message = "The Windows tunnel request was rejected safely.";
    result(zagros_tunnel::FlutterError(code, safe_message));
  }

  void CompletePending(NativeTunnelStatus status) {
    auto result = std::move(pending_result_);
    pending_result_ = nullptr;
    if (result != nullptr) result(std::move(status));
  }

  bool DeleteOwnedEntry() {
    if (entry_name_.empty()) entry_name_ = kEntryName;
    if (!DeleteOwnedPhonebookEntry()) return false;
    SecureClear(&entry_name_);
    return true;
  }

  void ResetCounters() {
    uplink_ = 0;
    downlink_ = 0;
    last_raw_uplink_ = 0;
    last_raw_downlink_ = 0;
    have_raw_counters_ = false;
    status_failures_ = 0;
  }

  void UpdateCounters() {
    if (connection_ == nullptr) return;
    RAS_STATS statistics{};
    statistics.dwSize = sizeof(statistics);
    if (RasGetConnectionStatistics(connection_, &statistics) != ERROR_SUCCESS) return;
    const uint32_t raw_uplink = statistics.dwBytesXmited;
    const uint32_t raw_downlink = statistics.dwBytesRcved;
    if (have_raw_counters_) {
      uplink_ += static_cast<uint32_t>(raw_uplink - last_raw_uplink_);
      downlink_ += static_cast<uint32_t>(raw_downlink - last_raw_downlink_);
    }
    last_raw_uplink_ = raw_uplink;
    last_raw_downlink_ = raw_downlink;
    have_raw_counters_ = true;
  }

  void SetState(NativeTunnelState next, bool publish) {
    const bool changed = state_ != next;
    state_ = next;
    ++sequence_;
    if (publish && (changed || next == NativeTunnelState::kConnected ||
                    next == NativeTunnelState::kFailed)) {
      publish_(Snapshot());
    }
  }

  NativeTunnelStatus Snapshot() const {
    const std::string protocol = "ikev2";
    const std::string safe_message = "The Windows tunnel failed safely.";
    const bool disconnected = state_ == NativeTunnelState::kDisconnected;
    const bool failed = state_ == NativeTunnelState::kFailed;
    return NativeTunnelStatus(
        state_, sequence_, uplink_, downlink_,
        disconnected || connection_id_.empty() ? nullptr : &connection_id_,
        disconnected || connection_id_.empty() ? nullptr : &protocol,
        state_ == NativeTunnelState::kConnected ? &connected_at_ : nullptr,
        failed ? &failure_code_ : nullptr, failed ? &safe_message : nullptr);
  }

  PublishCallback publish_;
  ResultCallback pending_result_;
  HWND window_ = nullptr;
  UINT ras_message_ = 0;
  HRASCONN connection_ = nullptr;
  std::wstring entry_name_;
  std::wstring ras_device_name_;
  std::string connection_id_;
  std::string failure_code_;
  Operation operation_ = Operation::kNone;
  NativeTunnelState state_ = NativeTunnelState::kDisconnected;
  int timer_attempts_ = 0;
  int status_failures_ = 0;
  int64_t sequence_ = 0;
  int64_t connected_at_ = 0;
  int64_t uplink_ = 0;
  int64_t downlink_ = 0;
  uint32_t last_raw_uplink_ = 0;
  uint32_t last_raw_downlink_ = 0;
  bool have_raw_counters_ = false;
  bool ras_available_ = false;
};

ZagrosTunnelPlugin::ZagrosTunnelPlugin(flutter::BinaryMessenger* messenger) {
  flutter_api_ = std::make_unique<zagros_tunnel::NativeTunnelFlutterApi>(messenger);
  state_ = std::make_unique<State>([this](const NativeTunnelStatus& status) {
    if (flutter_api_ == nullptr) return;
    flutter_api_->OnStatusChanged(status, [] {}, [](const zagros_tunnel::FlutterError&) {});
  });
}

ZagrosTunnelPlugin::~ZagrosTunnelPlugin() {
  state_.reset();
  flutter_api_.reset();
}

void ZagrosTunnelPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<ZagrosTunnelPlugin>(registrar->messenger());
  zagros_tunnel::NativeTunnelHostApi::SetUp(registrar->messenger(), plugin.get());
  registrar->AddPlugin(std::move(plugin));
}

ErrorOr<NativeTunnelCapabilities> ZagrosTunnelPlugin::GetCapabilities() {
  const bool available = state_->IsAvailable();
  ::flutter::EncodableList protocols;
  if (available) protocols.emplace_back("ikev2");
  return NativeTunnelCapabilities("windows", protocols, available, available,
                                  UnavailableReasons(available));
}

ErrorOr<NativeTunnelStatus> ZagrosTunnelPlugin::GetStatus() {
  return state_->GetStatus();
}

void ZagrosTunnelPlugin::Connect(const NativeTunnelRequest& request,
                                 std::function<void(ErrorOr<NativeTunnelStatus>)> result) {
  if (request.white_label()) {
    const std::string code = "runtime_profile_policy";
    const std::string message = "OS-managed VPN profiles are disabled by runtime-only policy.";
    result(zagros_tunnel::FlutterError(code, message));
    return;
  }
  if (request.protocol() != "ikev2" || request.engine() != "system" ||
      !SafeIdentifier(request.request_id()) ||
      !SafeIdentifier(request.connection_id())) {
    const std::string code = "invalid_request";
    const std::string message = "The Windows tunnel request was rejected safely.";
    result(zagros_tunnel::FlutterError(code, message));
    return;
  }
  SystemVpnConfiguration config;
  if (!Decode(request.config_payload(), &config)) {
    const std::string code = "invalid_config";
    const std::string message = "The Windows tunnel configuration was rejected safely.";
    result(zagros_tunnel::FlutterError(code, message));
    return;
  }
  state_->BeginConnect(request, &config, std::move(result));
}

void ZagrosTunnelPlugin::Disconnect(
    const std::string& reason,
    std::function<void(ErrorOr<NativeTunnelStatus>)> result) {
  state_->BeginDisconnect(reason, std::move(result));
}

}  // namespace tunnel_interface
