#ifndef FLUTTER_PLUGIN_TUNNEL_INTERFACE_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_TUNNEL_INTERFACE_PLUGIN_C_API_H_

#include <flutter_plugin_registrar.h>

#ifdef TUNNEL_INTERFACE_PLUGIN_IMPL
#define TUNNEL_INTERFACE_PLUGIN_EXPORT __declspec(dllexport)
#else
#define TUNNEL_INTERFACE_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

TUNNEL_INTERFACE_PLUGIN_EXPORT void ZagrosTunnelPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_TUNNEL_INTERFACE_PLUGIN_C_API_H_
