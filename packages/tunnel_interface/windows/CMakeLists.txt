cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "tunnel_interface")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "tunnel_interface_plugin")

add_library(${PLUGIN_NAME} SHARED
  "tunnel_interface_plugin.cpp"
  "tunnel_interface_plugin_c_api.cpp"
  "generated/tunnel_api.g.cpp"
)

apply_standard_settings(${PLUGIN_NAME})
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)
target_compile_definitions(${PLUGIN_NAME} PRIVATE
  FLUTTER_PLUGIN_IMPL
  _WIN32_WINNT=0x0A00
  UNICODE
  _UNICODE
  WIN32_LEAN_AND_MEAN
)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/include/tunnel_interface"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  rasapi32
  windowsapp
)

set(tunnel_interface_bundled_libraries
  ""
  PARENT_SCOPE
)
