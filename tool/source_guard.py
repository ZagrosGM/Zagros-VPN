#!/usr/bin/env python3
"""Fail-closed source/repository boundary checks for the shared client."""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import tarfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "apps" / "zagros_vpn"
TUNNEL = ROOT / "packages" / "tunnel_interface"

errors: list[str] = []


def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        errors.append(f"cannot read {path.relative_to(ROOT)}: {exc}")
        return ""


apps = [path for path in (ROOT / "apps").iterdir() if path.is_dir()]
require(apps == [APP], "repository must contain exactly apps/zagros_vpn")
require(not (APP / "lib" / "src" / "official").exists(), "Official source fork found")
require(
    not (APP / "lib" / "src" / "white_label").exists(),
    "White-label source fork found",
)

app_sources = "\n".join(
    text(path)
    for path in sorted((APP / "lib" / "src").rglob("*.dart"))
)
main_source = text(APP / "lib" / "main.dart")
require(
    "tunnelAdapter: NativeTunnelAdapter(" in main_source
    and "allowStructuredOsProfiles: !configuration.isWhiteLabel" in main_source
    and "tunnelAdapter: null" not in main_source,
    "composition root must inject the shared policy-aware native tunnel adapter",
)
app_source = text(APP / "lib" / "src" / "app.dart")
dependencies_source = text(APP / "lib" / "src" / "app_dependencies.dart")
require(
    "didRequestAppExit" in app_source
    and "AppLifecycleState.detached" in app_source
    and "adapter.dispose()" in dependencies_source,
    "application shutdown does not request shared tunnel-adapter teardown",
)
require(
    "ClientCapability.rawConfigPersistence" in main_source
    and "OfficialProfileRepository" in main_source,
    "Official repository composition must be guarded by SDK persistence policy",
)
require(
    "ClientCapability.rawConfigDisplay" in main_source
    and "PlatformRawConfigActions" in main_source,
    "raw actions must be conditionally composed from SDK policy",
)
require(
    "LicenseRegistry.addLicense" in main_source
    and "assets/legal/native_engine_notices.txt" in main_source
    and "showLicensePage" in app_sources
    and "openSourceLicenses" in app_sources
    and "Open-source licenses" in text(APP / "test" / "app_policy_widget_test.dart"),
    "packaged native notices are not registered, reachable, and tested",
)
require(
    "Phase 9" not in app_sources
    and "Phase 10" not in app_sources
    and "Phase 11" not in app_sources
    and "فاز ۹" not in app_sources
    and "فاز ۱۰" not in app_sources
    and "فاز ۱۱" not in app_sources,
    "shipping UI contains obsolete implementation-phase text",
)
library_source = "\n".join(
    text(path) for path in sorted((APP / "lib" / "src" / "library").rglob("*.dart"))
)
require(bool(library_source), "shared Official library presentation is missing")
for forbidden in ("parseShareUri(", "parseWireGuard(", "parseOpenVpn(", "jsonDecode("):
    require(
        forbidden not in library_source,
        f"Flutter library duplicates SDK parsing through {forbidden!r}",
    )
raw_actions_source = text(
    APP / "lib" / "src" / "platform" / "raw_config_actions.dart",
)
for capability in ("rawConfigClipboard", "rawConfigExport"):
    require(
        f"policy.require(ClientCapability.{capability})" in raw_actions_source,
        f"raw action is not guarded by {capability} policy",
    )
account_source = "\n".join(
    text(path) for path in sorted((APP / "lib" / "src" / "account").rglob("*.dart"))
)
require(bool(account_source), "shared Application account presentation is missing")
for forbidden in (
    "parseShareUri(",
    "parseWireGuard(",
    "parseOpenVpn(",
    "parseApplicationPayload(",
    "ConfigParser(",
    "CryptographicConfigEnvelopeOpener(",
    "jsonDecode(",
):
    require(
        forbidden not in account_source,
        f"Flutter account duplicates SDK parsing/crypto through {forbidden!r}",
    )

for forbidden in (
    "import 'dart:ffi'",
    "import 'dart:io'",
    "package:http/",
    "package:crypto/",
    "package:cryptography/",
    "package:sqflite/",
    "SharedPreferences",
    "FirebaseAnalytics",
    "FirebaseCrashlytics",
    "implements TunnelAdapter",
):
    require(forbidden not in app_sources, f"application boundary contains {forbidden!r}")

storage_source = text(APP / "lib" / "src" / "storage" / "secure_storage.dart")
for required in ("resetOnError: false", "migrateWithBackup: true"):
    require(required in storage_source, f"secure-storage hardening missing {required}")
for forbidden in ("NormalizedConfig", "OpenedConfig", "configPayload"):
    require(forbidden not in storage_source, f"secure storage accepts {forbidden}")

