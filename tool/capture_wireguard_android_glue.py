#!/usr/bin/env python3
"""Capture the exact tagged Android libwg-go build inputs."""

from __future__ import annotations

import argparse
import hashlib
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "third_party" / "wireguard-go" / "android-build-source"
LOCK = OUTPUT / "lock.json"
BASE = "https://git.zx2c4.com/wireguard-android/plain/tunnel/tools/libwg-go"
FILES = {
    "Makefile": (2135, "4b85a3bc286c00c5a360020d750dde3d0b6c3b21a0824eb50a60cc54b4f1db6d"),
    "api-android.go": (4647, "42cd27f8f4744aaed4d77bb8c1ac6a679501925576050edfec9245a1b6c902c0"),
    "jni.c": (2185, "f8758d642c1d2cd1dd1abe45f54b95481006c8b797347dd6e0f35703320b246b"),
    "go.mod": (319, "0967ad9b3b9e28a0457fea1d96cfd8d5028bfa84864d5624bb256ea9c1106971"),
    "go.sum": (1440, "5ee72cabd556981382ad463873228b6b0d54004664ec4aa3ada9e81efc288204"),
    "goruntime-boottime-over-monotonic.diff": (5069, "149ab7d9a1c20dad61fe279a837e0e0c81c6b2f5584614ac4d4cde67008755f0"),
}


def digest(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def capture() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    records = []
    for name, (size, sha) in FILES.items():
        url = f"{BASE}/{name}?h=1.0.20260102"
        with urllib.request.urlopen(url, timeout=120) as response:
            content = response.read()
        if len(content) != size or digest(content) != sha:
            raise SystemExit(f"tagged Android build input mismatch: {name}")
        path = OUTPUT / name
        path.write_bytes(content)
        records.append(
            {"name": name, "url": url, "path": str(path.relative_to(ROOT)),
             "size": size, "sha256": sha}
        )
    LOCK.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "tag": "1.0.20260102",
                "tag_object": "3831cab2da844319291459308a6e535d36dde4b3",
                "commit": "09b75c2bd37f749e2a8c85876394854113c74be7",
                "files": records,
                "acceptance_status": (
                    "PARTIAL: exact tagged libwg-go build glue is captured; signed-tag "
                    "and parent-snapshot verification are separate gates, and native "
                    "binary reproduction remains required."
                ),
            },
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )


def verify_local() -> None:
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    if lock.get("tag") != "1.0.20260102" or len(lock.get("files", [])) != 6:
        raise SystemExit("Android build-source lock metadata mismatch")
    for item in lock["files"]:
        expected = FILES.get(item["name"])
        path = ROOT / item["path"]
        if (
            expected != (item["size"], item["sha256"])
            or not path.is_file()
            or path.stat().st_size != item["size"]
            or digest(path.read_bytes()) != item["sha256"]
        ):
            raise SystemExit(f"Android build-source mismatch: {item['name']}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify-local", action="store_true")
    args = parser.parse_args()
    if not args.verify_local:
        capture()
    verify_local()
    print("Android libwg-go build-glue evidence is current.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
