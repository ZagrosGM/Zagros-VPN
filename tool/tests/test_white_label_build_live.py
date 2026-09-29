"""Live end-to-end proof for tool/white_label_build.py (real flutter build).

Opt-in: runs only with ``ZAGROS_LIVE_BUILD=1`` in the environment AND a
resolvable flutter SDK (``FLUTTER_BIN`` or ``PATH``). Otherwise skipped
with a clear reason so default test runs stay fast.

What it proves (linux/x64 + android/arm64-v8a toolchains):
  * the contract CLI (``--config/--platform/--arch/--out``) exits 0 when
    invoked worker-style (cwd outside the repo, absolute paths),
  * the staged artifact + receipt land in ``--out`` with a matching
    sha256,
  * the branding from the config JSON is baked into the compiled AOT
    library (byte scan of the shipped ``libapp.so``),
  * (android) the injected applicationId/launcher-label reach the APK
    and the throwaway injection key signs it (when SDK build-tools are
    present for aapt2/apksigner; otherwise skipped with a reason),
  * (android/aab) one ``--artifact aab`` run stages a multi-ABI bundle
    with the same branding baked in (manifest assertions stay APK-only:
    no bundletool in the sandbox to decode the bundle manifest),
  * (android) the generated brand + signing files are gone afterwards,
  * a second run into the same ``--out`` fails fast on the stale-output
    guard instead of rebuilding.

Run: ``ZAGROS_LIVE_BUILD=1 python3 -m pytest tool/tests/ -q`` from the
repo root (takes minutes per target: real ``flutter build`` runs).
The android case additionally needs ``ANDROID_SDK_ROOT``,
``JAVA_HOME`` (or keytool on PATH), and accepts the box being slow.
"""
from __future__ import annotations

import hashlib
import json
import os
import secrets
import shutil
import stat
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest

TOOL = Path(__file__).resolve().parents[1]
SCRIPT = TOOL / "white_label_build.py"

# Deliberately different from any manual-run config: the marker assertions
# below only pass if THIS run's --dart-defines reached the compiler, so a
# stale build/ directory can never fake a green test.
CONFIG = {
    "display_name": "Live Proof VPN",
    "default_locale": "fa",
    "application_api_base_url": "https://panel.example.test/api/live",
    "application_id": "application-live",
    "application_name": "LiveProof",
    "application_status": "active",
    "config_key_id": "config-key-live",
    "config_public_key": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
    "signing_key_id": "signing-key-live",
    "signing_public_key": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
    # Shared-file tolerance: the linux run below must accept (and
    # ignore) these; the android run requires and injects them.
    "android_application_id": "com.liveproof.vpn",
    "android_application_label": "Live Proof VPN",
}

# markers that must survive compilation into the shipped AOT library
BAKED_MARKERS = (
    b"Live Proof VPN",
    b"https://panel.example.test/api/live",
    b"application-live",
    b"config-key-live",
    b"signing-key-live",
)


def _flutter_available() -> bool:
    override = os.environ.get("FLUTTER_BIN", "").strip()
    if override:
        return Path(override).is_file()
    return shutil.which("flutter") is not None


def _flutter_bin() -> str:
    override = os.environ.get("FLUTTER_BIN", "").strip()
    return override or "flutter"


needs_live = pytest.mark.skipif(
    os.environ.get("ZAGROS_LIVE_BUILD") != "1" or not _flutter_available(),
    reason="live build needs ZAGROS_LIVE_BUILD=1 + a flutter SDK")


def _keytool_bin() -> str | None:
    found = shutil.which("keytool")
    if found:
        return found
    java_home = os.environ.get("JAVA_HOME", "").strip()
    if java_home:
        candidate = Path(java_home) / "bin" / "keytool"
        if candidate.is_file():
            return str(candidate)
    return None


def _sdk_build_tool(name: str) -> str | None:
    sdk = os.environ.get("ANDROID_SDK_ROOT", "").strip()
    if not sdk:
        return None
    matches = sorted(Path(sdk).glob(f"build-tools/*/{name}"))
    for match in matches:
        if match.is_file() and os.access(match, os.X_OK):
            return str(match)
    return None