android_build = text(APP / "android" / "app" / "build.gradle.kts")
require(
    'applicationId = "ai.zagros.vpn"' in android_build,
    "Android foundation application ID is not canonical",
)
require("minSdk = 24" in android_build, "Android minimum SDK must be explicit")
android_settings = text(APP / "android" / "settings.gradle.kts")
require(
    'id("com.android.application") version "9.1.0" apply false' in android_settings
    and 'id("org.jetbrains.kotlin.android")' not in android_settings
    and 'id("org.jetbrains.kotlin.android")' not in android_build
    and "AGP 9 provides built-in Kotlin" in android_build,
    "Android app must use AGP 9.1 built-in Kotlin without the obsolete plugin",
)
require(
    'signingConfigs.getByName("debug")' not in android_build,
    "Android release build must never fall back to a debug signing key",
)
wrapper_script = APP / "android" / "gradlew"
require(
    wrapper_script.is_file() and os.access(wrapper_script, os.X_OK),
    "Android Gradle wrapper script is not executable",
)
wrapper = APP / "android" / "gradle" / "wrapper" / "gradle-wrapper.jar"
require(
    hashlib.sha256(wrapper.read_bytes()).hexdigest()
    == "b3a875ddc1f044746e1b1a55f645584505f4a10438c1afea9f15e92a7c42ec13",
    "Gradle 9.3.1 wrapper JAR checksum mismatch",
)
require(
    "Apache License" in text(ROOT / "third_party" / "gradle-wrapper" / "LICENSE"),
    "vendored Gradle wrapper license is missing",
)
wrapper_properties = text(
    APP / "android" / "gradle" / "wrapper" / "gradle-wrapper.properties",
)
require(
    "distributionSha256Sum=b266d5ff6b90eada6dc3b20cb090e3731302e553a27c5d3e4df1f0d76beaff06"
    in wrapper_properties,
    "Gradle 9.3.1 distribution checksum is not pinned",
)

manifest = text(APP / "android" / "app" / "src" / "main" / "AndroidManifest.xml")
for required in (
    'android.permission.INTERNET',
    'android:allowBackup="false"',
    'android:fullBackupContent="false"',
    'android:usesCleartextTraffic="false"',
    'android:dataExtractionRules="@xml/data_extraction_rules"',
):
    require(required in manifest, f"Android hardening missing {required}")

for relative in (
    "ios/Runner/DebugProfile.entitlements",
    "ios/Runner/Release.entitlements",
    "macos/Runner/DebugProfile.entitlements",
    "macos/Runner/Release.entitlements",
):
    entitlement = text(APP / relative)
    require(
        "keychain-access-groups" in entitlement
        and "$(AppIdentifierPrefix)ai.zagros.vpn" in entitlement,
        f"app-scoped Keychain Sharing entitlement missing from {relative}",
    )
    require(
        "com.apple.developer.networking.vpn.api" in entitlement
        and "allow-vpn" in entitlement,
        f"Personal VPN entitlement missing from {relative}",
    )
    if relative.startswith("macos/"):
        require(
            "com.apple.security.files.downloads.read-write" in entitlement,
            f"explicit config-export entitlement missing from {relative}",
        )

require(
    "CODE_SIGN_ENTITLEMENTS = Runner/DebugProfile.entitlements;"
    in text(APP / "ios" / "Runner.xcodeproj" / "project.pbxproj"),
    "iOS Debug entitlement file is not wired to Runner",
)
require(
    "CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements;"
    in text(APP / "ios" / "Runner.xcodeproj" / "project.pbxproj"),
    "iOS Release entitlement file is not wired to Runner",
)

gitignore = text(ROOT / ".gitignore")
for ignored_secret in (
    "**/android/local.properties",
    "**/android/key.properties",
    "**/*.jks",
    "**/*.keystore",
    "**/*.p12",
    "**/*.pfx",
    "**/*.mobileprovision",
    ".env.*",
):
    require(
        ignored_secret in gitignore,
        f"secret-bearing local artifact is not ignored: {ignored_secret}",
    )

secret_patterns = {
    "private key block": re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
    "GitHub token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"),
    "Bearer token": re.compile(r"\bBearer\s+[A-Za-z0-9._~+/-]{24,}={0,2}\b", re.I),
}
scan_suffixes = {
    ".arb",
    ".bat",
    ".cc",
    ".cmake",
    ".cpp",
    ".dart",
    ".gradle",
    ".h",
    ".java",
    ".json",
    ".kt",
    ".kts",
    ".md",
    ".pbxproj",
    ".plist",
    ".pom",
    ".properties",
    ".rc",
    ".sh",
    ".storyboard",
    ".swift",
    ".txt",
    ".xcconfig",
    ".xib",
    ".xml",
    ".yaml",
    ".yml",
}
excluded_directories = {
    ".dart_tool",
    ".git",
    ".idea",
    "build",
    "coverage",
    "ephemeral",
}
for path in sorted(ROOT.rglob("*")):
    if not path.is_file() or excluded_directories.intersection(path.parts):
        continue
    if path.suffix not in scan_suffixes and path.name not in {
        "NOTICE",
        "LICENSE",
        "gradlew",
    }:
        continue
    source = text(path)
    for label, pattern in secret_patterns.items():
        require(not pattern.search(source), f"possible {label} in {path.relative_to(ROOT)}")

license_path = ROOT / "LICENSE"
license_digest = hashlib.sha256(license_path.read_bytes()).hexdigest()
require(
    license_digest == "675ba92d024629e9082b56f4de23518c074a6931c9c564075b3650f5f0891cbb",
    "root LICENSE is not the verbatim Zagros Commercial License text",
)
require(
    text(TUNNEL / "LICENSE") == text(license_path),
    "tunnel_interface license must match the repository Commercial license",
)
workflow = text(ROOT / ".github" / "workflows" / "client-checks.yml")
require(
    not re.search(r"\buses:\s*[^\s]+@(?:main|master|v\d+)\s*(?:#.*)?$", workflow, re.M),
    "CI actions must be pinned to immutable commit SHAs",
)
require(
    "repository: ZagrosGM/Zagros-VPN-SDK" in workflow,
    "CI must resolve the independent SDK sibling",
)
require(
    (TUNNEL / "lib" / "src" / "generated" / "tunnel_api.g.dart").is_file(),
    "generated Pigeon Dart contract is missing",
)
native_facade = text(TUNNEL / "lib" / "src" / "native_tunnel_adapter.dart")
native_encoder = text(TUNNEL / "lib" / "src" / "runtime_config_encoder.dart")
native_facade_tests = text(TUNNEL / "test" / "native_tunnel_adapter_test.dart")
require(
    "protocol_engine_mismatch" in native_facade
    and "encoder rejects a protocol-engine mismatch" in native_facade_tests
    and "facade rejects a protocol-engine mismatch" in native_facade_tests,
    "Dart protocol-engine mismatch validation or tests are missing",
)
require(
    "endpoint.port != 500" in native_encoder
    and "system IKEv2 encoder rejects unsupported custom ports"
    in native_facade_tests,
    "system IKEv2 custom-port validation or test is missing",
)

