#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/packages/tunnel_interface"
flutter=${FLUTTER_BIN:-flutter}
dart=${DART_BIN:-dart}

# Tier 1 (default): the hardening contract of the checked-in generated
# outputs — toolchain-free and deterministic. The strict regenerate-and-
# byte-compare gate below (Tier 2) needs the historical generator build
# (a locally patched Pigeon that still emitted the deep-equality/toString
# data-class codegen); no public Pigeon release reproduces the checked-in
# artifacts, so CI runs Tier 1 and the full compare stays explicit.
if [[ "${ZAGROS_PIGEON_REGEN_VERIFY:-0}" != "1" ]]; then
  python3 "$ROOT/tool/verify_pigeon_hardening.py"
  exit 0
fi

TEMP="$(mktemp -d)"
GENERATED="$TEMP/tunnel_interface"
trap 'rm -rf "$TEMP"' EXIT

FILES=(
  "lib/src/generated/tunnel_api.g.dart"
  "android/src/main/kotlin/ai/zagros/tunnel/generated/TunnelApi.g.kt"
  "ios/Classes/Generated/TunnelApi.g.swift"
  "macos/Classes/Generated/TunnelApi.g.swift"
  "windows/generated/tunnel_api.g.cpp"
  "windows/include/tunnel_interface/tunnel_api.g.h"
  "linux/generated/tunnel_api.g.cc"
  "linux/include/tunnel_interface/tunnel_api.g.h"
)
for relative in "${FILES[@]}"; do
  mkdir -p "$GENERATED/$(dirname "$relative")"
done

cd "$PACKAGE"
"$flutter" pub run pigeon \
  --input pigeons/tunnel_api.dart \
  --dart_out "$GENERATED/lib/src/generated/tunnel_api.g.dart" \
  --package_name tunnel_interface \
  --kotlin_out "$GENERATED/android/src/main/kotlin/ai/zagros/tunnel/generated/TunnelApi.g.kt" \
  --kotlin_package ai.zagros.tunnel.generated \
  --swift_out "$GENERATED/ios/Classes/Generated/TunnelApi.g.swift" \
  --cpp_header_out "$GENERATED/windows/include/tunnel_interface/tunnel_api.g.h" \
  --cpp_source_out "$GENERATED/windows/generated/tunnel_api.g.cpp" \
  --cpp_namespace zagros_tunnel \
  --gobject_header_out "$GENERATED/linux/include/tunnel_interface/tunnel_api.g.h" \
  --gobject_source_out "$GENERATED/linux/generated/tunnel_api.g.cc" \
  --gobject_module zagros_tunnel
cp "$GENERATED/ios/Classes/Generated/TunnelApi.g.swift" \
  "$GENERATED/macos/Classes/Generated/TunnelApi.g.swift"
cd "$ROOT"
ZAGROS_PIGEON_PACKAGE="$GENERATED" python3 tool/harden_pigeon.py
"$dart" format "$GENERATED/lib/src/generated/tunnel_api.g.dart" >/dev/null

for relative in "${FILES[@]}"; do
  if ! cmp -s "$PACKAGE/$relative" "$GENERATED/$relative"; then
    diff -u "$PACKAGE/$relative" "$GENERATED/$relative" || true
    echo "Generated Pigeon output drifted: $relative" >&2
    exit 1
  fi
done

echo "Pigeon generated outputs and hardening are current."
