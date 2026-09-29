#ifndef FLUTTER_PLUGIN_ZAGROS_TUNNEL_PLUGIN_H_
#define FLUTTER_PLUGIN_ZAGROS_TUNNEL_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

// The plugin target compiles with CXX_VISIBILITY_PRESET hidden, so the
// registrar entry point must be exported explicitly (same pattern as
// flutter_secure_storage_linux and other first-party Linux plugins).
#if defined(FLUTTER_PLUGIN_IMPL)
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

G_BEGIN_DECLS

G_DECLARE_FINAL_TYPE(ZagrosTunnelPlugin,
                     zagros_tunnel_plugin,
                     ZAGROS,
                     TUNNEL_PLUGIN,
                     GObject)

FLUTTER_PLUGIN_EXPORT void zagros_tunnel_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

G_END_DECLS

#endif  // FLUTTER_PLUGIN_ZAGROS_TUNNEL_PLUGIN_H_