native_files = {
    "Android": TUNNEL / "android" / "src" / "main" / "kotlin" / "ai" / "zagros" / "tunnel" / "ZagrosTunnelPlugin.kt",
    "Apple": TUNNEL / "darwin" / "Classes" / "ZagrosTunnelPlugin.swift",
    "Linux": TUNNEL / "linux" / "tunnel_interface_plugin.cc",
    "Windows": TUNNEL / "windows" / "tunnel_interface_plugin.cpp",
}
for platform, path in native_files.items():
    require(path.is_file(), f"{platform} native tunnel adapter source is missing")
    source = text(path)
    for protocol in (
        "openvpn",
        "ovpn",
        "xray",
        "sing-box",
        "vless",
        "vmess",
        "trojan",
        "shadowsocks",
        "hysteria2",
        "tuic",
        "anytls",
        "socks",
        "http",
        "https",
        "softether",
        "ssh",
        "pptp",
        "l2tp",
        "l2tp+ipsec",
    ):
        require(
            f'"{protocol}"' in source,
            f"{platform} capability source omits an explicit {protocol} decision",
        )

plugin_pubspec = text(TUNNEL / "pubspec.yaml")
for platform in ("android", "ios", "macos", "linux", "windows"):
    require(
        re.search(rf"^\s{{6}}{platform}:\s*$", plugin_pubspec, re.M) is not None,
        f"{platform} plugin registration is missing",
    )

android_plugin = text(native_files["Android"])
android_plugin_build = text(TUNNEL / "android" / "build.gradle.kts")
android_plugin_settings = text(TUNNEL / "android" / "settings.gradle.kts")
require(
    'id("com.android.library") version "9.1.0" apply false'
    in android_plugin_settings
    and 'id("org.jetbrains.kotlin.android")' not in android_plugin_build
    and 'url = uri("../../../third_party/maven")' in android_plugin_settings
    and 'includeGroup("ai.zagros.thirdparty")' in android_plugin_settings
    and "import java.security.MessageDigest" in android_plugin_build,
    "standalone Android plugin must pin AGP built-in Kotlin and its exclusive local Maven input",
)
wireguard_artifacts = {
    "tunnel-1.0.20260102.module": "7d026b7e4dd40665347eb682a7651751cdb0b75d2d6b235644384c7ad377e567",
    "tunnel-1.0.20260102.pom": "29bd0e7f2ddc1f0cce137fe17b8e5f1a16e4678cdad23acf67152581b3ae965f",
    "tunnel-1.0.20260102-sources.jar": "914dfe55d9bcb2a251048086555a31d7707ff78b6a2093304b2439f63c0dc012",
}
wireguard_root = ROOT / "third_party" / "wireguard-android"
for artifact_name, expected_digest in wireguard_artifacts.items():
    artifact = wireguard_root / artifact_name
    require(artifact.is_file(), f"Pinned WireGuard Android artifact is missing: {artifact_name}")
    if artifact.is_file():
        require(
            hashlib.sha256(artifact.read_bytes()).hexdigest() == expected_digest,
            f"Pinned WireGuard Android artifact digest mismatch: {artifact_name}",
        )
