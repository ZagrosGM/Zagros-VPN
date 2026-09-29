#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
flutter=${FLUTTER_BIN:-flutter}
dart=${DART_BIN:-dart}

cd "$root"
"$flutter" pub get
(
  cd apps/zagros_vpn
  "$flutter" gen-l10n
)

./tool/verify_pigeon_generated.sh

"$dart" format --output=none --set-exit-if-changed \
  apps/zagros_vpn/lib apps/zagros_vpn/test \
  packages/tunnel_interface/lib packages/tunnel_interface/test \
  packages/tunnel_interface/pigeons
python3 tool/generate_native_notices.py --check
python3 tool/capture_wireguard_go_modules.py --verify-local
python3 tool/capture_wireguard_android_glue.py --verify-local
python3 tool/capture_go_toolchain_notices.py --verify-local
python3 tool/capture_android_ndk_notices.py --verify-local
python3 tool/capture_android_runtime_dependencies.py --verify-local
python3 tool/generate_android_go_reachability.py --verify-local
python3 tool/verify_wireguard_android_source.py --local-only
python3 tool/inspect_wireguard_elf.py \
  third_party/maven/ai/zagros/thirdparty/wireguard-tunnel-go-only/1.0.20260102/wireguard-tunnel-go-only-1.0.20260102.aar
python3 tool/source_guard.py
native_test_dir=$(mktemp -d)
trap 'rm -rf "$native_test_dir"' EXIT
cxx=${CXX:-g++}
"$cxx" -std=c++17 -Wall -Wextra -Werror -pedantic \
  packages/tunnel_interface/linux/wireguard_config.cc \
  packages/tunnel_interface/linux/test/wireguard_config_test.cc \
  -Ipackages/tunnel_interface/linux \
  -o "$native_test_dir/wireguard_config_test"
"$native_test_dir/wireguard_config_test"
# shellcheck disable=SC2046
"$cxx" -std=c++17 -Wall -Wextra -Werror -pedantic \
  packages/tunnel_interface/linux/wireguard_config.cc \
  packages/tunnel_interface/linux/network_manager_settings.cc \
  packages/tunnel_interface/linux/test/network_manager_settings_test.cc \
  -Ipackages/tunnel_interface/linux $(pkg-config --cflags --libs gio-2.0) \
  -o "$native_test_dir/network_manager_settings_test"
"$native_test_dir/network_manager_settings_test"
(
  cd packages/tunnel_interface
  "$flutter" analyze
  "$flutter" test
)
(
  cd apps/zagros_vpn
  "$flutter" analyze
  "$flutter" test
  "$flutter" test test/environment_configuration_test.dart \
    --dart-define=ZAGROS_EXPECT_PRODUCT_MODE=white-label \
    --dart-define=ZAGROS_PRODUCT_MODE=white-label \
    --dart-define=ZAGROS_APP_NAME='Partner VPN' \
    --dart-define=ZAGROS_DEFAULT_LOCALE=fa \
    --dart-define=ZAGROS_APPLICATION_API_BASE_URL=https://panel.example.test/api/application/v1 \
    --dart-define=ZAGROS_APPLICATION_ID=application-1 \
    --dart-define=ZAGROS_APPLICATION_NAME=Partner \
    --dart-define=ZAGROS_APPLICATION_STATUS=active \
    --dart-define=ZAGROS_CONFIG_KEY_ID=config-key-1 \
    --dart-define=ZAGROS_CONFIG_PUBLIC_KEY=AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE \
    --dart-define=ZAGROS_SIGNING_KEY_ID=signing-key-1 \
    --dart-define=ZAGROS_SIGNING_PUBLIC_KEY=AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI
)
