cmake_minimum_required(VERSION 3.13)

set(PROJECT_NAME "tunnel_interface")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "tunnel_interface_plugin")

add_library(${PLUGIN_NAME} SHARED
  "tunnel_interface_plugin.cc"
  "network_manager_settings.cc"
  "wireguard_config.cc"
  "generated/tunnel_api.g.cc"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/include/tunnel_interface")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter PkgConfig::GTK)

set(tunnel_interface_bundled_libraries
  ""
  PARENT_SCOPE
)