@needs_live
def test_live_linux_build_end_to_end(tmp_path):
    if sys.platform != "linux":
        pytest.skip("live proof currently covers linux/x64 only")
    config_path = tmp_path / "build-config.json"
    config_path.write_text(json.dumps(CONFIG), encoding="utf-8")
    out_dir = tmp_path / "out"
    out_dir.mkdir()
    # worker-style: cwd outside the repo, absolute everything
    completed = subprocess.run(
        [sys.executable, str(SCRIPT),
         "--config", str(config_path),
         "--platform", "linux",
         "--arch", "x64",
         "--out", str(out_dir)],
        cwd=tmp_path, capture_output=True, text=True, timeout=1500)
    assert completed.returncode == 0, completed.stderr[-3000:]

    artifact = out_dir / "live-proof-vpn-linux-x64.tar.gz"
    receipt_path = out_dir / "white-label-build-receipt.json"
    assert artifact.is_file()
    assert receipt_path.is_file()

    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    assert receipt["contract"] == 1
    assert receipt["platform"] == "linux" and receipt["arch"] == "x64"
    assert receipt["product_mode"] == "white-label"
    assert receipt["app_name"] == "Live Proof VPN"
    assert "ZAGROS_APP_NAME" in receipt["defines"]
    assert receipt["flutter_version"].startswith("Flutter ")
    (record,) = receipt["artifacts"]
    assert record["name"] == artifact.name
    assert record["bytes"] == artifact.stat().st_size
    assert record["sha256"] == digest

    extract = tmp_path / "extracted"
    extract.mkdir()
    with tarfile.open(artifact, "r:gz") as archive:
        # our own just-built tarball: trust, but pin the filter explicitly
        # so Python 3.14+ keeps accepting it.
        archive.extractall(extract, filter="fully_trusted")
    top = extract / "live-proof-vpn-linux-x64"
    binary = top / "zagros_vpn"
    assert binary.is_file()
    assert binary.stat().st_mode & stat.S_IXUSR  # exec bit survived
    aot = top / "lib" / "libapp.so"
    assert aot.is_file()
    blob = aot.read_bytes()
    for marker in BAKED_MARKERS:
        assert marker in blob, marker  # branding baked into the binary

    # second run into the same --out must refuse BEFORE rebuilding
    rerun = subprocess.run(
        [sys.executable, str(SCRIPT),
         "--config", str(config_path),
         "--platform", "linux",
         "--arch", "x64",
         "--out", str(out_dir)],
        cwd=tmp_path, capture_output=True, text=True, timeout=300)
    assert rerun.returncode != 0
    assert "stale --out" in rerun.stderr


@needs_live
def test_live_lone_checkout_replays_sdk_failure_and_fix(tmp_path):
    # Phase 14 proof: a worker that cloned only the app repo used to die
    # inside `pub get`; the v2 layout (pinned SDK sibling) resolves.
    # No full rebuild here (2 GB sandboxes OOM on cold AOT) — `pub get`
    # is the exact historical failure point, and compilation itself was
    # proven by the test above.
    client_root = TOOL.parent
    sdk_root = client_root.parent / "Zagros-VPN-SDK"
    if not (sdk_root / "pubspec.yaml").is_file():
        pytest.skip("sibling Zagros-VPN-SDK checkout not present")
    lone = tmp_path / "lone"
    app_copy = lone / "Zagros-VPN"
    shutil.copytree(
        client_root, app_copy,
        ignore=shutil.ignore_patterns(
            "build", ".dart_tool", "__pycache__", ".git"))
    lone_script = app_copy / "tool" / "white_label_build.py"
    config_path = tmp_path / "build-config.json"
    config_path.write_text(json.dumps(CONFIG), encoding="utf-8")
    out_dir = tmp_path / "out"
    out_dir.mkdir()

    # 1. lone app checkout: fail fast with the actionable message
    # (before any flutter step runs)
    lone_run = subprocess.run(
        [sys.executable, str(lone_script),
         "--config", str(config_path),
         "--platform", "linux",
         "--arch", "x64",
         "--out", str(out_dir)],
        cwd=lone, capture_output=True, text=True, timeout=300)
    assert lone_run.returncode == 1
    assert "missing SDK" in lone_run.stderr

    # 2. place the SDK sibling (what the v2 worker clones): the script
    # now proceeds past the preflight — proven by reaching config
    # validation (exit 2) with a deliberately invalid config
    shutil.copytree(sdk_root, lone / "Zagros-VPN-SDK")
    bad_config = tmp_path / "bad-config.json"
    bad_config.write_text("{}", encoding="utf-8")
    past_preflight = subprocess.run(
        [sys.executable, str(lone_script),
         "--config", str(bad_config),
         "--platform", "linux",
         "--arch", "x64",
         "--out", str(out_dir)],
        cwd=lone, capture_output=True, text=True, timeout=300)
    assert past_preflight.returncode == 2
    assert "config error" in past_preflight.stderr

    # 3. the real dependency resolution succeeds in the v2 layout
    pub_cache = tmp_path / "pub-cache"
    pub_cache.mkdir()
    env = {**os.environ, "PUB_CACHE": str(pub_cache)}
    pub_get = subprocess.run(
        [_flutter_bin(), "pub", "get"],
        cwd=app_copy / "apps" / "zagros_vpn", env=env,
        capture_output=True, text=True, timeout=900)
    assert pub_get.returncode == 0, pub_get.stderr[-2000:]
    # workspace root owns the resolution (root pubspec.yaml is a Dart
    # workspace over apps/zagros_vpn + packages/tunnel_interface)
    package_config = app_copy / ".dart_tool" / "package_config.json"
    assert package_config.is_file()
    assert "Zagros-VPN-SDK" in package_config.read_text(encoding="utf-8")