require(
    not any(ROOT.rglob("tunnel-1.0.20260102.aar")),
    "unmodified upstream AAR with GPL wireguard-tools binaries must not be vendored",
)
wireguard_sha256 = "b8a8c73b701b4f6bd6baf99ae4251f8c90973ccf5b1c6201725f59b39c603931"
upstream_wireguard_sha256 = (
    "2b9c16db026496123e4db695d26d03d1958a201096c7c4c89b21077dc70f3119"
)
wireguard_maven_version = (
    ROOT
    / "third_party"
    / "maven"
    / "ai"
    / "zagros"
    / "thirdparty"
    / "wireguard-tunnel-go-only"
    / "1.0.20260102"
)
derived_wireguard_aar = (
    wireguard_maven_version / "wireguard-tunnel-go-only-1.0.20260102.aar"
)
derived_wireguard_pom = (
    wireguard_maven_version / "wireguard-tunnel-go-only-1.0.20260102.pom"
)
require(
    derived_wireguard_aar.is_file()
    and hashlib.sha256(derived_wireguard_aar.read_bytes()).hexdigest()
    == wireguard_sha256,
    "Pinned WireGuard GoBackend-only Maven AAR is missing or modified",
)
require(
    derived_wireguard_pom.is_file()
    and hashlib.sha256(derived_wireguard_pom.read_bytes()).hexdigest()
    == "b62d9e384476e7a80b59c6582da9806e9bd20c79f8f5df7af8d4e0dd671cd4bc",
    "Pinned WireGuard GoBackend-only Maven POM is missing or modified",
)
wireguard_preparer = text(ROOT / "tool" / "prepare_wireguard_android.py")
require(
    upstream_wireguard_sha256 in wireguard_preparer
    and wireguard_sha256 in wireguard_preparer
    and 'EXCLUDED_NAMES = {"libwg.so", "libwg-quick.so"}' in wireguard_preparer,
    "WireGuard GoBackend-only AAR derivation is not fully hash locked",
)
wireguard_go_license = ROOT / "third_party" / "wireguard-go" / "LICENSE-MIT"
require(
    wireguard_go_license.is_file()
    and hashlib.sha256(wireguard_go_license.read_bytes()).hexdigest()
    == "91276db973f25602d1aa43491f59cbc84cb88e6f151e1d0cc82a755563ce0195",
    "pinned wireguard-go MIT license copy is missing or modified",
)
wireguard_go_module_lock = ROOT / "third_party" / "wireguard-go" / "module-lock.json"
require(wireguard_go_module_lock.is_file(), "wireguard-go module checksum lock is missing")
go_lock: dict[str, object] = {}
source_license_lock: dict[str, object] = {}
go_toolchain_lock: dict[str, object] = {}
android_ndk_lock: dict[str, object] = {}
if wireguard_go_module_lock.is_file():
    go_lock = json.loads(wireguard_go_module_lock.read_text(encoding="utf-8"))
    require(
        len(go_lock.get("modules", [])) == 8
        and all(module.get("go_sum", "").startswith("h1:") for module in go_lock["modules"])
        and str(go_lock.get("license_review_status", "")).startswith("PARTIAL:")
        and go_lock.get("android_reachable_package_report")
        == "third_party/wireguard-go/android-reachable-packages.json"
        and go_lock.get("native_reproduction_report")
        == "third_party/wireguard-go/native-reproduction.json"
        and go_lock.get("source_license_lock")
        == "third_party/wireguard-go/source-license-lock.json"
        and go_lock.get("android_build_source_lock")
        == "third_party/wireguard-go/android-build-source/lock.json"
        and go_lock.get("go_toolchain_notice_lock")
        == "third_party/wireguard-go/go-toolchain-licenses/lock.json"
        and go_lock.get("android_ndk_notice_lock")
        == "third_party/wireguard-go/android-ndk-r27-notices/lock.json",
        "wireguard-go module lock is incomplete or overstates acceptance",
    )
    source_license_path = ROOT / str(go_lock.get("source_license_lock", "missing"))
    require(source_license_path.is_file(), "Go module source-license lock is missing")
    if source_license_path.is_file():
        source_license_lock = json.loads(source_license_path.read_text())
        require(
            len(source_license_lock.get("modules", [])) == 8
            and [
                (item["module"], item["version"], item["go_sum"])
                for item in source_license_lock["modules"]
            ] == [
                (item["module"], item["version"], item["go_sum"])
                for item in go_lock["modules"]
            ],
            "Go module source-license lock does not match module lock",
        )
        for module in source_license_lock.get("modules", []):
            require(module.get("license_notice_files"), f"Go module notice set is empty: {module.get('module')}")
            for item in module.get("license_notice_files", []):
                captured = ROOT / item["path"]
                require(
                    captured.is_file()
                    and captured.stat().st_size == item["size"]
                    and hashlib.sha256(captured.read_bytes()).hexdigest() == item["sha256"],
                    f"Go module license mismatch: {item['path']}",
                )
    build_source_path = ROOT / str(go_lock.get("android_build_source_lock", "missing"))
    require(build_source_path.is_file(), "Android libwg-go build-source lock is missing")
    if build_source_path.is_file():
        build_source = json.loads(build_source_path.read_text())
        require(
            build_source.get("tag_object") == "3831cab2da844319291459308a6e535d36dde4b3"
            and build_source.get("commit") == "09b75c2bd37f749e2a8c85876394854113c74be7"
            and len(build_source.get("files", [])) == 6,
            "Android libwg-go build-source lock metadata mismatch",
        )
        source_archive = wireguard_root / "wireguard-android-1.0.20260102-source.tar.gz"
        require(
            source_archive.is_file()
            and source_archive.stat().st_size == 424849
            and hashlib.sha256(source_archive.read_bytes()).hexdigest()
            == "0d12c37fabf73fe88983e779c077aaad55ff62ea5749bad89ec1a27c60d7ade3",
            "WireGuard parent-tag source snapshot is missing or modified",
        )
        if source_archive.is_file():
            with tarfile.open(source_archive, "r:gz") as archive:
                prefix = "wireguard-android-1.0.20260102/tunnel/tools/libwg-go/"
                for item in build_source.get("files", []):
                    captured = ROOT / item["path"]
                    member = archive.extractfile(prefix + item["name"])
                    archive_content = member.read() if member is not None else b""
                    require(
                        captured.is_file()
                        and captured.stat().st_size == item["size"]
                        and hashlib.sha256(captured.read_bytes()).hexdigest() == item["sha256"]
                        and archive_content == captured.read_bytes(),
                        f"Android build source/snapshot mismatch: {item['name']}",
                    )
    toolchain_path = ROOT / str(go_lock.get("go_toolchain_notice_lock", "missing"))
    require(toolchain_path.is_file(), "Go toolchain notice lock is missing")
    if toolchain_path.is_file():
        go_toolchain_lock = json.loads(toolchain_path.read_text())
        require(
            go_toolchain_lock.get("go_version") == "1.24.3"
            and go_toolchain_lock.get("tarball_size") == 78558709
            and go_toolchain_lock.get("tarball_sha256")
            == "3333f6ea53afa971e9078895eaa4ac7204a8c6b5c68c10e6bc9a33e8e391bdd8"
            and len(go_toolchain_lock.get("license_notice_files", [])) == 33,
            "Go toolchain notice lock is incomplete",
        )
        for item in go_toolchain_lock.get("license_notice_files", []):
            captured = ROOT / item["path"]
            require(
                captured.is_file()
                and captured.stat().st_size == item["size"]
                and hashlib.sha256(captured.read_bytes()).hexdigest() == item["sha256"],
                f"Go toolchain notice mismatch: {item['path']}",
            )
    ndk_path = ROOT / str(go_lock.get("android_ndk_notice_lock", "missing"))
    require(ndk_path.is_file(), "Android NDK notice lock is missing")
    if ndk_path.is_file():
        android_ndk_lock = json.loads(ndk_path.read_text())
        require(
            android_ndk_lock.get("ndk_version") == "27.0.12077973"
            and android_ndk_lock.get("archive_size") == 663957918
            and android_ndk_lock.get("archive_sha256")
            == "2f17eb8bcbfdc40201c0b36e9a70826fcd2524ab7a2a235e2c71186c302da1dc"
            and len(android_ndk_lock.get("license_notice_files", [])) == 15,
            "Android NDK notice lock is incomplete",
        )
        for item in android_ndk_lock.get("license_notice_files", []):
            captured = ROOT / item["path"]
            require(
                captured.is_file()
                and captured.stat().st_size == item["size"]
                and hashlib.sha256(captured.read_bytes()).hexdigest() == item["sha256"],
                f"Android NDK notice mismatch: {item['path']}",
            )
    reachability_path = ROOT / str(go_lock.get("android_reachable_package_report", "missing"))
    require(reachability_path.is_file(), "Android Go reachability report is missing")
    if reachability_path.is_file():
        reachability = json.loads(reachability_path.read_text())
        require(
            reachability.get("abis") == ["arm64-v8a", "armeabi-v7a", "x86", "x86_64"]
            and len(reachability.get("packages", [])) == 135
            and [item["module"] for item in reachability.get("reachable_modules", [])]
            == ["golang.org/x/crypto", "golang.org/x/net", "golang.org/x/sys", "golang.zx2c4.com/wireguard"]
            and str(reachability.get("analysis_status", "")).startswith("PASS:")
            and str(reachability.get("distribution_status", "")).startswith("BLOCKED:"),
            "Android Go reachability report is incomplete or overstates distribution acceptance",
        )
    reproduction: dict[str, object] = {}
    reproduction_path = ROOT / str(go_lock.get("native_reproduction_report", "missing"))
    require(reproduction_path.is_file(), "WireGuard native reproduction report is missing")
    if reproduction_path.is_file():
        reproduction = json.loads(reproduction_path.read_text())
        outputs = reproduction.get("outputs", [])
        require(
            reproduction.get("source_archive_sha256")
            == "0d12c37fabf73fe88983e779c077aaad55ff62ea5749bad89ec1a27c60d7ade3"
            and reproduction.get("go_toolchain_sha256")
            == "3333f6ea53afa971e9078895eaa4ac7204a8c6b5c68c10e6bc9a33e8e391bdd8"
            and reproduction.get("android_ndk", {}).get("archive_sha256")
            == "2f17eb8bcbfdc40201c0b36e9a70826fcd2524ab7a2a235e2c71186c302da1dc"
            and reproduction.get("template") == "tool/wireguard_go_only_CMakeLists.txt"
            and reproduction.get("template_sha256")
            == hashlib.sha256((ROOT / "tool/wireguard_go_only_CMakeLists.txt").read_bytes()).hexdigest()
            and len(outputs) == 4
            and all(item.get("byte_identical_to_packaged_aar") is True for item in outputs)
            and str(reproduction.get("reproduction_status", "")).startswith("PASS:")
            and str(reproduction.get("distribution_status", "")).startswith("BLOCKED:"),
            "WireGuard native reproduction report is incomplete or overstates distribution acceptance",
        )
