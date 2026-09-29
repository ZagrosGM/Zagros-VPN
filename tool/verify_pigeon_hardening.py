#!/usr/bin/env python3
"""Tier-1 pigeon gate: the checked-in generated outputs carry every hardening.

The strict regenerate-and-byte-compare gate in verify_pigeon_generated.sh
needs the exact historical generator build (a locally patched Pigeon that
still emitted the deep-equality/toString data-class codegen, stamped
v28.0.0). That generator is not recoverable from any public source, so a
plain CI runner cannot reproduce the artifacts. This gate instead verifies,
deterministically and toolchain-free, the SECURITY CONTRACT of every
generated file:

* Dart   — payload redacted in toString, generic error path hardened to
           native_callback_failure.
* Kotlin — Log import stripped, payload redacted, failure triple fixed to
           native_failure.
* Swift  — @MainActor protocol + Task { @MainActor } dispatch, payload
           redacted, failure triple fixed to native_failure.
* Win    — zeroizing ~NativeTunnelRequest declared + defined, redacted
           diagnostic, native_failure error list.
* Linux  — dispose() zeroizes the payload, redacted diagnostic append.

The full regen-compare stays available where the reproducing generator
exists: ZAGROS_PIGEON_REGEN_VERIFY=1 tool/verify_pigeon_generated.sh
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TUNNEL = ROOT / "packages" / "tunnel_interface"

failures: list[str] = []
checks = 0


def require(relative: str, *needles: str) -> None:
    global checks
    path = TUNNEL / relative
    checks += 1
    if not path.is_file():
        failures.append(f"missing generated file: {relative}")
        return
    source = path.read_text(encoding="utf-8")
    for needle in needles:
        if needle not in source:
            failures.append(f"{relative}: lost hardening pattern {needle!r}")


def refuse(relative: str, *needles: str) -> None:
    global checks
    path = TUNNEL / relative
    checks += 1
    if not path.is_file():
        failures.append(f"missing generated file: {relative}")
        return
    source = path.read_text(encoding="utf-8")
    for needle in needles:
        if needle in source:
            failures.append(f"{relative}: unhardened pattern returned {needle!r}")


# --- Dart --------------------------------------------------------------- #
require(
    "lib/src/generated/tunnel_api.g.dart",
    "configPayload: **redacted**, whiteLabel: $whiteLabel)",
    "native_callback_failure",
    "'Tunnel status callback failed.'",
)
refuse(
    "lib/src/generated/tunnel_api.g.dart",
    "PlatformException(code: 'error', message: e.toString())",
)

# --- Kotlin ------------------------------------------------------------- #
K = "android/src/main/kotlin/ai/zagros/tunnel/generated/TunnelApi.g.kt"
require(K, "configPayload=**redacted**, whiteLabel=$whiteLabel)")
refuse(K, "import android.util.Log", "configPayload=${configPayload.contentToString()}")

# --- Swift (iOS + macOS copies) ----------------------------------------- #
for swift in (
    "ios/Classes/Generated/TunnelApi.g.swift",
    "macos/Classes/Generated/TunnelApi.g.swift",
):
    require(
        swift,
        "@MainActor func getCapabilities()",
        "Task { @MainActor in",
        'configPayload: **redacted**, whiteLabel:',
        '"native_failure",',
    )
    refuse(swift, "configPayload: \\(String(describing: configPayload))")

# --- Windows (header + source) ------------------------------------------ #
require(
    "windows/include/tunnel_interface/tunnel_api.g.h",
    "~NativeTunnelRequest();",
)
require(
    "windows/generated/tunnel_api.g.cpp",
    "NativeTunnelRequest::~NativeTunnelRequest() {",
    "volatile uint8_t* secret = config_payload_.data();",
    'os << "**redacted**";',
    'EncodableValue("native_failure"),',
)
refuse(
    "windows/generated/tunnel_api.g.cpp",
    "os << PigeonInternalToString(obj.config_payload_);",
)

# --- Linux (GObject source) ---------------------------------------------- #
require(
    "linux/generated/tunnel_api.g.cc",
    "volatile uint8_t* secret = self->config_payload;",
    'g_string_append(str, "**redacted**");',
)

if failures:
    print("Pigeon hardening contract VIOLATIONS:", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    raise SystemExit(1)
print(f"Pigeon hardening contract holds ({checks} files checked).")
