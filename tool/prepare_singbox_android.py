#!/usr/bin/env python3
"""Stage and verify pinned sing-box Android daemon binaries.

Validates the exact upstream release archives, extracts the standalone PIE
executable for the requested Android ABI, verifies its SHA-256 against lock.json,
and stages it under the specified jniLibs output path.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tarfile
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "third_party" / "singbox" / "lock.json"


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
        choices=["arm64-v8a", "armeabi-v7a", "x86_64", "linux-amd64"],
        default="arm64-v8a",
        help="Target ABI to fetch and verify",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Destination path for the verified binary",
    )
    args = parser.parse_args()

    with LOCK_PATH.open("r", encoding="utf-8") as f:
        lock = json.load(f)

    if args.abi not in lock["artifacts"]:
        raise SystemExit(f"ABI {args.abi} not in lock.json")

    spec = lock["artifacts"][args.abi]
    expected_sha256 = spec["sha256"]
    url = spec["url"]
    member = spec["archive_member"]

    output_path = args.output
    if output_path is None:
        if args.abi == "linux-amd64":
            output_path = ROOT / "third_party" / "singbox" / "bin" / "sing-box"
        else:
            output_path = (
                ROOT
                / "packages"
                / "tunnel_interface"
                / "android"
                / "src"
                / "main"
                / "jniLibs"
                / args.abi
                / "libsingbox.so"
            )

    output_path.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="zagros-singbox-") as tmpdir:
        archive_path = Path(tmpdir) / "archive.tar.gz"
        with urllib.request.urlopen(url, timeout=60) as response, archive_path.open("wb") as out:
            while block := response.read(1024 * 1024):
                out.write(block)

        with tarfile.open(archive_path, "r:gz") as tar:
            extracted_bin = Path(tmpdir) / "extracted_singbox"
            with tar.extractfile(member) as src_file, extracted_bin.open("wb") as dst_file:
                while block := src_file.read(1024 * 1024):
                    dst_file.write(block)

        actual_sha = digest(extracted_bin)
        if actual_sha != expected_sha256:
            raise SystemExit(
                f"sing-box {args.abi} SHA-256 mismatch!\nExpected: {expected_sha256}\nActual:   {actual_sha}"
            )

        extracted_bin.chmod(0o755)
        import shutil
        shutil.move(extracted_bin, output_path)

    print(f"Verified and staged {args.abi} binary at {output_path} ({expected_sha256})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