native_manifest_path = wireguard_root / "embedded-native-sha256.json"
require(native_manifest_path.is_file(), "WireGuard embedded-native digest manifest is missing")
if native_manifest_path.is_file() and derived_wireguard_aar.is_file():
    native_manifest = json.loads(native_manifest_path.read_text(encoding="utf-8"))
    with zipfile.ZipFile(derived_wireguard_aar) as archive:
        embedded = {
            name: {
                "size": len(content),
                "sha256": hashlib.sha256(content).hexdigest(),
            }
            for name in sorted(archive.namelist())
            if name.startswith("jni/") and name.endswith(".so")
            for content in (archive.read(name),)
        }
    require(
        native_manifest.get("aar_sha256") == wireguard_sha256
        and native_manifest.get("upstream_aar_sha256") == upstream_wireguard_sha256
        and native_manifest.get("excluded_upstream_native_names")
        == ["libwg-quick.so", "libwg.so"]
        and native_manifest.get("files") == embedded
        and {
            f"jni/{item['abi']}/libwg-go.so": {
                "size": item["size"],
                "sha256": item["sha256"],
            }
            for item in reproduction.get("outputs", [])
        }
        == embedded
        and {Path(name).name for name in embedded} == {"libwg-go.so"},
        "WireGuard embedded-native digest manifest does not match the GoBackend-only AAR",
    )
android_root_build = text(APP / "android" / "build.gradle.kts")
require(
    "ai.zagros.thirdparty:wireguard-tunnel-go-only:1.0.20260102"
    in android_plugin_build
    and "wireguard-tunnel-go-only-1.0.20260102.aar" in android_plugin_build
    and wireguard_sha256 in android_plugin_build
    and "exclusiveContent" in android_root_build
    and 'includeGroup("ai.zagros.thirdparty")' in android_root_build
    and 'url = uri("../../../third_party/maven")' in android_root_build,
    "Android WireGuard build does not exclusively resolve and verify the pinned Maven artifact",
)
android_app_build = text(APP / "android" / "app" / "build.gradle.kts")
require(
    '"**/libwg.so"' in android_app_build
    and '"**/libwg-quick.so"' in android_app_build,
    "Android app does not exclude unused GPL wireguard-tools native libraries",
)
for required in (
    "VpnService.prepare",
    "GoBackend",
    "latestHandshakeEpochMillis",
    "handshakeNotBeforeEpochMs",
    '"handshake_timeout"',
    '"teardown_failed"',
    "Backend callbacks may arrive on its worker thread",
    "operationMutex.isLocked",
    "activeRequest = null",
    "throw FlutterError",
    "configPayload.fill(0)",
):
    require(required in android_plugin, f"Android native lifecycle hardening missing {required}")
