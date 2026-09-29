#!/usr/bin/env python3
"""Verify WireGuard Android signed-tag identity and vendored parent source snapshot."""

from __future__ import annotations

import argparse
import hashlib
import json
import tarfile
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TAG = "1.0.20260102"
TAG_OBJECT = "3831cab2da844319291459308a6e535d36dde4b3"
COMMIT = "09b75c2bd37f749e2a8c85876394854113c74be7"
ARCHIVE_URL = "https://github.com/WireGuard/wireguard-android/archive/refs/tags/1.0.20260102.tar.gz"
ARCHIVE_SIZE = 424_849
ARCHIVE_SHA256 = "0d12c37fabf73fe88983e779c077aaad55ff62ea5749bad89ec1a27c60d7ade3"
ARCHIVE = ROOT / "third_party" / "wireguard-android" / "wireguard-android-1.0.20260102-source.tar.gz"
GLUE_LOCK = ROOT / "third_party" / "wireguard-go" / "android-build-source" / "lock.json"


def file_hash(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def api(path: str) -> dict[str, object]:
    request = urllib.request.Request(
        "https://api.github.com/repos/WireGuard/wireguard-android/" + path,
        headers={"Accept": "application/vnd.github+json", "User-Agent": "zagros-source-verifier"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)


def verify_archive(path: Path) -> None:
    if path.stat().st_size != ARCHIVE_SIZE or file_hash(path) != ARCHIVE_SHA256:
        raise SystemExit("WireGuard Android source snapshot size/checksum mismatch")
    glue = json.loads(GLUE_LOCK.read_text(encoding="utf-8"))
    prefix = f"wireguard-android-{TAG}/tunnel/tools/libwg-go/"
    with tarfile.open(path, "r:gz") as archive:
        for item in glue["files"]:
            member = archive.extractfile(prefix + item["name"])
            if member is None:
                raise SystemExit(f"source snapshot member missing: {item['name']}")
            content = member.read()
            captured = (ROOT / item["path"]).read_bytes()
            if content != captured or hashlib.sha256(content).hexdigest() != item["sha256"]:
                raise SystemExit(f"source snapshot/build-glue mismatch: {item['name']}")


def verify_remote() -> None:
    reference = api(f"git/ref/tags/{TAG}")
    obj = reference.get("object", {})
    if obj.get("type") != "tag" or obj.get("sha") != TAG_OBJECT:
        raise SystemExit("GitHub tag reference identity mismatch")
    tag = api(f"git/tags/{TAG_OBJECT}")
    target = tag.get("object", {})
    verification = tag.get("verification", {})
    if (
        target.get("type") != "commit"
        or target.get("sha") != COMMIT
        or verification.get("verified") is not True
        or verification.get("reason") != "valid"
    ):
        raise SystemExit("WireGuard Android tag signature/target verification failed")
    with tempfile.TemporaryDirectory(prefix="zagros-wireguard-source-", dir=ROOT.parent) as directory:
        downloaded = Path(directory) / "source.tar.gz"
        with urllib.request.urlopen(ARCHIVE_URL, timeout=120) as response, downloaded.open("wb") as out:
            while block := response.read(1024 * 1024):
                out.write(block)
        verify_archive(downloaded)
        if downloaded.read_bytes() != ARCHIVE.read_bytes():
            raise SystemExit("vendored WireGuard source snapshot differs from remote bytes")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--local-only", action="store_true")
    args = parser.parse_args()
    verify_archive(ARCHIVE)
    if not args.local_only:
        verify_remote()
    print("WireGuard Android signed tag and source snapshot are current.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
