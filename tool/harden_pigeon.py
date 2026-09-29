#!/usr/bin/env python3
"""Apply deterministic secret-redaction/zeroization hardening after Pigeon."""

from __future__ import annotations

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TUNNEL = Path(
    os.environ.get("ZAGROS_PIGEON_PACKAGE", ROOT / "packages" / "tunnel_interface")
).resolve()


def replace(relative: str, old: str, new: str) -> None:
    path = TUNNEL / relative
    source = path.read_text(encoding="utf-8")
    if new and new in source:
        return
    if not new and old not in source:
        return
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"Pigeon hardening pattern count {count} in {relative}")
    path.write_text(source.replace(old, new), encoding="utf-8")


replace(
    "lib/src/generated/tunnel_api.g.dart",
    "configPayload: $configPayload, whiteLabel: $whiteLabel)",
    "configPayload: **redacted**, whiteLabel: $whiteLabel)",
)
dart_generated = TUNNEL / "lib/src/generated/tunnel_api.g.dart"
dart_source = dart_generated.read_text(encoding="utf-8")
if "native_callback_failure" not in dart_source:
    old = "PlatformException(code: 'error', message: e.toString())"
    if dart_source.count(old) != 1:
        raise SystemExit("Pigeon Dart generic error pattern drift")
    dart_generated.write_text(
        dart_source.replace(
            old,
            "PlatformException(code: 'native_callback_failure', message: 'Tunnel status callback failed.')",
        ),
        encoding="utf-8",
    )
replace(
    "android/src/main/kotlin/ai/zagros/tunnel/generated/TunnelApi.g.kt",
    "configPayload=${configPayload.contentToString()}, whiteLabel=$whiteLabel)",
    "configPayload=**redacted**, whiteLabel=$whiteLabel)",
)
for swift in (
    "ios/Classes/Generated/TunnelApi.g.swift",
    "macos/Classes/Generated/TunnelApi.g.swift",
):
    replace(
        swift,
        "configPayload: \\(String(describing: configPayload)), whiteLabel:",
        "configPayload: **redacted**, whiteLabel:",
    )
# Add a zeroizing destructor declaration because the generated class owns a
# mutable copy of the runtime payload.
# The constructor text
# is stable while the generated class has no destructor by default.
header_path = TUNNEL / "windows/include/tunnel_interface/tunnel_api.g.h"
header = header_path.read_text(encoding="utf-8")
needle = "    bool white_label);\n\n  const std::string& request_id() const;"
replacement = "    bool white_label);\n  ~NativeTunnelRequest();\n\n  const std::string& request_id() const;"
if replacement not in header:
    if header.count(needle) != 1:
        raise SystemExit("Pigeon Windows destructor declaration pattern drift")
    header_path.write_text(header.replace(needle, replacement), encoding="utf-8")
replace(
    "windows/generated/tunnel_api.g.cpp",
    "    config_payload_(config_payload),\n    white_label_(white_label) {}\n\nconst std::string& NativeTunnelRequest::request_id() const {",
    "    config_payload_(config_payload),\n    white_label_(white_label) {}\n\nNativeTunnelRequest::~NativeTunnelRequest() {\n  volatile uint8_t* secret = config_payload_.data();\n  for (size_t i = 0; i < config_payload_.size(); ++i) secret[i] = 0;\n}\n\nconst std::string& NativeTunnelRequest::request_id() const {",
)
replace(
    "windows/generated/tunnel_api.g.cpp",
    "  os << PigeonInternalToString(obj.config_payload_);",
    '  os << "**redacted**";',
)
replace(
    "linux/generated/tunnel_api.g.cc",
    "  g_clear_pointer(&self->engine, g_free);\n  G_OBJECT_CLASS(zagros_tunnel_native_tunnel_request_parent_class)->dispose(object);",
    "  g_clear_pointer(&self->engine, g_free);\n  if (self->config_payload != nullptr) {\n    volatile uint8_t* secret = self->config_payload;\n    for (size_t i = 0; i < self->config_payload_length; ++i) secret[i] = 0;\n    free(self->config_payload);\n    self->config_payload = nullptr;\n    self->config_payload_length = 0;\n  }\n  G_OBJECT_CLASS(zagros_tunnel_native_tunnel_request_parent_class)->dispose(object);",
)
linux_path = TUNNEL / "linux/generated/tunnel_api.g.cc"
linux = linux_path.read_text(encoding="utf-8")
start = '  g_string_append(str, ", config_payload: ");\n'
end = '  g_string_append(str, ", white_label: ");\n'
redacted = (
    '  g_string_append(str, ", config_payload: ");\n'
    '  g_string_append(str, "**redacted**");\n'
    '  g_string_append(str, ", white_label: ");\n'
)
if redacted not in linux:
    first = linux.find(start)
    last = linux.find(end, first + len(start))
    if first < 0 or last < 0:
        raise SystemExit("Pigeon Linux request diagnostic pattern drift")
    linux = linux[:first] + redacted + linux[last + len(end) :]
    linux_path.write_text(linux, encoding="utf-8")