for forbidden in ("Log.", "println(", "printStackTrace("):
    require(forbidden not in android_plugin, f"Android adapter may log runtime data through {forbidden}")

apple_plugin = text(native_files["Apple"])
for required in (
    "NEVPNManager.shared()",
    "NEVPNStatusDidChange",
    "@MainActor",
    "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly",
    'fail("activation_timeout")',
    "guard deleteAllOwnedSecrets()",
    "stopAndRemoveOwnedConfiguration",
    "ownershipConflict",
    'return fail("ownership_conflict")',
    "Never treat an unrecognized app-scoped Personal VPN configuration",
    "request.whiteLabel",
    'rejection("runtime_profile_policy")',
    "Set(root.keys).isSubset(of: allowedKeys)",
    'root["port"] as? Int == 500',
    "throw rejection",
    "removeFromPreferences",
):
    require(required in apple_plugin, f"Apple native lifecycle hardening missing {required}")

linux_plugin = text(native_files["Linux"])
for required in (
    'g_variant_new_string("volatile")',
    'g_variant_new_string("dbus-client")',
    "OpenPrivateSystemBus",
    "CleanupOwnedNetworkManagerProfile",
    "SettingsProfileIsActive",
    "kConnectionProfileId",
    "kConnectionProfileUuid",
    'g_variant_lookup(connection, "uuid"',
    "claims_reserved_identity",
    "g_dbus_connection_close_sync",
    'start_automatic_teardown(self, "handshake_timeout")',
    "QueryActiveState",
    "respond_error_connect",
    "respond_error_disconnect",
):
    require(required in linux_plugin, f"Linux native lifecycle hardening missing {required}")
require(
    "g_bus_get_sync(G_BUS_TYPE_SYSTEM" in linux_plugin,
    "Linux capability discovery must query the system bus",
)
require(
    "g_find_program_in_path" not in linux_plugin,
    "Linux adapter must not execute an attacker-selected PATH entry for wg",
)

windows_plugin = text(native_files["Windows"])
for required in (
    "RasDialW",
    'RegisterWindowMessageW(L"RasDialEvent")',
    "kWindowNotifierType = 0xFFFFFFFF",
    "reinterpret_cast<LPVOID>(window_)",
    "HWND_MESSAGE",
    "VS_Ikev2Only",
    "RasGetConnectionStatistics",
    "FindOwnedConnection",
    "InspectOwnedPhonebookEntry",
    "Never delete a colliding foreign or unreadable phone-book entry",
    "kStartupCleanup",
    "request.white_label()",
    '"runtime_profile_policy"',
    "AllowedConfigurationKey",
    'GetNamedNumber(L"port", 0) != 500',
    "result(zagros_tunnel::FlutterError",
    "SecureZeroMemory(&parameters",
    "RasDeleteEntryW",
):
    require(required in windows_plugin, f"Windows native lifecycle hardening missing {required}")
require(
    "std::this_thread::sleep_for" not in windows_plugin,
    "Windows adapter must not block the Flutter platform thread while RAS changes state",
)

all_generated = "\n".join(
    text(path)
    for path in sorted(TUNNEL.rglob("*"))
    if path.is_file()
    and "build" not in path.parts
    and any(part.lower() == "generated" for part in path.parts)
)
for leaked in (
    "exception.toString()",
    "message: e.toString()",
    "Log.getStackTraceString(exception)",
    "Thread.callStackSymbols",
    "PigeonInternalToString(obj.config_payload)",
    "configPayload.contentToString()",
):
    require(leaked not in all_generated, f"generated Pigeon diagnostic leaks {leaked}")
require(
    all_generated.count("**redacted**") >= 6,
    "generated request diagnostics are not consistently redacted",
)
require(
    all_generated.count("Native tunnel operation failed.") >= 4,
    "generated generic native errors are not consistently sanitized",
)

runtime_lock_path = ROOT / "third_party" / "android-runtime" / "lock.json"
runtime_sbom_path = (
    ROOT / "third_party" / "android-runtime" / "android-runtime-sbom.cdx.json"
)
require(runtime_lock_path.is_file(), "Android runtime dependency lock is missing")
runtime_lock: dict[str, object] = {}
if runtime_lock_path.is_file():
    runtime_lock = json.loads(runtime_lock_path.read_text())
    require(
        runtime_lock.get("scope")
        == ["releaseRuntimeClasspath", "coreLibraryDesugaring"]
        and runtime_lock.get("resolved_with", {}).get("gradle") == "9.3.1"
        and runtime_lock.get("resolved_with", {}).get("agp") == "9.1.0"
        and runtime_lock.get("resolved_with", {}).get("agp_built_in_kotlin_stdlib")
        == "2.2.10"
        and len(runtime_lock.get("artifacts", [])) == 22
        and len(runtime_lock.get("licenses", [])) == 8
        and str(runtime_lock.get("acceptance_status", "")).startswith("BLOCKED:"),
        "Android runtime dependency lock is incomplete or overstates acceptance",
    )
    for item in runtime_lock.get("licenses", []):
        captured = ROOT / item["path"]
        require(
            captured.is_file()
            and captured.stat().st_size == item["size"]
            and hashlib.sha256(captured.read_bytes()).hexdigest() == item["sha256"],
            f"Android runtime license mismatch: {item['path']}",
        )
    source = runtime_lock.get("desugar_source_candidate", {})
    source_path = ROOT / source.get("path", "missing")
    require(
        source.get("commit") == "73170c345e6a762fc6a1f0301bb15218850023ef"
        and source.get("commit_signature") == "unsigned"
        and source.get("size") == 18251068
        and source.get("sha256")
        == "4cd2faa88ecb2450522fd4f0dcd11d6df878d7197b2276fb35532c50267f7a64"
        and source_path.is_file()
        and source_path.stat().st_size == source.get("size")
        and hashlib.sha256(source_path.read_bytes()).hexdigest() == source.get("sha256"),
        "desugar corresponding-source candidate is missing, modified, or overstated",
    )
