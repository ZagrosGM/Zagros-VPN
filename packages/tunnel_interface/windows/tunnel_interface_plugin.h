#ifndef FLUTTER_PLUGIN_TUNNEL_INTERFACE_PLUGIN_H_
#define FLUTTER_PLUGIN_TUNNEL_INTERFACE_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

#include <functional>
#include <memory>
#include <mutex>
#include <string>

#include "include/tunnel_interface/tunnel_api.g.h"

namespace tunnel_interface {

class ZagrosTunnelPlugin : public flutter::Plugin,
                           public zagros_tunnel::NativeTunnelHostApi {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit ZagrosTunnelPlugin(flutter::BinaryMessenger* messenger);
  ~ZagrosTunnelPlugin() override;

  ZagrosTunnelPlugin(const ZagrosTunnelPlugin&) = delete;
  ZagrosTunnelPlugin& operator=(const ZagrosTunnelPlugin&) = delete;

  zagros_tunnel::ErrorOr<zagros_tunnel::NativeTunnelCapabilities>
  GetCapabilities() override;
  zagros_tunnel::ErrorOr<zagros_tunnel::NativeTunnelStatus> GetStatus() override;
  void Connect(
      const zagros_tunnel::NativeTunnelRequest& request,
      std::function<void(zagros_tunnel::ErrorOr<zagros_tunnel::NativeTunnelStatus>)>
          result) override;
  void Disconnect(
      const std::string& reason,
      std::function<void(zagros_tunnel::ErrorOr<zagros_tunnel::NativeTunnelStatus>)>
          result) override;

 private:
  class State;
  std::unique_ptr<State> state_;
  std::unique_ptr<zagros_tunnel::NativeTunnelFlutterApi> flutter_api_;
};

}  // namespace tunnel_interface

#endif  // FLUTTER_PLUGIN_TUNNEL_INTERFACE_PLUGIN_H_
