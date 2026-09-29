#include "include/tunnel_interface/tunnel_interface_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "tunnel_interface_plugin.h"

void ZagrosTunnelPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  tunnel_interface::ZagrosTunnelPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