require(runtime_sbom_path.is_file(), "Android runtime CycloneDX SBOM is missing")
if runtime_sbom_path.is_file():
    runtime_sbom = json.loads(runtime_sbom_path.read_text())
    require(
        runtime_sbom.get("bomFormat") == "CycloneDX"
        and runtime_sbom.get("specVersion") == "1.6"
        and len(runtime_sbom.get("components", [])) == 13
        and runtime_sbom.get("metadata", {}).get("properties", [])[1].get("value")
        == "BLOCKED",
        "Android runtime CycloneDX SBOM is incomplete or overstates acceptance",
    )
runtime_report = text(ROOT / "third_party" / "android-runtime-dependencies.txt")
desugar_report = text(ROOT / "third_party" / "android-desugaring-dependencies.txt")
require(
    "BUILD SUCCESSFUL" in runtime_report
    and " FAILED" not in runtime_report
    and all(
        component in runtime_report
        for component in (
            "wireguard-tunnel-go-only:1.0.20260102",
            "annotation-jvm:1.9.1",
            "collection-jvm:1.5.0",
            "kotlin-stdlib:2.2.10",
            "annotations:23.0.0",
            "kotlinx-coroutines-android:1.10.2",
            "kotlinx-coroutines-core-jvm:1.10.2",
        )
    ),
    "resolved Android runtime dependency report is missing, failed, or incomplete",
)
require(
    "BUILD SUCCESSFUL" in desugar_report
    and " FAILED" not in desugar_report
    and "desugar_jdk_libs:2.1.5" in desugar_report
    and "desugar_jdk_libs_configuration:2.1.5" in desugar_report,
    "resolved Android desugaring dependency report is missing, failed, or incomplete",
)
compile_evidence = json.loads(
    text(ROOT / "third_party" / "android-standalone-build-evidence.json")
)
compile_report_path = ROOT / "third_party" / "android-standalone-build.txt"
compile_report = text(compile_report_path)
require(
    compile_evidence.get("status") == "PASS_STANDALONE_BUILD_ONLY"
    and "BUILD SUCCESSFUL" in compile_report
    and " FAILED" not in compile_report
    and compile_evidence.get("report", {}).get("sha256")
    == hashlib.sha256(compile_report_path.read_bytes()).hexdigest(),
    "current Android standalone build evidence is missing or stale",
)
expected_compile_inputs = {
    "packages/tunnel_interface/android/build.gradle.kts",
    "packages/tunnel_interface/android/settings.gradle.kts",
    "packages/tunnel_interface/android/gradle/verification-metadata.xml",
}
expected_compile_inputs.update(
    str(path.relative_to(ROOT))
    for path in (TUNNEL / "android" / "src" / "main").rglob("*")
    if path.is_file()
)
compile_inputs = {
    entry.get("path"): entry for entry in compile_evidence.get("compiled_inputs", [])
}
require(
    set(compile_inputs) == expected_compile_inputs
    and all(
        entry.get("size") == (ROOT / path).stat().st_size
        and entry.get("sha256") == hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
        for path, entry in compile_inputs.items()
    ),
    "Android standalone build evidence does not cover the current inputs",
)
verification_metadata = text(
    TUNNEL / "android" / "gradle" / "verification-metadata.xml"
)
require(
    '<verification-metadata xmlns="https://schema.gradle.org/dependency-verification"'
    in verification_metadata
    and verification_metadata.count("<component group=") >= 300
    and all(item["sha256"] in verification_metadata for item in runtime_lock.get("artifacts", [])),
    "Gradle dependency verification metadata does not lock the Android runtime/build inputs",
)

lock_path = ROOT / "third_party" / "native-engine-lock.json"
require(lock_path.is_file(), "native engine dependency lock is missing")
if lock_path.is_file():
    native_lock = json.loads(lock_path.read_text())
    android_engine = next(
        (item for item in native_lock.get("engines", []) if item.get("platform") == "android"),
        {},
    )
    require(
        android_engine.get("tag_source_archive_sha256")
        == "0d12c37fabf73fe88983e779c077aaad55ff62ea5749bad89ec1a27c60d7ade3"
        and android_engine.get("github_tag_signature_status", {}).get("verified") is True
        and android_engine.get("wireguard_go_source_license_lock")
        == "third_party/wireguard-go/source-license-lock.json"
        and android_engine.get("wireguard_go_toolchain_notice_lock")
        == "third_party/wireguard-go/go-toolchain-licenses/lock.json"
        and android_engine.get("wireguard_android_ndk_notice_lock")
        == "third_party/wireguard-go/android-ndk-r27-notices/lock.json"
        and android_engine.get("wireguard_go_reachable_package_report")
        == "third_party/wireguard-go/android-reachable-packages.json"
        and android_engine.get("wireguard_go_native_reproduction_report")
        == "third_party/wireguard-go/native-reproduction.json"
        and android_engine.get("android_runtime_lock")
        == "third_party/android-runtime/lock.json"
        and android_engine.get("android_runtime_sbom")
        == "third_party/android-runtime/android-runtime-sbom.cdx.json"
        and android_engine.get("android_standalone_build_evidence")
        == "third_party/android-standalone-build-evidence.json"
        and android_engine.get("retained_elf_toolchain_identity", {}).get("android_ndk_version")
        == "27.0.12077973"
        and str(android_engine.get("distribution_gate", "")).startswith("BLOCKED:"),
        "native engine lock omits Android source/toolchain/runtime gates",
    )