# Unknown exceptions may contain config fragments, credentials, host paths, and
# stack traces. Generated fallback serialization is therefore replaced by a
# fixed error. Explicit Flutter/Pigeon errors remain the adapter's safe codes.
replace(
    "android/src/main/kotlin/ai/zagros/tunnel/generated/TunnelApi.g.kt",
    "import android.util.Log\n",
    "",
)
replace(
    "android/src/main/kotlin/ai/zagros/tunnel/generated/TunnelApi.g.kt",
    '''      listOf(
        exception.javaClass.simpleName,
        exception.toString(),
        "Cause: " + exception.cause + ", Stacktrace: " + Log.getStackTraceString(exception)
      )''',
    '''      listOf(
        "native_failure",
        "Native tunnel operation failed.",
        null
      )''',
)
for swift in (
    "ios/Classes/Generated/TunnelApi.g.swift",
    "macos/Classes/Generated/TunnelApi.g.swift",
):
    replace(
        swift,
        '''protocol NativeTunnelHostApi {
  func getCapabilities() throws -> NativeTunnelCapabilities
  func getStatus() throws -> NativeTunnelStatus
  func connect(request: NativeTunnelRequest) async throws -> NativeTunnelStatus
  func disconnect(reason: String) async throws -> NativeTunnelStatus
}''',
        '''protocol NativeTunnelHostApi {
  @MainActor func getCapabilities() throws -> NativeTunnelCapabilities
  @MainActor func getStatus() throws -> NativeTunnelStatus
  @MainActor func connect(request: NativeTunnelRequest) async throws -> NativeTunnelStatus
  @MainActor func disconnect(reason: String) async throws -> NativeTunnelStatus
}''',
    )
    replace(
        swift,
        '''      getCapabilitiesChannel.setMessageHandler { _, reply in
        do {
          let result = try api.getCapabilities()
          reply(wrapResult(result))
        } catch {
          reply(wrapError(error))
        }
      }''',
        '''      getCapabilitiesChannel.setMessageHandler { _, reply in
        Task { @MainActor in
          do {
            let result = try api.getCapabilities()
            reply(wrapResult(result))
          } catch {
            reply(wrapError(error))
          }
        }
      }''',
    )
    replace(
        swift,
        '''      getStatusChannel.setMessageHandler { _, reply in
        do {
          let result = try api.getStatus()
          reply(wrapResult(result))
        } catch {
          reply(wrapError(error))
        }
      }''',
        '''      getStatusChannel.setMessageHandler { _, reply in
        Task { @MainActor in
          do {
            let result = try api.getStatus()
            reply(wrapResult(result))
          } catch {
            reply(wrapError(error))
          }
        }
      }''',
    )
    replace(
        swift,
        '''  return [
    "\\(error)",
    "\\(Swift.type(of: error))",
    "Stacktrace: \\(Thread.callStackSymbols)",
  ]''',
        '''  return [
    "native_failure",
    "Native tunnel operation failed.",
    nil,
  ]''',
    )
replace(
    "windows/generated/tunnel_api.g.cpp",
    '''  return EncodableValue(EncodableList{
    EncodableValue(std::string(error_message)),
    EncodableValue("Error"),
    EncodableValue()
  });''',
    '''  (void)error_message;
  return EncodableValue(EncodableList{
    EncodableValue("native_failure"),
    EncodableValue("Native tunnel operation failed."),
    EncodableValue()
  });''',
)

print("Generated Pigeon secret hardening applied.")
