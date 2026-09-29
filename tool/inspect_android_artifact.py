#!/usr/bin/env python3
"""Inspect a built APK/AAB against the reviewed WireGuard native manifest.

This is a fail-closed distribution gate. The consumed AAR retains only the
reviewed MIT wireguard-go backend; any wireguard-tools native member is an
unexpected GPL-bearing package input and is rejected without a bypass.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "third_party" / "wireguard-android" / "embedded-native-sha256.json"
WIREGUARD_LIBRARIES = {"libwg-go.so", "libwg.so", "libwg-quick.so"}
GPL_LIBRARIES = {"libwg.so", "libwg-quick.so"}


def canonical_name(member: str) -> str | None:
    parts = member.split("/")
    if len(parts) < 3 or parts[-1] not in WIREGUARD_LIBRARIES:
        return None
    library_index = len(parts) - 1
    abi = parts[library_index - 1]
    return f"jni/{abi}/{parts[-1]}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact", type=Path)
    args = parser.parse_args()

    if not args.artifact.is_file():
        parser.error(f"artifact not found: {args.artifact}")
    expected = json.loads(MANIFEST.read_text(encoding="utf-8"))["files"]
    discovered: dict[str, dict[str, int | str]] = {}
    errors: list[str] = []
    with zipfile.ZipFile(args.artifact) as archive:
        for member in archive.namelist():
            canonical = canonical_name(member)
            if canonical is None:
                continue
            if canonical in discovered:
                errors.append(f"duplicate WireGuard native member: {canonical}")
                continue
            content = archive.read(member)
            discovered[canonical] = {
                "size": len(content),
                "sha256": hashlib.sha256(content).hexdigest(),
            }

    if not discovered:
        errors.append("no WireGuard native libraries were found")
    for name, details in discovered.items():
        if expected.get(name) != details:
            errors.append(f"unreviewed or modified WireGuard native member: {name}")
    names = {Path(name).name for name in discovered}
    if "libwg-go.so" not in names:
        errors.append("the reviewed Go backend is absent")
    present_gpl = sorted(names & GPL_LIBRARIES)
    if present_gpl:
        errors.append(
            "distribution blocked: embedded GPL wireguard-tools members are present: "
            + ", ".join(present_gpl)
        )

    if errors:
        for error in errors:
            print(f"ANDROID ARTIFACT: {error}", file=sys.stderr)
        return 1
    print("Android artifact contains only reviewed WireGuard native members.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