third_party_notices = ROOT / "THIRD_PARTY_NOTICES.md"
require(third_party_notices.is_file(), "third-party notices are missing")
notice_asset = APP / "assets" / "legal" / "native_engine_notices.txt"
notice_header = (
    "ZAGROS NATIVE ENGINE THIRD-PARTY NOTICES\n"
    "Generated by tool/generate_native_notices.py. Do not edit this asset directly.\n"
    "This native-engine notice set is not yet the complete shipping dependency inventory."
)
notice_sections = [
    notice_header,
    f"REVIEW AND DISTRIBUTION STATUS\n\n{text(third_party_notices).rstrip()}",
    "WIREGUARD ANDROID JAVA/KOTLIN — APACHE LICENSE 2.0\n\n"
    + text(wireguard_root / "LICENSE-APACHE-2.0").rstrip(),
    "WIREGUARD-GO — MIT LICENSE\n\n" + text(wireguard_go_license).rstrip(),
    "SING-BOX DAEMON — GNU GPL 3.0\n\n"
    + text(ROOT / "third_party" / "singbox" / "LICENSE-GPL-3.0").rstrip(),
    "HEV-SOCKS5-TUNNEL BRIDGE — MIT LICENSE\n\n"
    + text(ROOT / "third_party" / "hev-socks5-tunnel" / "LICENSE-MIT").rstrip(),
]
for module in source_license_lock.get("modules", []):
    for item in module["license_notice_files"]:
        member = item["module_member"].rsplit("/", 1)[-1]
        notice_sections.append(
            f"GO MODULE {module['module']} {module['version']} — {member}\n\n"
            + text(ROOT / item["path"]).rstrip()
        )
for item in go_toolchain_lock.get("license_notice_files", []):
    notice_sections.append(
        f"GO {go_toolchain_lock['go_version']} TOOLCHAIN — {item['archive_member']}\n\n"
        + text(ROOT / item["path"]).rstrip()
    )
for item in runtime_lock.get("licenses", []):
    notice_sections.append(
        f"ANDROID RUNTIME — {Path(item['path']).name}\n\n"
        + text(ROOT / item["path"]).rstrip()
    )
expected_notice_asset = ("\n\n" + "=" * 78 + "\n\n").join(notice_sections) + "\n"
require(
    notice_asset.is_file()
    and text(notice_asset) == expected_notice_asset
    and "assets/legal/native_engine_notices.txt"
    in text(APP / "pubspec.yaml"),
    "packaged native-engine notice asset is missing, stale, or not declared",
)
require(
    (ROOT / "doc" / "native-adapters.md").is_file(),
    "native adapter support and validation documentation is missing",
)
ci_source = text(ROOT / ".github" / "workflows" / "client-checks.yml")
android_inspector = text(ROOT / "tool" / "inspect_android_artifact.py")
reproduction_requirements = text(
    ROOT / "tool" / "android-native-reproduction-requirements.txt"
)
require(
    "cmake==4.4.3" in reproduction_requirements
    and "bae3c4954623ec4d62e62c70443f0da7988b733111c2871fcc6a31ead5137e20"
    in reproduction_requirements
    and "ninja==1.13.2" in reproduction_requirements
    and "65a24341b5ac09fcadcc37082660be40a94174e51a937fabf6e2cae26225fa2c"
    in reproduction_requirements,
    "Android native reproduction host tools are not hash pinned",
)
require(
    "distribution blocked" in android_inspector
    and "--allow-known-gpl" not in android_inspector
    and "inspect_android_artifact.py" in ci_source
    and "prepare_wireguard_android.py" in ci_source
    and "cmp third_party/maven/" in ci_source
    and "verify_wireguard_android_source.py" in ci_source
    and "capture_wireguard_go_modules.py" in ci_source
    and "capture_wireguard_android_glue.py" in ci_source
    and "capture_go_toolchain_notices.py" in ci_source
    and "capture_android_ndk_notices.py" in ci_source
    and "capture_android_runtime_dependencies.py" in ci_source
    and "reproduce_wireguard_android_native.py" in ci_source
    and "generate_android_go_reachability.py" in ci_source
    and "android-native-reproduction-requirements.txt" in ci_source
    and "assembleDebug" in ci_source
    and "-PzagrosStandaloneCompile=true" in ci_source
    and "git diff --exit-code -- third_party" in ci_source
    and "--allow-known-gpl" not in ci_source,
    "Android derivation/final-package GPL inspection gate is missing or bypassable",
)
for target in (
    "flutter build apk",
    "flutter build ios",
    "flutter build windows",
    "flutter build macos",
    "flutter build linux",
):
    require(target in ci_source, f"CI does not compile native target through {target}")

if errors:
    for error in errors:
        print(f"SOURCE GUARD: {error}", file=sys.stderr)
    raise SystemExit(1)

print("Source guards passed.")
