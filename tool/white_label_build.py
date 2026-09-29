#!/usr/bin/env python3
"""White-label build entry for the Zagros VPN client (job contract v1).

Invoked by the ``Zagros-VPN-Builder`` worker (never by hand in
production) as::

    python3 tool/white_label_build.py --config <build_config.json> \
        --platform <slug> --arch <slug> --out <dir>

The script validates the build config, translates it into the
compile-time ``ZAGROS_*`` dart-defines consumed by
``apps/zagros_vpn/lib/src/config/product_configuration.dart``, runs the
real ``flutter build`` for the requested target, and stages finished
release files (top level only) into ``--out`` plus a
``white-label-build-receipt.json`` provenance record.

Design rules:

* argv-only subprocesses (no shell); define *values* never echo to logs
  (names only) even though every value here is public by contract.
* Unknown config keys are rejected: a typo'd branding key must fail the
  build, never silently fall back to a default.
* Secret-shaped config keys are rejected as defense in depth (process
  listings would otherwise leak them via ``--dart-define``). The panel
  is the authority that rejects secrets first; this is the second net.
* This script always builds ``product_mode=white-label``. Official
  releases use the official release process, not this entry point.
* The SDK sibling checkout is verified before any flutter step: a lone
  app checkout fails fast with an actionable message instead of a
  cryptic ``pub get`` failure.
* Android brand keys (applicationId/label) travel in a generated
  properties file Gradle reads, never as dart-defines; the file is
  staged before the build and deleted afterwards even on failure.
* Android jobs build one artifact per run (``--artifact apk|aab``,
  default ``apk``); AAB is android-only and always the full multi-ABI
  bundle. Brand injection and receipts work identically for both.
* Exit codes: 0 success, 2 usage/config error, 1 build/staging failure.
"""
from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path

CONTRACT_VERSION = 1
PRODUCT_MODE = "white-label"

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "apps" / "zagros_vpn"

# Sibling checkout the app/package pubspecs resolve via
# ``../../../Zagros-VPN-SDK``. The v2 worker clones the pinned SDK source
# to exactly this directory; this script refuses to burn toolchain time
# when the layout is incomplete (fail fast, actionable message).
SDK_DIRNAME = "Zagros-VPN-SDK"

# platform -> arch -> flutter --target-platform (None: no flag supported)
PLATFORM_MATRIX: dict[str, dict[str, str | None]] = {
    "android": {
        "armeabi-v7a": "android-arm",
        "arm64-v8a": "android-arm64",
        "x86_64": "android-x64",
    },
    "ios": {"arm64": None},
    "linux": {"x64": None, "arm64": None},
    "windows": {"x64": None, "arm64": None},
    "macos": {"arm64": None, "x64": None},
}

# android ABI suffix used by flutter in apk file names
ANDROID_APK_ABI = {
    "armeabi-v7a": "armeabi-v7a",
    "arm64-v8a": "arm64-v8a",
    "x86_64": "x86_64",
}

# Android artifact kinds. An AAB job always builds the full multi-ABI
# bundle (flutter's default, no --target-platform flag): per-arch AABs
# would share one versionCode while Play accepts a single bundle per
# release. The job's arch still scopes queues/uploads and names the file.
ANDROID_ARTIFACTS = ("apk", "aab")

RECEIPT_NAME = "white-label-build-receipt.json"


def preflight_sdk(root: Path | None = None) -> Path:
    """Require the SDK sibling checkout; returns its path.

    The app and tunnel_interface pubspecs resolve ``zagros_vpn_sdk`` via
    ``../../../<SDK_DIRNAME>``, so a worker that cloned only the app repo
    would die inside ``pub get``. Detect that layout up front instead.
    """
    sdk = (ROOT if root is None else root).parent / SDK_DIRNAME
    if not sdk.is_dir() or not (sdk / "pubspec.yaml").is_file():
        raise BuildStepError(
            f"missing SDK checkout: {sdk} is not a usable "
            f"'{SDK_DIRNAME}' directory (the v2 worker must clone the "
            f"pinned SDK source as a sibling of the app checkout)")
    return sdk


