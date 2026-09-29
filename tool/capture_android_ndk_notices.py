#!/usr/bin/env python3
"""Capture metadata/notices from the exact Android NDK identified in libwg-go."""

from __future__ import annotations

import argparse
import hashlib
import json
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = "27.0.12077973"
URL = "https://dl.google.com/android/repository/android-ndk-r27-linux.zip"
SIZE = 663_957_918
SHA1 = "5e5cd517bdb98d7e0faf2c494a3041291e71bdcc"
SHA256 = "2f17eb8bcbfdc40201c0b36e9a70826fcd2524ab7a2a235e2c71186c302da1dc"
OUTPUT = ROOT / "third_party" / "wireguard-go" / "android-ndk-r27-notices"
LOCK = OUTPUT / "lock.json"


def file_digest(path: Path, algorithm: str) -> str:
    hasher = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def digest(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def wanted(name: str) -> bool:
    basename = name.rsplit("/", 1)[-1].lower()
    return basename == "source.properties" or basename.startswith(
        ("license", "copying", "notice", "patents")
    )


def capture(source: Path) -> None:
    if (
        source.stat().st_size != SIZE
        or file_digest(source, "sha1") != SHA1
        or file_digest(source, "sha256") != SHA256
    ):
        raise SystemExit("Android NDK r27 archive size/checksum mismatch")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    expected: set[Path] = set()
    records = []
    with zipfile.ZipFile(source) as archive:
        members = sorted(
            name for name in archive.namelist()
            if not name.endswith("/") and wanted(name)
        )
        if len(members) != 15:
            raise SystemExit(f"expected 15 Android NDK metadata/notices, found {len(members)}")
        for index, member in enumerate(members):
            content = archive.read(member)
            destination = OUTPUT / f"{index:02d}-{member.replace('/', '__')}"
            destination.write_bytes(content)
            expected.add(destination)
            records.append(
                {"archive_member": member,
                 "path": str(destination.relative_to(ROOT)),
                 "size": len(content), "sha256": digest(content)}
            )
    for existing in OUTPUT.iterdir():
        if existing.is_file() and existing != LOCK and existing not in expected:
            existing.unlink()
    LOCK.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "ndk_version": VERSION,
                "source_url": URL,
                "archive_size": SIZE,
                "archive_sha1": SHA1,
                "archive_sha256": SHA256,
                "license_notice_files": records,
                "acceptance_status": (
                    "PARTIAL: exact NDK metadata/notices are captured and retained "
                    "ELF identity matches r27; a reproducible per-ABI libwg-go build "
                    "still must run."
                ),
            },
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )


def verify_local() -> None:
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    if (
        lock.get("ndk_version") != VERSION
        or lock.get("archive_size") != SIZE
        or lock.get("archive_sha1") != SHA1
        or lock.get("archive_sha256") != SHA256
        or len(lock.get("license_notice_files", [])) != 15
    ):
        raise SystemExit("Android NDK notice lock metadata mismatch")
    expected = set()
    properties: Path | None = None
    for item in lock["license_notice_files"]:
        path = ROOT / item["path"]
        expected.add(path)
        if item["archive_member"].endswith("/source.properties"):
            properties = path
        if (
            not path.is_file()
            or path.stat().st_size != item["size"]
            or digest(path.read_bytes()) != item["sha256"]
        ):
            raise SystemExit(f"Android NDK notice mismatch: {item['path']}")
    actual = {path for path in OUTPUT.iterdir() if path.is_file() and path != LOCK}
    if actual != expected:
        raise SystemExit("Android NDK notice file set mismatch")
    if properties is None or f"Pkg.Revision = {VERSION}" not in properties.read_text():
        raise SystemExit("Android NDK source.properties version mismatch")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path)
    parser.add_argument("--verify-local", action="store_true")
    args = parser.parse_args()
    if not args.verify_local:
        if args.source is not None:
            capture(args.source)
        else:
            with tempfile.TemporaryDirectory(prefix="zagros-ndk-", dir=ROOT.parent) as directory:
                source = Path(directory) / "ndk.zip"
                with urllib.request.urlopen(URL, timeout=300) as response, source.open("wb") as out:
                    while block := response.read(1024 * 1024):
                        out.write(block)
                capture(source)
    verify_local()
    print("Pinned Android NDK r27 metadata/notice evidence is current.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
