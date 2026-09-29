"""Unit tests for tool/white_label_build.py (real file ops, no flutter).

Run: ``python3 -m pytest tool/tests/test_white_label_build.py`` from the
repo root. The live ``flutter build`` proof lives in
``test_white_label_build_live.py`` (needs the Flutter SDK + toolchains).
"""
from __future__ import annotations

import base64
import json
import stat
import sys
import tarfile
import zipfile
from pathlib import Path

import pytest

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))

import white_label_build as script  # noqa: E402

FAKE_KEY_32 = base64.urlsafe_b64encode(bytes(range(32))).decode("ascii")


def _config(**overrides):
    config = {
        "display_name": "Partner VPN",
        "default_locale": "fa",
        "application_api_base_url": "https://panel.example.test/api/app",
        "application_id": "application-1",
        "application_name": "Partner",
        "application_status": "active",
        "config_key_id": "config-key-1",
        "config_public_key": FAKE_KEY_32,
        "signing_key_id": "signing-key-1",
        "signing_public_key": FAKE_KEY_32,
    }
    config.update(overrides)
    return config


# --------------------------------------------------------------------- #
# contract matrix (duplicated on purpose: no cross-repo imports allowed)
# --------------------------------------------------------------------- #

def test_platform_matrix_matches_panel_and_builder():
    assert script.PLATFORM_MATRIX == {
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


# --------------------------------------------------------------------- #
# config validation -> dart-defines
# --------------------------------------------------------------------- #

def test_valid_config_translates_to_exact_defines():
    defines = script.validate_build_config(_config())
    assert defines == {
        "ZAGROS_PRODUCT_MODE": "white-label",
        "ZAGROS_APP_NAME": "Partner VPN",
        "ZAGROS_DEFAULT_LOCALE": "fa",
        "ZAGROS_APPLICATION_API_BASE_URL":
            "https://panel.example.test/api/app",
        "ZAGROS_APPLICATION_ID": "application-1",
        "ZAGROS_APPLICATION_NAME": "Partner",
        "ZAGROS_APPLICATION_STATUS": "active",
        "ZAGROS_CONFIG_KEY_ID": "config-key-1",
        "ZAGROS_CONFIG_PUBLIC_KEY": FAKE_KEY_32,
        "ZAGROS_SIGNING_KEY_ID": "signing-key-1",
        "ZAGROS_SIGNING_PUBLIC_KEY": FAKE_KEY_32,
    }


def test_optionals_fall_back_and_blanks_rejected():
    defines = script.validate_build_config(_config(
        default_locale=None, application_name=None,
        application_status=None))
    assert defines["ZAGROS_DEFAULT_LOCALE"] == "fa"
    assert defines["ZAGROS_APPLICATION_STATUS"] == "active"
    assert "ZAGROS_APPLICATION_NAME" not in defines  # app falls back
    with pytest.raises(script.BuildConfigError):
        script.validate_build_config(_config(display_name="   "))
    with pytest.raises(script.BuildConfigError):
        script.validate_build_config("not-a-dict")


def test_missing_required_keys_fail():
    for key in ("display_name", "application_api_base_url",
                "application_id", "config_key_id", "config_public_key",
                "signing_key_id", "signing_public_key"):
        config = _config()
        del config[key]
        with pytest.raises(script.BuildConfigError, match=key):
            script.validate_build_config(config)


def test_invalid_values_fail_with_field_errors():
    cases = [
        ({"default_locale": "de"}, "default_locale"),
        ({"application_api_base_url": "http://insecure.test/a"},
         "application_api_base_url"),
        ({"application_api_base_url": "https://u:p@h.test/a"},
         "application_api_base_url"),
        ({"application_api_base_url": "https://h.test/a?q=1"},
         "application_api_base_url"),
        ({"application_id": "has spaces"}, "application_id"),
        ({"application_id": "x" * 129}, "application_id"),
        ({"display_name": "bad\nname"}, "display_name"),
        ({"display_name": "x" * 129}, "display_name"),
        ({"config_public_key": "!!!not-base64!!!"}, "config_public_key"),
        ({"config_public_key": base64.urlsafe_b64encode(b"short").decode()},
         "config_public_key"),
    ]
    for override, field in cases:
        with pytest.raises(script.BuildConfigError, match=field):
            script.validate_build_config(_config(**override))


def test_secret_shaped_and_unknown_keys_rejected():
    with pytest.raises(script.BuildConfigError, match="secret"):
        script.validate_build_config(_config(api_token="abc"))
    with pytest.raises(script.BuildConfigError, match="secret"):
        script.validate_build_config(_config(signing_password="abc"))
    with pytest.raises(script.BuildConfigError, match="unknown"):
        script.validate_build_config(_config(displayname="typo"))
    with pytest.raises(script.BuildConfigError, match="unknown"):
        script.validate_build_config(_config(product_mode="official"))


def test_slugify():
    assert script.slugify("Partner VPN") == "partner-vpn"
    assert script.slugify("  A_B.C@d  ") == "a-b-c-d"
    assert script.slugify("!!!") == "white-label-app"
    assert len(script.slugify("x" * 100)) == 48


# --------------------------------------------------------------------- #
# argv construction (pure; execution is proven live)
# --------------------------------------------------------------------- #

DEFINES = {"ZAGROS_PRODUCT_MODE": "white-label",
           "ZAGROS_APP_NAME": "Partner VPN"}


def test_build_command_android_maps_arches():
    command = script.build_command("flutter", "android", "arm64-v8a",
                                   DEFINES)
    assert command[:4] == ["flutter", "build", "apk", "--release"]
    assert "--target-platform=android-arm64" in command
    # Load-bearing: without --split-per-abi flutter emits a plain
    # app-release.apk while stage_outputs expects app-<abi>-release.apk.
    assert "--split-per-abi" in command
    assert "--dart-define=ZAGROS_APP_NAME=Partner VPN" in command
    assert "--target-platform=android-arm" in script.build_command(
        "flutter", "android", "armeabi-v7a", DEFINES)
    assert "--target-platform=android-x64" in script.build_command(
        "flutter", "android", "x86_64", DEFINES)


def test_build_command_desktop_and_ios():
    assert script.build_command(
        "flutter", "linux", "x64", DEFINES)[:3] == [
        "flutter", "build", "linux"]
    assert script.build_command(
        "flutter", "windows", "arm64", DEFINES)[2] == "windows"
    assert script.build_command(
        "flutter", "macos", "x64", DEFINES)[2] == "macos"
    assert script.build_command(
        "flutter", "ios", "arm64", DEFINES)[2] == "ipa"
    assert "--release" in script.build_command(
        "flutter", "ios", "arm64", DEFINES)


def test_build_command_rejects_unknown_targets():
    with pytest.raises(script.BuildConfigError):
        script.build_command("flutter", "symbian", "arm", DEFINES)
    with pytest.raises(script.BuildConfigError):
        script.build_command("flutter", "ios", "x86_64", DEFINES)


def test_resolve_flutter_honors_override_and_fails_closed(monkeypatch):
    monkeypatch.setenv("FLUTTER_BIN", "/custom/flutter")
    assert script.resolve_flutter() == "/custom/flutter"
    monkeypatch.delenv("FLUTTER_BIN")
    monkeypatch.setattr(script.shutil, "which", lambda *_: None)
    with pytest.raises(script.BuildStepError, match="FLUTTER_BIN"):
        script.resolve_flutter()


# --------------------------------------------------------------------- #
# staging (fixture build-output trees, real files + archives)
# --------------------------------------------------------------------- #

@pytest.fixture()
def staged_app(tmp_path, monkeypatch):
    fake_app = tmp_path / "app"
    (fake_app / "build").mkdir(parents=True)
    out = tmp_path / "out"
    out.mkdir()
    monkeypatch.setattr(script, "APP", fake_app)
    return fake_app, out


def test_stage_android_apk_bytes_identical(staged_app):
    fake_app, out = staged_app
    apk_dir = fake_app / "build" / "app" / "outputs" / "flutter-apk"
    apk_dir.mkdir(parents=True)
    (apk_dir / "app-arm64-v8a-release.apk").write_bytes(b"APK" * 1000)
    (records,) = script.stage_outputs(
        platform="android", arch="arm64-v8a", slug="partner-vpn",
        out_dir=out)
    assert records["name"] == "partner-vpn-arm64-v8a.apk"
    assert (out / records["name"]).read_bytes() == b"APK" * 1000
    assert len(records["sha256"]) == 64
    with pytest.raises(script.BuildStepError, match="missing"):
        script.stage_outputs(platform="android", arch="x86_64",
                             slug="partner-vpn", out_dir=out)


def test_stage_ios_requires_exactly_one_ipa(staged_app):
    fake_app, out = staged_app
    ipa_dir = fake_app / "build" / "ios" / "ipa"
    ipa_dir.mkdir(parents=True)
    with pytest.raises(script.BuildStepError, match="exactly one"):
        script.stage_outputs(platform="ios", arch="arm64",
                             slug="partner-vpn", out_dir=out)
    (ipa_dir / "a.ipa").write_bytes(b"1")
    (ipa_dir / "b.ipa").write_bytes(b"2")
    with pytest.raises(script.BuildStepError, match="exactly one"):
        script.stage_outputs(platform="ios", arch="arm64",
                             slug="partner-vpn", out_dir=out)


def test_stage_linux_tarball_preserves_modes_and_reproduces(staged_app):
    fake_app, out = staged_app
    bundle = fake_app / "build" / "linux" / "x64" / "release" / "bundle"
    (bundle / "lib").mkdir(parents=True)
    binary = bundle / "partner"
    binary.write_bytes(b"\x7fELF" + b"x" * 100)
    binary.chmod(0o755)
    (bundle / "lib" / "libx.so").write_bytes(b"so")
    first = script.stage_outputs(platform="linux", arch="x64",
                                 slug="partner-vpn", out_dir=out)[0]
    assert first["name"] == "partner-vpn-linux-x64.tar.gz"
    out2 = out.parent / "out2"
    out2.mkdir()
    second = script.stage_outputs(platform="linux", arch="x64",
                                  slug="partner-vpn", out_dir=out2)[0]
    assert first["sha256"] == second["sha256"]  # byte-reproducible
    with tarfile.open(out / first["name"], "r:gz") as archive:
        names = sorted(archive.getnames())
        assert names[0].startswith("partner-vpn-linux-x64/")
        member = archive.getmember("partner-vpn-linux-x64/partner")
        assert member.mtime == 0
        assert stat.S_IMODE(member.mode) == 0o755
        assert member.uid == 0 and member.uname == ""


def test_stage_windows_zip_clamps_and_sorts(staged_app):
    fake_app, out = staged_app
    release = fake_app / "build" / "windows" / "x64" / "runner" / "Release"
    release.mkdir(parents=True)
    (release / "b.dll").write_bytes(b"b")
    (release / "a.exe").write_bytes(b"a")
    (record,) = script.stage_outputs(platform="windows", arch="x64",
                                     slug="partner-vpn", out_dir=out)
    assert record["name"] == "partner-vpn-windows-x64.zip"
    with zipfile.ZipFile(out / record["name"]) as archive:
        assert archive.namelist() == [
            "partner-vpn-windows-x64/a.exe",
            "partner-vpn-windows-x64/b.dll"]
        assert archive.getinfo(
            "partner-vpn-windows-x64/a.exe").date_time == (
            2020, 1, 1, 0, 0, 0)


def test_stage_macos_keeps_app_bundle_name(staged_app):
    fake_app, out = staged_app
    release = fake_app / "build" / "macos" / "Build" / "Products" / "Release"
    app_dir = release / "Partner.app" / "Contents" / "MacOS"
    app_dir.mkdir(parents=True)
    exe = app_dir / "Partner"
    exe.write_bytes(b"macho")
    exe.chmod(0o755)
    (record,) = script.stage_outputs(platform="macos", arch="arm64",
                                     slug="partner-vpn", out_dir=out)
    assert record["name"] == "partner-vpn-macos-arm64.tar.gz"
    with tarfile.open(out / record["name"], "r:gz") as archive:
        member = archive.getmember("Partner.app/Contents/MacOS/Partner")
        assert stat.S_IMODE(member.mode) == 0o755


def test_stage_refuses_stale_out_and_missing_dir(staged_app, tmp_path):
    fake_app, out = staged_app
    (out / "partner-vpn-arm64-v8a.apk").write_bytes(b"stale")
    apk_dir = fake_app / "build" / "app" / "outputs" / "flutter-apk"
    apk_dir.mkdir(parents=True)
    (apk_dir / "app-arm64-v8a-release.apk").write_bytes(b"new")
    with pytest.raises(script.BuildStepError, match="stale --out"):
        script.stage_outputs(platform="android", arch="arm64-v8a",
                             slug="partner-vpn", out_dir=out)
    with pytest.raises(script.BuildStepError, match="not a directory"):
        script.stage_outputs(platform="android", arch="arm64-v8a",
                             slug="partner-vpn",
                             out_dir=tmp_path / "nope")


def test_expected_artifact_names_cover_matrix():
    assert script.expected_artifact_name(
        "android", "arm64-v8a", "s") == "s-arm64-v8a.apk"
    assert script.expected_artifact_name(
        "ios", "arm64", "s") == "s.ipa"
    assert script.expected_artifact_name(
        "linux", "x64", "s") == "s-linux-x64.tar.gz"
    assert script.expected_artifact_name(
        "windows", "arm64", "s") == "s-windows-arm64.zip"
    assert script.expected_artifact_name(
        "macos", "x64", "s") == "s-macos-x64.tar.gz"


def _sdk_path_dep(pubspec: Path) -> str:
    lines = pubspec.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        if line.strip() == "zagros_vpn_sdk:":
            for follow in lines[index + 1:index + 4]:
                stripped = follow.strip()
                if stripped.startswith("path:"):
                    return stripped.split("path:", 1)[1].strip()
    raise AssertionError(f"no zagros_vpn_sdk path dep in {pubspec}")


def test_pubspec_sdk_paths_match_the_worker_convention():
    # The v2 worker clones the SDK to `<checkout-sibling>/Zagros-VPN-SDK`
    # (see SDK_CHECKOUT_DIRNAME there). Both pubspecs must resolve to
    # exactly that sibling, or lone checkouts break at pub get.
    root = Path(script.__file__).resolve().parents[1]
    expected = f"../../../{script.SDK_DIRNAME}"
    assert _sdk_path_dep(
        root / "apps" / "zagros_vpn" / "pubspec.yaml") == expected
    assert _sdk_path_dep(
        root / "packages" / "tunnel_interface" / "pubspec.yaml") == expected


def test_preflight_sdk_requires_a_usable_sibling_checkout(tmp_path):
    fake_root = tmp_path / "Zagros-VPN"
    fake_root.mkdir()
    with pytest.raises(script.BuildStepError, match="missing SDK"):
        script.preflight_sdk(fake_root)
    sdk = tmp_path / script.SDK_DIRNAME
    sdk.mkdir()  # present but not a checkout (no pubspec)
    with pytest.raises(script.BuildStepError, match="missing SDK"):
        script.preflight_sdk(fake_root)
    (sdk / "pubspec.yaml").write_text("name: zagros_vpn_sdk\n",
                                      encoding="utf-8")
    assert script.preflight_sdk(fake_root) == sdk


def test_preflight_rejects_missing_and_stale_out(tmp_path):
    with pytest.raises(script.BuildConfigError, match="not a directory"):
        script.preflight_out_dir(tmp_path / "nope", "s-linux-x64.tar.gz")
    fresh = tmp_path / "fresh"
    fresh.mkdir()
    script.preflight_out_dir(fresh, "s-linux-x64.tar.gz")  # no raise
    (fresh / "s-linux-x64.tar.gz").write_bytes(b"stale")
    with pytest.raises(script.BuildStepError, match="stale --out"):
        script.preflight_out_dir(fresh, "s-linux-x64.tar.gz")
    (fresh / "s-linux-x64.tar.gz").unlink()
    (fresh / "unrelated.txt").write_bytes(b"x")
    with pytest.raises(script.BuildStepError, match="not empty"):
        script.preflight_out_dir(fresh, "s-linux-x64.tar.gz")


def test_write_receipt_is_deterministic_json(staged_app):
    _, out = staged_app
    receipt = script.write_receipt(
        out_dir=out, platform="linux", arch="x64", app_name="Partner VPN",
        define_names=["B", "A"], flutter_version="Flutter 3.47.2\nnoise",
        artifacts=[{"name": "a", "bytes": 3, "sha256": "0" * 64}])
    assert receipt.name == "white-label-build-receipt.json"
    parsed = json.loads(receipt.read_text(encoding="utf-8"))
    assert parsed["contract"] == 1
    assert parsed["product_mode"] == "white-label"
    assert parsed["defines"] == ["B", "A"]
    assert parsed["flutter_version"] == "Flutter 3.47.2"
    with pytest.raises(script.BuildStepError, match="stale --out"):
        script.write_receipt(
            out_dir=out, platform="linux", arch="x64",
            app_name="x", define_names=[],
            flutter_version="", artifacts=[])


# --------------------------------------------------------------------- #
# android brand injection (Gradle file, never dart-defines)
# --------------------------------------------------------------------- #

def _android_config(**overrides):
    base = {
        "android_application_id": "com.partner.vpn",
        "android_application_label": "Partner VPN",
    }
    base.update(overrides)
    return _config(**base)


def test_android_brand_keys_allowed_but_never_become_defines():
    defines = script.validate_build_config(_android_config())
    assert "ZAGROS_APP_NAME" in defines
    assert not any("ANDROID" in name for name in defines)
    assert len(defines) == 11  # product mode + 10 dart fields, unchanged


def test_android_brand_validates_pair_or_nothing():
    assert script.android_brand(_android_config(), for_android=True) == {
        "applicationId": "com.partner.vpn", "label": "Partner VPN"}
    assert script.android_brand(_config(), for_android=False) is None
    # shared configs validate strictly even for other platforms
    assert script.android_brand(
        _android_config(), for_android=False) is not None
    with pytest.raises(script.BuildConfigError, match="required"):
        script.android_brand(_config(), for_android=True)
    only_id = _config(android_application_id="com.partner.vpn")
    with pytest.raises(script.BuildConfigError,
                       match="android_application_label"):
        script.android_brand(only_id, for_android=True)
    with pytest.raises(script.BuildConfigError, match="must be a JSON"):
        script.android_brand("nope", for_android=False)


def test_android_application_id_rejects_non_play_shapes():
    bad = ["nodots", "Com.Caps.Vpn", "com.9start.vpn", "com.part-ner.vpn",
           "com..empty.vpn", ".leading.dot", "trailing.dot.", "com/pa/th",
           "com." + "x" * 252, "", "   ", "com.partner.vpn;rm -rf"]
    for value in bad:
        with pytest.raises(script.BuildConfigError,
                           match="android_application_id"):
            script.android_brand(
                _android_config(android_application_id=value),
                for_android=True)
    good = ["c.p", "com.partner.vpn", "com.partner_v2.vpn_app",
            "com." + "x" * 251]  # exactly 255 chars: boundary-valid
    for value in good:
        brand = script.android_brand(
            _android_config(android_application_id=value), for_android=True)
        assert brand["applicationId"] == value


def test_android_label_capped_and_control_safe():
    with pytest.raises(script.BuildConfigError,
                       match="android_application_label"):
        script.android_brand(
            _android_config(android_application_label="x" * 65),
            for_android=True)
    with pytest.raises(script.BuildConfigError,
                       match="android_application_label"):
        script.android_brand(
            _android_config(android_application_label="bad\nlabel"),
            for_android=True)
    brand = script.android_brand(
        _android_config(android_application_label="x" * 64),
        for_android=True)
    assert brand["label"] == "x" * 64


def test_brand_file_roundtrip_and_escaping(tmp_path):
    app_dir = tmp_path / "zagros_vpn"
    (app_dir / "android").mkdir(parents=True)
    dest = script.write_android_brand(
        {"applicationId": "com.partner.vpn", "label": "A=B:C#D!E\\F"},
        app_dir=app_dir)
    assert dest == app_dir / "android" / "zagros-brand.properties"
    body = dest.read_text(encoding="utf-8")
    assert "applicationId=com.partner.vpn\n" in body
    assert "label=A\\=B\\:C\\#D\\!E\\\\F\n" in body
    assert "Do not commit" in body
    # atomic write leaves no temp crumbs
    assert [path.name for path in (app_dir / "android").iterdir()] == [
        "zagros-brand.properties"]
    script.clear_android_brand(app_dir=app_dir)
    assert not dest.exists()
    script.clear_android_brand(app_dir=app_dir)  # idempotent, no raise


def test_brand_path_defaults_to_real_android_tree():
    assert script.android_brand_path() == (
        script.APP / "android" / "zagros-brand.properties")


# --------------------------------------------------------------------- #
# android artifact kinds (apk per ABI, one multi-ABI aab)
# --------------------------------------------------------------------- #

def test_resolve_artifact_matrix():
    assert script.resolve_artifact("android", "apk") == "apk"
    assert script.resolve_artifact("android", "aab") == "aab"
    assert script.resolve_artifact("linux", "apk") == "apk"
    with pytest.raises(script.BuildConfigError, match="only supported"):
        script.resolve_artifact("linux", "aab")
    with pytest.raises(script.BuildConfigError, match="unsupported"):
        script.resolve_artifact("android", "abb")


def test_build_command_aab_has_no_target_platform():
    command = script.build_command("flutter", "android", "arm64-v8a",
                                   DEFINES, artifact="aab")
    assert command[:4] == ["flutter", "build", "appbundle", "--release"]
    assert not any(part.startswith("--target-platform")
                   for part in command)
    assert "--dart-define=ZAGROS_APP_NAME=Partner VPN" in command
    # default stays apk (old callers unaffected)
    assert script.build_command(
        "flutter", "android", "arm64-v8a", DEFINES)[2] == "apk"
    with pytest.raises(script.BuildConfigError, match="only supported"):
        script.build_command("flutter", "linux", "x64", DEFINES,
                             artifact="aab")


def test_artifact_aware_naming_and_staging(staged_app):
    assert script.expected_artifact_name(
        "android", "arm64-v8a", "s", artifact="aab") == "s-arm64-v8a.aab"
    assert script.expected_artifact_name(
        "android", "arm64-v8a", "s") == "s-arm64-v8a.apk"
    with pytest.raises(script.BuildConfigError, match="unsupported"):
        script.expected_artifact_name(
            "android", "arm64-v8a", "s", artifact="abb")
    fake_app, out = staged_app
    bundle_dir = fake_app / "build" / "app" / "outputs" / "bundle" / "release"
    bundle_dir.mkdir(parents=True)
    (bundle_dir / "app-release.aab").write_bytes(b"AAB" * 1000)
    (record,) = script.stage_outputs(
        platform="android", arch="arm64-v8a", slug="partner-vpn",
        out_dir=out, artifact="aab")
    assert record["name"] == "partner-vpn-arm64-v8a.aab"
    assert (out / record["name"]).read_bytes() == b"AAB" * 1000
    # the bundle path is arch-independent: remove the file to prove
    # the missing-output guard
    (bundle_dir / "app-release.aab").unlink()
    out2 = out.parent / "out2"
    out2.mkdir()
    with pytest.raises(script.BuildStepError, match="missing"):
        script.stage_outputs(platform="android", arch="x86_64",
                             slug="partner-vpn", out_dir=out2,
                             artifact="aab")


# --------------------------------------------------------------------- #
# launcher icon pack (--icon-pack, android only)
# --------------------------------------------------------------------- #

_FAKE_PNG = b"\x89PNG\r\n\x1a\n" + bytes(100)


def _write_pack(path, names_payloads):
    with zipfile.ZipFile(path, "w") as zf:
        for name, payload in names_payloads:
            zf.writestr(name, payload)
    return path


def _full_pack(path):
    return _write_pack(path, [
        (f"{density}/ic_launcher.png", _FAKE_PNG + density.encode())
        for density, _ in script.ANDROID_ICON_DENSITIES])


def _fake_res_tree(app_dir):
    res = (app_dir / "android" / "app" / "src" / "main" / "res")
    for density, _ in script.ANDROID_ICON_DENSITIES:
        cell = res / density
        cell.mkdir(parents=True)
        (cell / "ic_launcher.png").write_bytes(b"STOCK-" + density.encode())
    return res


def test_icon_pack_roundtrip_restores_stock_files(tmp_path):
    app_dir = tmp_path / "app"
    res = _fake_res_tree(app_dir)
    pack = _full_pack(tmp_path / "pack.zip")
    entries = script.read_icon_pack(pack)
    assert sorted(entries) == sorted(
        f"{density}/ic_launcher.png"
        for density, _ in script.ANDROID_ICON_DENSITIES)
    stock = {name: (res / name).read_bytes() for name in entries}
    backup = script.stage_android_icons(entries, app_dir)
    try:
        for name, blob in entries.items():
            assert (res / name).read_bytes() == blob
    finally:
        script.restore_android_icons(backup, app_dir)
    for name, blob in stock.items():
        assert (res / name).read_bytes() == blob
    assert not backup.exists()


def test_icon_pack_rejects_incomplete_and_foreign_entries(tmp_path):
    one = ("mipmap-mdpi/ic_launcher.png", _FAKE_PNG)
    with pytest.raises(script.BuildConfigError, match="exactly"):
        script.read_icon_pack(_write_pack(tmp_path / "a.zip", [one]))
    names = [(f"{d}/ic_launcher.png", _FAKE_PNG)
             for d, _ in script.ANDROID_ICON_DENSITIES]
    with pytest.raises(script.BuildConfigError, match="evil"):
        script.read_icon_pack(_write_pack(
            tmp_path / "b.zip", names + [("../../evil.png", b"x")]))
    with pytest.raises(script.BuildConfigError, match="not a PNG"):
        script.read_icon_pack(_write_pack(
            tmp_path / "c.zip",
            [(n, b"nope-not-png") for n, _ in names]))
    (tmp_path / "d.zip").write_bytes(b"definitely not a zip")
    with pytest.raises(script.BuildConfigError, match="not a valid zip"):
        script.read_icon_pack(tmp_path / "d.zip")
    with pytest.raises(script.BuildConfigError, match="not found"):
        script.read_icon_pack(tmp_path / "missing.zip")


def test_icon_stage_refuses_broken_res_tree(tmp_path):
    app_dir = tmp_path / "app"
    res = _fake_res_tree(app_dir)
    (res / "mipmap-mdpi" / "ic_launcher.png").unlink()
    entries = script.read_icon_pack(_full_pack(tmp_path / "pack.zip"))
    with pytest.raises(script.BuildStepError, match="mipmap-mdpi"):
        script.stage_android_icons(entries, app_dir)


def test_icon_pack_flag_defaults_to_none_and_receipt_carries_sha(tmp_path):
    args = script.parse_args(
        ["--config", "c.json", "--platform", "android",
         "--arch", "arm64-v8a", "--out", "out"])
    assert args.icon_pack is None
    args = script.parse_args(
        ["--config", "c.json", "--platform", "android",
         "--arch", "arm64-v8a", "--out", "out",
         "--icon-pack", "pack.zip"])
    assert args.icon_pack == "pack.zip"
    out = tmp_path / "out"
    out.mkdir()
    receipt = script.write_receipt(
        out_dir=out, platform="android", arch="arm64-v8a",
        app_name="P", define_names=[], flutter_version="",
        artifacts=[], icon_pack_sha256="ab" * 32)
    import json as _json
    parsed = _json.loads(receipt.read_text(encoding="utf-8"))
    assert parsed["icon_pack_sha256"] == "ab" * 32


_SEED = "k" * 43  # 32 bytes, base64url unpadded


def test_build_command_carries_secret_define_file(tmp_path):
    seed_file = tmp_path / "seed"
    seed_file.write_text(_SEED + "\n", encoding="utf-8")
    command = script.build_command(
        "flutter", "android", "arm64-v8a", DEFINES,
        secret_define_file=str(seed_file))
    assert command[-1] == f"--dart-define-from-file={seed_file}"
    # the plain --dart-define list stays untouched (public values only)
    assert "--dart-define=ZAGROS_APP_NAME=Partner VPN" in command
    assert not any("ZAGROS_APPLICATION_SIGNING_PRIVATE_KEY" in part
                   for part in command)


def test_read_signing_seed_validates_and_strips(tmp_path):
    seed_file = tmp_path / "seed"
    seed_file.write_text("  " + _SEED + "\n", encoding="utf-8")
    assert script.read_signing_seed(str(seed_file)) == _SEED
    for bad in ("short", "A" * 42, "A" * 44, "A" * 43 + "="):
        seed_file.write_text(bad, encoding="utf-8")
        with pytest.raises(script.BuildConfigError, match="43-char"):
            script.read_signing_seed(str(seed_file))
    with pytest.raises(script.BuildConfigError, match="cannot read"):
        script.read_signing_seed(str(tmp_path / "missing"))


def test_secret_define_file_never_in_config_defines():
    # the config-side validator must keep rejecting the secret key (it
    # trips the secret-fragment guard) so the file channel stays the ONLY
    # path for the seed
    with pytest.raises(script.BuildConfigError, match="looks like a secret"):
        script.validate_build_config(
            dict(_config(), signing_private_seed=_SEED))