def expected_artifact_name(platform: str, arch: str, slug: str,
                           *, artifact: str = "apk") -> str:
    """Single source of truth for staged artifact filenames."""
    if platform == "android":
        if artifact not in ANDROID_ARTIFACTS:
            raise BuildConfigError(f"unsupported artifact: {artifact!r}")
        suffix = "aab" if artifact == "aab" else "apk"
        return f"{slug}-{arch}.{suffix}"
    if platform == "ios":
        return f"{slug}.ipa"
    if platform in ("linux", "macos"):
        return f"{slug}-{platform}-{arch}.tar.gz"
    if platform == "windows":
        return f"{slug}-{platform}-{arch}.zip"
    raise BuildConfigError(f"unsupported platform: {platform!r}")  # guarded


def preflight_out_dir(out_dir: Path, artifact_name: str) -> None:
    """Refuse a stale --out BEFORE the expensive flutter build runs."""
    if not out_dir.is_dir():
        raise BuildConfigError(
            f"--out is not a directory: {out_dir} "
            f"(worker must create it first)")
    for name in (artifact_name, RECEIPT_NAME):
        if (out_dir / name).exists():
            raise BuildStepError(
                f"stale --out: {name} already exists in {out_dir} — "
                f"refusing to overwrite; use a fresh directory")
    if any(out_dir.iterdir()):
        raise BuildStepError(
            f"stale --out: {out_dir} is not empty — refusing to mix "
            f"outputs from another build; use a fresh directory")

_SECRET_KEY_FRAGMENTS = (
    "password", "passwd", "secret", "token", "private_key", "privatekey",
    "api_key", "apikey", "credential", "passphrase", "signing",
    "client_secret", "auth_key",
)

_IDENTIFIER = re.compile(r"^[A-Za-z0-9._-]{1,128}$")


class BuildConfigError(ValueError):
    pass


class BuildStepError(RuntimeError):
    pass


# --------------------------------------------------------------------- #
# config validation (mirrors product_configuration.dart, fail-fast here)
# --------------------------------------------------------------------- #

def _bounded_text(value: object, *, field: str,
                  maximum_length: int = 128) -> str:
    if not isinstance(value, str):
        raise BuildConfigError(f"config['{field}'] must be a string")
    text = value.strip()
    if not text or len(text) > maximum_length:
        raise BuildConfigError(
            f"config['{field}'] must be 1..{maximum_length} chars")
    for rune in map(ord, text):
        if rune < 0x20 or (0x7F <= rune <= 0x9F) or rune in (0x2028, 0x2029):
            raise BuildConfigError(
                f"config['{field}'] contains control characters")
    return text


def _identifier(value: object, *, field: str) -> str:
    if not isinstance(value, str) or not _IDENTIFIER.match(value.strip()):
        raise BuildConfigError(
            f"config['{field}'] must match [A-Za-z0-9._-]{{1,128}}")
    return value.strip()


def _locale(value: object) -> str:
    if not isinstance(value, str) or value.strip().lower() not in ("en", "fa"):
        raise BuildConfigError("config['default_locale'] must be en or fa")
    return value.strip().lower()


def _https_origin(value: object, *, field: str) -> str:
    from urllib.parse import urlsplit
    if not isinstance(value, str):
        raise BuildConfigError(f"config['{field}'] must be a string")
    text = value.strip()
    try:
        parsed = urlsplit(text)
    except ValueError as exc:
        raise BuildConfigError(
            f"config['{field}'] is not a URL: {exc}") from exc
    if (parsed.scheme != "https" or not parsed.hostname
            or parsed.username or parsed.password
            or parsed.query or parsed.fragment):
        raise BuildConfigError(
            f"config['{field}'] must be an HTTPS origin "
            f"(no userinfo/query/fragment)")
    return text


def _base64key32(value: object, *, field: str) -> str:
    if not isinstance(value, str):
        raise BuildConfigError(f"config['{field}'] must be a string")
    text = value.strip()
    padded = text + "=" * (-len(text) % 4)
    try:
        raw = base64.urlsafe_b64decode(padded.encode("ascii"))
    except (ValueError, UnicodeEncodeError) as exc:
        raise BuildConfigError(
            f"config['{field}'] is not base64url: {exc}") from exc
    if len(raw) != 32:
        raise BuildConfigError(
            f"config['{field}'] must decode to exactly 32 bytes")
    return text


