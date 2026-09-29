#!/usr/bin/env python3
"""Reproduce the pinned GoBackend-only WireGuard Android AAR.

The upstream AAR also contains libwg.so and libwg-quick.so from GPL-2.0
wireguard-tools. Zagros does not call those libraries and does not vendor or
package them. This tool verifies the exact upstream artifact, removes only
those members, and verifies the byte-for-byte reproducible derived artifact.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import os
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
URL = (
    "https://repo1.maven.org/maven2/com/wireguard/android/tunnel/"
    "1.0.20260102/tunnel-1.0.20260102.aar"
)
UPSTREAM_SIZE = 5_830_762
UPSTREAM_SHA256 = "2b9c16db026496123e4db695d26d03d1958a201096c7c4c89b21077dc70f3119"
DERIVED_SHA256 = "b8a8c73b701b4f6bd6baf99ae4251f8c90973ccf5b1c6201725f59b39c603931"
OUTPUT = (
    ROOT
    / "third_party"
    / "maven"
    / "ai"
    / "zagros"
    / "thirdparty"
    / "wireguard-tunnel-go-only"
    / "1.0.20260102"
    / "wireguard-tunnel-go-only-1.0.20260102.aar"
)
EXCLUDED_NAMES = {"libwg.so", "libwg-quick.so"}
EXPECTED_EXCLUDED_MEMBERS = {
    f"jni/{abi}/{library}"
    for abi in ("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
    for library in EXCLUDED_NAMES
}


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def verify_upstream(path: Path) -> None:
    if path.stat().st_size != UPSTREAM_SIZE or digest(path) != UPSTREAM_SHA256:
        raise SystemExit("upstream WireGuard Android AAR size or SHA-256 mismatch")


def derive(source: Path, destination: Path) -> None:
    removed: set[str] = set()
    with zipfile.ZipFile(source, "r") as input_archive, zipfile.ZipFile(
        destination, "w"
    ) as output_archive:
        for source_info in sorted(
            input_archive.infolist(), key=lambda entry: entry.filename
        ):
            if Path(source_info.filename).name in EXCLUDED_NAMES:
                removed.add(source_info.filename)
                continue
            content = input_archive.read(source_info)
            info = copy.copy(source_info)
            # Stored entries avoid zlib-version-dependent deflate output, making
            # the derivative stable across build hosts and Python releases.
            info.compress_type = zipfile.ZIP_STORED
            info.compress_size = info.file_size
            output_archive.writestr(info, content)
    if removed != EXPECTED_EXCLUDED_MEMBERS:
        raise SystemExit("upstream AAR GPL member set does not match the reviewed lock")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source",
        type=Path,
        help="use a local upstream AAR instead of downloading the pinned URL",
    )
    parser.add_argument("--output", type=Path, default=OUTPUT)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="zagros-wireguard-") as directory:
        temporary = Path(directory)
        source = args.source
        if source is None:
            source = temporary / "upstream.aar"
            with urllib.request.urlopen(URL, timeout=60) as response, source.open(
                "wb"
            ) as output:
                while block := response.read(1024 * 1024):
                    output.write(block)
        verify_upstream(source)

        args.output.parent.mkdir(parents=True, exist_ok=True)
        staged = args.output.with_suffix(args.output.suffix + ".tmp")
        try:
            staged.unlink(missing_ok=True)
            derive(source, staged)
            if digest(staged) != DERIVED_SHA256:
                raise SystemExit("derived GoBackend-only AAR SHA-256 mismatch")

            with zipfile.ZipFile(staged) as archive:
                native_names = {
                    Path(name).name
                    for name in archive.namelist()
                    if name.startswith("jni/") and name.endswith(".so")
                }
            if native_names != {"libwg-go.so"}:
                raise SystemExit("derived AAR contains an unexpected native library set")
            os.replace(staged, args.output)
        finally:
            staged.unlink(missing_ok=True)

    print(f"Prepared {args.output} ({DERIVED_SHA256}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
