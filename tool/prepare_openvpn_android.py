#!/usr/bin/env python3
"""Stage and verify pinned OpenVPN 2.6.x (ics-openvpn) Android daemon binaries.

Validates the exact upstream release APK archive from schwabe/ics-openvpn,
extracts the native binaries (libopenvpn.so, libovpnexec.so, libovpnutil.so)
for the requested Android ABI, verifies SHA-256 against lock.json,
and stages them under packages/tunnel_interface/android/src/main/jniLibs/<abi>/.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "third_party" / "openvpn" / "lock.json"


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--abi",
        choices=["arm64-v8a", "armeabi-v7a", "x86_64"],
        default="arm64-v8a",
        help="Target ABI to fetch and verify",
    )
    args = parser.parse_args()

    with LOCK_PATH.open("r", encoding="utf-8") as f:
        lock = json.load(f)

    if args.abi not in lock["artifacts"]:
        raise SystemExit(f"ABI {args.abi} not in lock.json")

    spec = lock["artifacts"][args.abi]
    url = spec["url"]
    expected_apk_sha = spec["sha256"]
    files_spec = spec["files"]

    dest_dir = (
        ROOT
        / "packages"
        / "tunnel_interface"
        / "android"
        / "src"
        / "main"
        / "jniLibs"
        / args.abi
    )
    dest_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="zagros-openvpn-") as tmpdir:
        apk_path = Path(tmpdir) / "app.apk"
        # Check if cached in /tmp/openvpn.apk first
        cached_apk = Path("/tmp/openvpn.apk")
        if cached_apk.exists() and digest(cached_apk) == expected_apk_sha:
            shutil.copy2(cached_apk, apk_path)
        else:
            with urllib.request.urlopen(url, timeout=60) as response, apk_path.open("wb") as out:
                while block := response.read(1024 * 1024):
                    out.write(block)

        actual_apk_sha = digest(apk_path)
        if actual_apk_sha != expected_apk_sha:
            raise SystemExit(
                f"OpenVPN APK SHA-256 mismatch!\nExpected: {expected_apk_sha}\nActual:   {actual_apk_sha}"
            )

        with zipfile.ZipFile(apk_path, "r") as zf:
            for filename, expected_file_sha in files_spec.items():
                member_name = f"lib/{args.abi}/{filename}"
                extracted_path = Path(tmpdir) / filename
                with zf.open(member_name) as src, extracted_path.open("wb") as dst:
                    shutil.copyfileobj(src, dst)

                actual_file_sha = digest(extracted_path)
                if actual_file_sha != expected_file_sha:
                    raise SystemExit(
                        f"OpenVPN {filename} SHA-256 mismatch!\nExpected: {expected_file_sha}\nActual:   {actual_file_sha}"
                    )

                extracted_path.chmod(0o755)
                final_dest = dest_dir / filename
                shutil.move(str(extracted_path), str(final_dest))
                print(f"Verified and staged {filename} ({actual_file_sha[:12]}…)")

    print(f"Staged OpenVPN native binaries for {args.abi} in {dest_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