@needs_live
def test_live_android_build_end_to_end(tmp_path):
    if sys.platform != "linux":
        pytest.skip("live proof currently covers linux-hosted builds only")
    keytool = _keytool_bin()
    if keytool is None:
        pytest.skip("live android proof needs a JDK keytool")
    android_sdk = os.environ.get("ANDROID_SDK_ROOT", "").strip()
    if not android_sdk or not Path(android_sdk).is_dir():
        pytest.skip("live android proof needs ANDROID_SDK_ROOT")
    client_root = TOOL.parent
    android_dir = client_root / "apps" / "zagros_vpn" / "android"
    key_properties = android_dir / "key.properties"
    brand_file = android_dir / "zagros-brand.properties"
    if key_properties.exists() or brand_file.exists():
        pytest.skip("android tree has leftover injection files; "
                    "remove key.properties/zagros-brand.properties first")

    config_path = tmp_path / "build-config.json"
    config_path.write_text(json.dumps(CONFIG), encoding="utf-8")
    out_dir = tmp_path / "out"
    out_dir.mkdir()

    # Throwaway 30-day key, generated for this run only; the release
    # signing injection point (android/key.properties) carries it, and
    # both are deleted afterwards.
    keystore = tmp_path / "live-test.jks"
    # Random per run: no password literal in source, nothing to leak.
    store_pass = secrets.token_hex(16)
    keygen = subprocess.run(
        [keytool, "-genkeypair", "-keystore", str(keystore),
         "-alias", "livetest", "-keyalg", "RSA", "-keysize", "2048",
         "-validity", "30", "-storepass", store_pass,
         "-keypass", store_pass,
         "-dname", "CN=Live Test Only, OU=Test, O=Zagros"],
        capture_output=True, text=True, timeout=120)
    assert keygen.returncode == 0, keygen.stderr[-1000:]
    key_properties.write_text(
        f"storeFile={keystore}\nstorePassword={store_pass}\n"
        f"keyAlias=livetest\nkeyPassword={store_pass}\n",
        encoding="utf-8")
    try:
        # worker-style: cwd outside the repo, absolute everything
        completed = subprocess.run(
            [sys.executable, str(SCRIPT),
             "--config", str(config_path),
             "--platform", "android",
             "--arch", "arm64-v8a",
             "--out", str(out_dir)],
            cwd=tmp_path, capture_output=True, text=True, timeout=2700)
        assert completed.returncode == 0, completed.stderr[-3000:]

        artifact = out_dir / "live-proof-vpn-arm64-v8a.apk"
        receipt_path = out_dir / "white-label-build-receipt.json"
        assert artifact.is_file()
        assert receipt_path.is_file()

        digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        assert receipt["contract"] == 1
        assert receipt["platform"] == "android"
        assert receipt["arch"] == "arm64-v8a"
        assert receipt["product_mode"] == "white-label"
        assert receipt["app_name"] == "Live Proof VPN"
        assert "ZAGROS_APP_NAME" in receipt["defines"]
        assert "ANDROID" not in " ".join(receipt["defines"])
        assert receipt["flutter_version"].startswith("Flutter ")
        (record,) = receipt["artifacts"]
        assert record["name"] == artifact.name
        assert record["bytes"] == artifact.stat().st_size
        assert record["sha256"] == digest

        import zipfile as _zipfile
        with _zipfile.ZipFile(artifact) as archive:
            names = archive.namelist()
        abis = sorted({name.split("/")[1] for name in names
                       if name.startswith("lib/")
                       and len(name.split("/")) > 2})
        assert abis == ["arm64-v8a"]  # single-ABI split, nothing else
        assert not any(name.endswith("/libwg.so") for name in names)
        assert not any("libwg-quick" in name for name in names)
        with _zipfile.ZipFile(artifact) as archive:
            blob = archive.read("lib/arm64-v8a/libapp.so")
        for marker in BAKED_MARKERS:
            assert marker in blob, marker  # branding baked into the binary

        # Injection E2E: only when SDK build-tools are around to decode
        # the binary manifest / signature (best-effort elsewhere).
        aapt2 = _sdk_build_tool("aapt2")
        if aapt2 is None:
            pytest.skip("aapt2 not found under ANDROID_SDK_ROOT; "
                        "manifest assertions skipped")
        badging = subprocess.run(
            [aapt2, "dump", "badging", str(artifact)],
            capture_output=True, text=True, timeout=120)
        assert badging.returncode == 0, badging.stderr[-1000:]
        assert "package: name='com.liveproof.vpn'" in badging.stdout
        assert "application: label='Live Proof VPN'" in badging.stdout
        apksigner = _sdk_build_tool("apksigner")
        if apksigner is None:
            pytest.skip("apksigner not found under ANDROID_SDK_ROOT; "
                        "signer assertion skipped")
        verify = subprocess.run(
            [apksigner, "verify", "--print-certs", str(artifact)],
            capture_output=True, text=True, timeout=120)
        assert verify.returncode == 0, verify.stderr[-1000:]
        assert "CN=Live Test Only" in verify.stdout

        # second run into the same --out must refuse BEFORE rebuilding
        rerun = subprocess.run(
            [sys.executable, str(SCRIPT),
             "--config", str(config_path),
             "--platform", "android",
             "--arch", "arm64-v8a",
             "--out", str(out_dir)],
            cwd=tmp_path, capture_output=True, text=True, timeout=300)
        assert rerun.returncode != 0
        assert "stale --out" in rerun.stderr

        # AAB leg (Phase 17): same keystore/config, one multi-ABI
        # bundle. Manifest assertions stay APK-only (no bundletool
        # here); the injection path is shared code, badging-verified
        # above.
        out_aab = tmp_path / "out-aab"
        out_aab.mkdir()
        bundle_run = subprocess.run(
            [sys.executable, str(SCRIPT),
             "--config", str(config_path),
             "--platform", "android",
             "--arch", "arm64-v8a",
             "--artifact", "aab",
             "--out", str(out_aab)],
            cwd=tmp_path, capture_output=True, text=True, timeout=2700)
        assert bundle_run.returncode == 0, bundle_run.stderr[-3000:]
        bundle = out_aab / "live-proof-vpn-arm64-v8a.aab"
        bundle_receipt = out_aab / "white-label-build-receipt.json"
        assert bundle.is_file()
        assert bundle_receipt.is_file()
        bundle_record = json.loads(
            bundle_receipt.read_text(encoding="utf-8"))["artifacts"]
        assert [entry["name"] for entry in bundle_record] == [bundle.name]
        with _zipfile.ZipFile(bundle) as archive:
            bundle_names = archive.namelist()
        bundle_abis = sorted({name.split("/")[2]
                              for name in bundle_names
                              if name.startswith("base/lib/")
                              and len(name.split("/")) > 3})
        assert bundle_abis == ["arm64-v8a", "armeabi-v7a", "x86_64"]
        assert not any(name.endswith("/libwg.so")
                       for name in bundle_names)
        with _zipfile.ZipFile(bundle) as archive:
            bundle_blob = archive.read("base/lib/arm64-v8a/libapp.so")
        for marker in BAKED_MARKERS:
            assert marker in bundle_blob, marker
    finally:
        try:
            key_properties.unlink(missing_ok=True)
        except OSError:
            pass

    # the contract script must leave no injection residue behind
    assert not brand_file.exists()
    assert not key_properties.exists()
