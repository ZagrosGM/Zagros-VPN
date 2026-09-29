#!/usr/bin/env python3
"""Verify retained libwg-go ELF dependencies and embedded toolchain identity."""

from __future__ import annotations

import argparse
import re
import subprocess
import tempfile
import zipfile
from pathlib import Path

EXPECTED_NEEDED = {"liblog.so", "libdl.so", "libc.so"}
EXPECTED_COMMENT = (
    "Android (12027248, +pgo, +bolt, +lto, +mlgo, based on r522817) "
    "clang version 18.0.1 (https://android.googlesource.com/toolchain/llvm-project "
    "d8003a456d14a3deb8054cdaa529ffbf02d9b262)"
)


def readelf(*arguments: str, path: Path) -> str:
    return subprocess.run(
        ["readelf", *arguments, str(path)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact", type=Path)
    args = parser.parse_args()
    if not args.artifact.is_file():
        parser.error(f"artifact not found: {args.artifact}")
    with zipfile.ZipFile(args.artifact) as archive, tempfile.TemporaryDirectory(
        prefix="zagros-elf-"
    ) as directory:
        members = sorted(
            name for name in archive.namelist()
            if re.fullmatch(r"jni/[^/]+/libwg-go[.]so", name)
        )
        if len(members) != 4:
            raise SystemExit(f"expected four retained libwg-go ELFs, found {len(members)}")
        for index, member in enumerate(members):
            path = Path(directory) / f"{index}.so"
            content = archive.read(member)
            path.write_bytes(content)
            needed = set(
                re.findall(r"Shared library: \[([^]]+)]", readelf("-d", path=path))
            )
            if needed != EXPECTED_NEEDED:
                raise SystemExit(f"{member}: unexpected NEEDED set: {sorted(needed)}")
            if EXPECTED_COMMENT not in readelf("-p", ".comment", path=path):
                raise SystemExit(f"{member}: unexpected Clang identity")
            android_note = readelf("-x", ".note.android.ident", path=path)
            if (
                "6f696400 18000000 72323700" not in android_note
                or "31323037 37393733" not in android_note
            ):
                raise SystemExit(f"{member}: unexpected Android API/NDK identity")
            if b"go1.24.3" not in content:
                raise SystemExit(f"{member}: unexpected Go toolchain identity")
    print("All retained libwg-go ELFs match the locked dependency/toolchain identity.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