_ANDROID_APPLICATION_ID = re.compile(
    r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$")


def _android_application_id(value: object, *, field: str) -> str:
    # Android applicationId (Play-compatible): dot-separated lowercase
    # segments, each starting with a letter. At least one dot: dotless
    # ids fail downstream (AGP/Play) with cryptic errors.
    if not isinstance(value, str):
        raise BuildConfigError(f"config['{field}'] must be a string")
    text = value.strip()
    if len(text) > 255 or not _ANDROID_APPLICATION_ID.match(text):
        raise BuildConfigError(
            f"config['{field}'] must be a dotted lowercase "
            f"applicationId (e.g. com.partner.vpn)")
    return text


def _android_label(value: object, *, field: str) -> str:
    # Launcher label: same control-char rules as display_name, capped
    # like the panel caps display_name (64).
    return _bounded_text(value, field=field, maximum_length=64)


# config key -> (dart-define, required, validator, default)
CONFIG_FIELDS = {
    "display_name": ("ZAGROS_APP_NAME", True, _bounded_text, None),
    "default_locale": ("ZAGROS_DEFAULT_LOCALE", False, _locale, "fa"),
    "application_api_base_url": (
        "ZAGROS_APPLICATION_API_BASE_URL", True, _https_origin, None),
    "application_id": ("ZAGROS_APPLICATION_ID", True, _identifier, None),
    "application_name": ("ZAGROS_APPLICATION_NAME", False, _bounded_text,
                         None),
    "application_status": (
        "ZAGROS_APPLICATION_STATUS", False, _identifier, "active"),
    "config_key_id": ("ZAGROS_CONFIG_KEY_ID", True, _identifier, None),
    "config_public_key": (
        "ZAGROS_CONFIG_PUBLIC_KEY", True, _base64key32, None),
    "signing_key_id": ("ZAGROS_SIGNING_KEY_ID", True, _identifier, None),
    "signing_public_key": (
        "ZAGROS_SIGNING_PUBLIC_KEY", True, _base64key32, None),
}

# Android-only brand keys: consumed by Gradle (applicationId + launcher
# label), NOT by Dart, so they never become --dart-define entries. They
# are allowed in every config (one shared file per partner across
# platforms) but required when --platform is android.
ANDROID_BRAND_FIELDS = {
    "android_application_id": _android_application_id,
    "android_application_label": _android_label,
}


def android_brand(config: object, *, for_android: bool) -> dict | None:
    """Validate the android brand keys.

    Returns {"applicationId":..., "label":...}, or None when both keys
    are absent (non-android builds). Exactly one key present, an
    invalid value, or absence on an android build is a config error.
    """
    if not isinstance(config, dict):
        raise BuildConfigError("build_config must be a JSON object")
    present = {key: config[key] for key in ANDROID_BRAND_FIELDS
               if key in config and config[key] is not None}
    if not present:
        if for_android:
            raise BuildConfigError(
                "config['android_application_id'] and "
                "config['android_application_label'] are required "
                "for android builds")
        return None
    if set(present) != set(ANDROID_BRAND_FIELDS):
        missing = sorted(set(ANDROID_BRAND_FIELDS) - set(present))[0]
        raise BuildConfigError(
            f"config['{missing}'] is required alongside the other "
            f"android brand key")
    return {
        "applicationId": ANDROID_BRAND_FIELDS["android_application_id"](
            present["android_application_id"],
            field="android_application_id"),
        "label": ANDROID_BRAND_FIELDS["android_application_label"](
            present["android_application_label"],
            field="android_application_label"),
    }


ANDROID_BRAND_FILENAME = "zagros-brand.properties"


def android_brand_path(app_dir: Path | None = None) -> Path:
    """Location Gradle reads (app/android/); parameterised for tests."""
    return ((APP if app_dir is None else app_dir) / "android"
            / ANDROID_BRAND_FILENAME)


def _properties_escape(value: str) -> str:
    return (value.replace("\\", "\\\\").replace("=", "\\=")
                 .replace(":", "\\:").replace("#", "\\#")
                 .replace("!", "\\!"))


def write_android_brand(brand: dict[str, str],
                        app_dir: Path | None = None) -> Path:
    """Atomically stage the brand file for one Gradle run."""
    dest = android_brand_path(app_dir)
    body = ("# Generated by tool/white_label_build.py for one android "
            "build; deleted afterwards. Do not commit.\n"
            f"applicationId={_properties_escape(brand['applicationId'])}\n"
            f"label={_properties_escape(brand['label'])}\n")
    handle, tmp_name = tempfile.mkstemp(
        prefix=".brand-", suffix=".tmp", dir=str(dest.parent))
    try:
        with open(handle, "w", encoding="utf-8") as stream:
            stream.write(body)
        Path(tmp_name).replace(dest)
    except BaseException:
        try:
            Path(tmp_name).unlink(missing_ok=True)
        except OSError:
            pass
        raise
    return dest


def clear_android_brand(app_dir: Path | None = None) -> None:
    try:
        android_brand_path(app_dir).unlink(missing_ok=True)
    except OSError:
        pass


# Launcher-icon injection (android only): the panel renders one zip pack
# with exactly these entries from the uploaded icon; the worker downloads
# it over the job-token endpoint and hands it over via --icon-pack. The
# stock files are backed up and restored around the Gradle run, exactly
# like the brand properties file above.
ANDROID_ICON_DENSITIES: tuple[tuple[str, int], ...] = (
    ("mipmap-mdpi", 48),
    ("mipmap-hdpi", 72),
    ("mipmap-xhdpi", 96),
    ("mipmap-xxhdpi", 144),
    ("mipmap-xxxhdpi", 192),
)
ANDROID_ICON_ENTRY = "ic_launcher.png"
_ANDROID_ICON_NAMES = frozenset(
    f"{density}/{ANDROID_ICON_ENTRY}"
    for density, _ in ANDROID_ICON_DENSITIES)
_PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def android_res_dir(app_dir: Path | None = None) -> Path:
    """The app's android res tree (parameterised for tests)."""
    return ((APP if app_dir is None else app_dir) / "android" / "app"
            / "src" / "main" / "res")


def read_icon_pack(pack_path: Path) -> dict[str, bytes]:
    """Validate a launcher pack; return {res-relative-name: png-bytes}.

    The pack must carry exactly the five density entries — anything
    else (extras, traversal attempts, non-PNG payloads) is a config
    error, never a silent partial staging.
    """
    try:
        with zipfile.ZipFile(pack_path) as zf:
            names = zf.namelist()
            offenders = sorted(set(names) ^ _ANDROID_ICON_NAMES)
            if offenders:
                raise BuildConfigError(
                    f"--icon-pack must carry exactly the launcher "
                    f"densities (offending entries: "
                    f"{', '.join(offenders)})")
            entries: dict[str, bytes] = {}
            for name in sorted(_ANDROID_ICON_NAMES):
                blob = zf.read(name)
                if len(blob) > 2 * 1024 * 1024:
                    raise BuildConfigError(
                        f"--icon-pack entry '{name}' exceeds 2 MiB")
                if len(blob[:8]) < 8 or blob[:8] != _PNG_MAGIC:
                    raise BuildConfigError(
                        f"--icon-pack entry '{name}' is not a PNG file")
                entries[name] = blob
    except zipfile.BadZipFile as exc:
        raise BuildConfigError(
            f"--icon-pack is not a valid zip archive: {exc}") from exc
    except FileNotFoundError as exc:
        raise BuildConfigError(
            f"--icon-pack not found: {pack_path}") from exc
    return entries


def stage_android_icons(entries: dict[str, bytes],
                        app_dir: Path | None = None) -> Path:
    """Back up the stock icons and stage the pack; return the backup dir.

    Every stock file must exist BEFORE anything is written: a broken
    tree fails loudly instead of ending half-staged.
    """
    res = android_res_dir(app_dir)
    missing = sorted(
        name for name in entries if not (res / name).is_file())
    if missing:
        raise BuildStepError(
            f"android res tree misses stock icons: "
            f"{', '.join(missing)}")
    backup = Path(tempfile.mkdtemp(prefix="zagros-icons-"))
    try:
        for name, blob in entries.items():
            saved = backup / name
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(res / name, saved)
            dest = res / name
            handle, tmp_name = tempfile.mkstemp(
                prefix=".icon-", suffix=".tmp", dir=str(dest.parent))
            try:
                with open(handle, "wb") as stream:
                    stream.write(blob)
                Path(tmp_name).replace(dest)
            except BaseException:
                try:
                    Path(tmp_name).unlink(missing_ok=True)
                except OSError:
                    pass
                raise
    except BaseException:
        restore_android_icons(backup, app_dir)
        raise
    return backup


def restore_android_icons(backup: Path,
                          app_dir: Path | None = None) -> None:
    """Put the stock icons back; best-effort, never raises."""
    res = android_res_dir(app_dir)
    try:
        for name in sorted(_ANDROID_ICON_NAMES):
            saved = backup / name
            if not saved.is_file():
                print(f"white_label_build: warning: icon backup "
                      f"misses '{name}' — leaving staged file in place",
                      file=sys.stderr)
                continue
            try:
                shutil.copy2(saved, res / name)
            except OSError as exc:
                print(f"white_label_build: warning: cannot restore "
                      f"stock icon '{name}': {exc}", file=sys.stderr)
    finally:
        try:
            shutil.rmtree(backup, ignore_errors=True)
        except OSError:
            pass


def validate_build_config(config: object) -> dict[str, str]:
    """Validate + translate to {ZAGROS_DEFINE: value} (product mode first)."""
    if not isinstance(config, dict):
        raise BuildConfigError("build_config must be a JSON object")
    known = set(CONFIG_FIELDS) | set(ANDROID_BRAND_FIELDS)
    unknown = sorted(set(config) - known)
    if unknown:
        # allowlist first: known keys are all public by construction, so
        # only unknown keys are screened for secret-shaped names.
        secret = next(
            (key for key in unknown
             if any(fragment in key.lower()
                    for fragment in _SECRET_KEY_FRAGMENTS)),
            None)
        if secret is not None:
            raise BuildConfigError(
                f"config['{secret}'] looks like a secret: configs ride "
                f"process listings via --dart-define — pass secrets as "
                f"build credentials instead")
        raise BuildConfigError(
            f"unknown config keys: {', '.join(unknown)} "
            f"(allowed: {', '.join(sorted(CONFIG_FIELDS))})")
    defines: dict[str, str] = {
        "ZAGROS_PRODUCT_MODE": PRODUCT_MODE}
    for key, (dart_define, required, validator, default) in (
            CONFIG_FIELDS.items()):
        if key not in config or config[key] is None:
            if required:
                raise BuildConfigError(
                    f"config['{key}'] is required for white-label builds")
            if default is None:
                continue  # the app default applies (e.g. app name fallback)
            value = default
        else:
            value = config[key]
        if validator is _bounded_text or validator is _identifier \
                or validator is _https_origin or validator is _base64key32:
            defines[dart_define] = validator(value, field=key)
        else:
            defines[dart_define] = validator(value)
    return defines


# --------------------------------------------------------------------- #
# flutter invocation
# --------------------------------------------------------------------- #

def resolve_flutter() -> str:
    override = os.environ.get("FLUTTER_BIN", "").strip()
    if override:
        return override
    found = shutil.which("flutter")
    if not found:
        raise BuildStepError(
            "flutter executable not found: install the Flutter SDK and "
            "ensure 'flutter' is on PATH (or set FLUTTER_BIN)")
    return found


def define_args(defines: dict[str, str]) -> list[str]:
    return [f"--dart-define={name}={value}"
            for name, value in defines.items()]


def build_command(flutter_bin: str, platform: str, arch: str,
                  defines: dict[str, str],
                  *, artifact: str = "apk") -> list[str]:
    """Pure argv construction (unit-tested); execution stays in main flow."""
    arches = PLATFORM_MATRIX.get(platform)
    if arches is None or arch not in arches:
        raise BuildConfigError(
            f"unsupported target {platform}/{arch} "
            f"(supported: {', '.join(sorted(PLATFORM_MATRIX))})")
    if artifact not in ANDROID_ARTIFACTS:
        raise BuildConfigError(f"unsupported artifact: {artifact!r}")
    if artifact == "aab" and platform != "android":
        raise BuildConfigError(
            f"artifact 'aab' is only supported for android, "
            f"not {platform!r}")
    command = [flutter_bin, "build"]
    if platform == "android" and artifact == "aab":
        # Full multi-ABI bundle (see ANDROID_ARTIFACTS): no
        # --target-platform flag, so flutter embeds every ABI.
        command += ["appbundle", "--release"]
    elif platform == "android":
        # --split-per-abi is load-bearing: with a single --target-platform
        # and no split flag, flutter emits a plain app-release.apk, while
        # stage_outputs/ below expects the per-ABI app-<abi>-release.apk.
        command += ["apk", "--release", "--split-per-abi",
                    f"--target-platform={arches[arch]}"]
    elif platform == "ios":
        command += ["ipa", "--release"]
    elif platform == "linux":
        command += ["linux", "--release"]
    elif platform == "windows":
        command += ["windows", "--release"]
    elif platform == "macos":
        command += ["macos", "--release"]
    return command + define_args(defines)


def resolve_artifact(platform: str, artifact: str) -> str:
    """Validate --artifact against the platform (exit 2 upstream)."""
    if artifact not in ANDROID_ARTIFACTS:
        raise BuildConfigError(f"unsupported artifact: {artifact!r}")
    if artifact == "aab" and platform != "android":
        raise BuildConfigError(
            f"artifact 'aab' is only supported for android, "
            f"not {platform!r}")
    return artifact


def run_step(argv: list[str], *, cwd: Path, what: str) -> str:
    """Run argv (no shell), stream through, return combined output tail."""
    print(f"+ {' '.join(argv[:3])}"
          f"{' …' if len(argv) > 3 else ''}  [{what}]", flush=True)
    try:
        completed = subprocess.run(
            argv, cwd=str(cwd), stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True)
    except OSError as exc:
        raise BuildStepError(f"{what} failed to start: {exc}") from exc
    sys.stdout.write(completed.stdout)
    sys.stdout.flush()
    if completed.returncode != 0:
        tail = "\n".join(completed.stdout.strip().splitlines()[-25:])
        raise BuildStepError(f"{what} failed (exit "
                             f"{completed.returncode}):\n{tail}")
    return completed.stdout


# --------------------------------------------------------------------- #
# output staging (fresh release files into --out, top level only)
# --------------------------------------------------------------------- #

def slugify(display_name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", display_name.lower()).strip("-")
    return (slug[:48] or "white-label-app")


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _place_file(source: Path, out_dir: Path, name: str) -> dict:
    dest = out_dir / name
    if dest.exists():
        raise BuildStepError(
            f"refusing to overwrite staged '{name}' (stale --out?)")
    shutil.copyfile(source, dest)
    return {"name": name, "bytes": dest.stat().st_size,
            "sha256": sha256_of(dest)}


def _tar_bundle(tree: Path, out_dir: Path, name: str,
                *, top: str) -> dict:
    dest = out_dir / name
    if dest.exists():
        raise BuildStepError(
            f"refusing to overwrite staged '{name}' (stale --out?)")
    # Reproducible bytes: fixed ownership + member timestamps, then a
    # gzip pass with a clamped header (tarfile's "w:gz" would stamp the
    # current time into the gzip wrapper instead).
    handle, tmp_name = tempfile.mkstemp(
        prefix=".bundle-", suffix=".tar", dir=str(out_dir))
    os.close(handle)
    tmp_tar = Path(tmp_name)
    try:
        with tarfile.open(tmp_tar, "w", format=tarfile.PAX_FORMAT) as archive:
            for path in sorted(tree.rglob("*")):
                member = archive.gettarinfo(
                    str(path),
                    arcname=str(Path(top) / path.relative_to(tree)))
                member.uid = member.gid = 0
                member.uname = member.gname = ""
                member.mtime = 0
                if member.isfile() and not member.issym() \
                        and not member.islnk():
                    with open(path, "rb") as data:
                        archive.addfile(member, data)
                else:
                    archive.addfile(member)
        with open(tmp_tar, "rb") as raw, open(dest, "wb") as packed:
            with gzip.GzipFile(filename="", mode="wb", fileobj=packed,
                               mtime=0) as gz:
                shutil.copyfileobj(raw, gz, length=1024 * 1024)
    finally:
        try:
            tmp_tar.unlink(missing_ok=True)
        except OSError:
            pass
    return {"name": name, "bytes": dest.stat().st_size,
            "sha256": sha256_of(dest)}


def _zip_tree(tree: Path, out_dir: Path, name: str, top: str) -> dict:
    dest = out_dir / name
    if dest.exists():
        raise BuildStepError(
            f"refusing to overwrite staged '{name}' (stale --out?)")
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as archive:
        files = sorted(path for path in tree.rglob("*") if path.is_file())
        for path in files:
            info = zipfile.ZipInfo(
                str(Path(top) / path.relative_to(tree)),
                date_time=(2020, 1, 1, 0, 0, 0))
            info.external_attr = 0o644 << 16
            archive.writestr(info, path.read_bytes())
    return {"name": name, "bytes": dest.stat().st_size,
            "sha256": sha256_of(dest)}


def _exactly_one(matches: list[Path], *, what: str) -> Path:
    if len(matches) != 1:
        raise BuildStepError(
            f"expected exactly one {what}, found {len(matches)}")
    return matches[0]


def stage_outputs(*, platform: str, arch: str, slug: str,
                  out_dir: Path, artifact: str = "apk") -> list[dict]:
    """Collect flutter's outputs into --out; returns artifact records."""
    if not out_dir.is_dir():
        raise BuildStepError(f"--out is not a directory: {out_dir}")
    build = APP / "build"
    if platform == "android" and artifact == "aab":
        bundle = (build / "app" / "outputs" / "bundle" / "release"
                  / "app-release.aab")
        if not bundle.is_file():
            raise BuildStepError(f"missing expected output {bundle}")
        return [_place_file(
            bundle, out_dir,
            expected_artifact_name(platform, arch, slug,
                                   artifact=artifact))]
    if platform == "android":
        apk = build / "app" / "outputs" / "flutter-apk" / (
            f"app-{ANDROID_APK_ABI[arch]}-release.apk")
        if not apk.is_file():
            raise BuildStepError(f"missing expected output {apk}")
        return [_place_file(
            apk, out_dir,
            expected_artifact_name(platform, arch, slug,
                                   artifact=artifact))]
    if platform == "ios":
        ipa = _exactly_one(
            sorted((build / "ios" / "ipa").glob("*.ipa"))
            if (build / "ios" / "ipa").is_dir() else [],
            what="ios .ipa")
        return [_place_file(
            ipa, out_dir,
            expected_artifact_name(platform, arch, slug))]
    if platform == "linux":
        bundle = build / "linux" / arch / "release" / "bundle"
        if not bundle.is_dir():
            raise BuildStepError(f"missing expected output {bundle}")
        return [_tar_bundle(
            bundle, out_dir,
            expected_artifact_name(platform, arch, slug),
            top=f"{slug}-linux-{arch}")]
    if platform == "windows":
        folder = build / "windows" / arch / "runner" / "Release"
        if not folder.is_dir():
            raise BuildStepError(f"missing expected output {folder}")
        return [_zip_tree(
            folder, out_dir,
            expected_artifact_name(platform, arch, slug),
            f"{slug}-windows-{arch}")]
    if platform == "macos":
        # tar, not zip: zipping an .app with zipfile would drop the main
        # executable bit and Framework symlinks; tar preserves both.
        release = build / "macos" / "Build" / "Products" / "Release"
        app_dir = _exactly_one(
            sorted(release.glob("*.app")) if release.is_dir() else [],
            what="macos .app")
        return [_tar_bundle(
            app_dir, out_dir,
            expected_artifact_name(platform, arch, slug),
            top=app_dir.name)]
    raise BuildConfigError(f"unsupported platform '{platform}'")


def write_receipt(*, out_dir: Path, platform: str, arch: str,
                  app_name: str, define_names: list[str],
                  flutter_version: str, artifacts: list[dict],
                  icon_pack_sha256: str | None = None) -> Path:
    receipt = {
        "contract": CONTRACT_VERSION,
        "script": "tool/white_label_build.py",
        "product_mode": PRODUCT_MODE,
        "platform": platform,
        "arch": arch,
        "app_name": app_name,
        "defines": define_names,
        "flutter_version": flutter_version.strip().splitlines()[0]
        if flutter_version.strip() else "unknown",
        "artifacts": artifacts,
        "icon_pack_sha256": icon_pack_sha256,
    }
    dest = out_dir / RECEIPT_NAME
    if dest.exists():
        raise BuildStepError(
            f"refusing to overwrite staged '{RECEIPT_NAME}' (stale --out?)")
    handle, tmp_name = tempfile.mkstemp(
        prefix=".receipt-", suffix=".tmp", dir=str(out_dir))
    try:
        with open(handle, "w", encoding="utf-8") as stream:
            json.dump(receipt, stream, ensure_ascii=False, indent=2,
                      sort_keys=True)
            stream.write("\n")
        Path(tmp_name).replace(dest)
    except BaseException:
        try:
            Path(tmp_name).unlink(missing_ok=True)
        except OSError:
            pass
        raise
    return dest


# --------------------------------------------------------------------- #
# main flow
# --------------------------------------------------------------------- #

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a white-label Zagros VPN release "
                    "(job contract v1).")
    parser.add_argument("--config", required=True,
                        help="path to build_config.json")
    parser.add_argument("--platform", required=True,
                        help="target platform slug")
    parser.add_argument("--arch", required=True, help="target arch slug")
    parser.add_argument("--out", required=True,
                        help="existing directory for release files")
    parser.add_argument("--artifact", default="apk",
                        choices=sorted(ANDROID_ARTIFACTS),
                        help="android artifact kind (default: apk)")
    parser.add_argument("--icon-pack", default=None,
                        help="launcher icon pack zip (android only; "
                             "the worker downloads it from the panel)")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    platform = args.platform.strip().lower()
    arch = args.arch.strip().lower()
    out_dir = Path(args.out)
    try:
        if not (APP / "pubspec.yaml").is_file():
            raise BuildConfigError(
                f"not a Zagros-VPN checkout (missing {APP}/pubspec.yaml)")
        preflight_sdk()
        try:
            raw_config = Path(args.config).read_text(encoding="utf-8")
        except OSError as exc:
            raise BuildConfigError(
                f"cannot read --config: {exc}") from exc
        try:
            config = json.loads(raw_config)
        except json.JSONDecodeError as exc:
            raise BuildConfigError(
                f"--config is not valid JSON: {exc}") from exc
        defines = validate_build_config(config)
        arches = PLATFORM_MATRIX.get(platform)
        if arches is None or arch not in arches:
            raise BuildConfigError(
                f"unsupported target {platform}/{arch}")
        brand = android_brand(config, for_android=(platform == "android"))
        if args.icon_pack and platform != "android":
            raise BuildConfigError(
                "--icon-pack is only supported for android builds")
        icon_entries = (read_icon_pack(Path(args.icon_pack))
                        if args.icon_pack else None)
        icon_pack_sha256 = (sha256_of(Path(args.icon_pack))
                            if args.icon_pack else None)
        artifact = resolve_artifact(platform, args.artifact)
        app_name = defines["ZAGROS_APP_NAME"]
        slug = slugify(app_name)
        preflight_out_dir(
            out_dir, expected_artifact_name(platform, arch, slug,
                                            artifact=artifact))
        print(f"white-label build: app='{app_name}' slug='{slug}' "
              f"target={platform}/{arch} artifact={artifact}", flush=True)
        print(f"baking defines: {', '.join(defines)}", flush=True)

        flutter_bin = resolve_flutter()
        flutter_version = run_step([flutter_bin, "--version"], cwd=ROOT,
                                   what="flutter toolchain probe")
        run_step([flutter_bin, "pub", "get"], cwd=ROOT,
                 what="flutter pub get")
        run_step([flutter_bin, "gen-l10n"], cwd=APP,
                 what="flutter gen-l10n")
        command = build_command(flutter_bin, platform, arch, defines,
                                artifact=artifact)
        icon_backup: Path | None = None
        if platform == "android":
            # brand is never None here (required above). A stale file
            # from a crashed run must never poison this one; the write
            # then fails loudly if the tree itself is broken.
            clear_android_brand()
            write_android_brand(brand)
            print("android brand: staged (applicationId, label)",
                  flush=True)
            if icon_entries is not None:
                icon_backup = stage_android_icons(icon_entries)
                assert icon_pack_sha256 is not None
                print(f"android icons: staged {len(icon_entries)} "
                      f"densities from pack "
                      f"(sha256:{icon_pack_sha256[:12]}…)", flush=True)
        try:
            run_step(command, cwd=APP, what=f"flutter build {platform}")
        finally:
            if platform == "android":
                if icon_backup is not None:
                    restore_android_icons(icon_backup)
                clear_android_brand()
        artifacts = stage_outputs(platform=platform, arch=arch, slug=slug,
                                  out_dir=out_dir, artifact=artifact)
        receipt = write_receipt(
            out_dir=out_dir, platform=platform, arch=arch,
            app_name=app_name, define_names=sorted(defines),
            flutter_version=flutter_version, artifacts=artifacts,
            icon_pack_sha256=icon_pack_sha256)
        for record in artifacts:
            print(f"ARTIFACT name={record['name']} bytes={record['bytes']} "
                  f"sha256={record['sha256']}", flush=True)
        print(f"receipt: {receipt.name}", flush=True)
        print("white-label build complete", flush=True)
        return 0
    except BuildConfigError as exc:
        print(f"white_label_build: config error: {exc}", file=sys.stderr)
        return 2
    except BuildStepError as exc:
        print(f"white_label_build: build error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("white_label_build: interrupted", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
