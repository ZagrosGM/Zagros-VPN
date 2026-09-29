#!/usr/bin/env python3
"""Capture license/notice members from the exact Go toolchain used by libwg-go."""

from __future__ import annotations

import argparse
import hashlib
import json
import tarfile
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
URL = "https://dl.google.com/go/go1.24.3.linux-amd64.tar.gz"
SIZE = 78_558_709
SHA256 = "3333f6ea53afa971e9078895eaa4ac7204a8c6b5c68c10e6bc9a33e8e391bdd8"
OUTPUT = ROOT / "third_party" / "wireguard-go" / "go-toolchain-licenses"
LOCK = OUTPUT / "lock.json"


def file_hash(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def digest(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def wanted(name: str) -> bool:
    basename = name.rsplit("/", 1)[-1].lower()
    return basename.startswith(("license", "copying", "notice", "patents"))


def capture(source: Path) -> None:
    if source.stat().st_size != SIZE or file_hash(source) != SHA256:
        raise SystemExit("Go 1.24.3 toolchain archive size/checksum mismatch")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    expected: set[Path] = set()
    records = []
    with tarfile.open(source, "r:gz") as archive:
        members = sorted(
            (item for item in archive.getmembers() if item.isfile() and wanted(item.name)),
            key=lambda item: item.name,
        )
        if len(members) != 33:
            raise SystemExit(f"expected 33 Go toolchain notices, found {len(members)}")
        for index, member in enumerate(members):
            stream = archive.extractfile(member)
            if stream is None:
                raise SystemExit(f"cannot read Go toolchain member: {member.name}")
            content = stream.read()
            destination = OUTPUT / f"{index:02d}-{member.name.replace('/', '__')}"
            destination.write_bytes(content)
            expected.add(destination)
            records.append(
                {"archive_member": member.name,
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
                "go_version": "1.24.3",
                "platform": "linux-amd64",
                "source_url": URL,
                "tarball_size": SIZE,
                "tarball_sha256": SHA256,
                "license_notice_files": records,
                "acceptance_status": (
                    "PARTIAL: all license/notice/PATENTS members in the pinned "
                    "toolchain archive are captured; native binary reproduction "
                    "and final linked-package analysis remain required."
                ),
            },
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )


def verify_local() -> None:
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    if (
        lock.get("go_version") != "1.24.3"
        or lock.get("platform") != "linux-amd64"
        or lock.get("tarball_size") != SIZE
        or lock.get("tarball_sha256") != SHA256
        or len(lock.get("license_notice_files", [])) != 33
    ):
        raise SystemExit("Go toolchain notice lock metadata mismatch")
    expected = set()
    for item in lock["license_notice_files"]:
        path = ROOT / item["path"]
        expected.add(path)
        if (
            not path.is_file()
            or path.stat().st_size != item["size"]
            or digest(path.read_bytes()) != item["sha256"]
        ):
            raise SystemExit(f"Go toolchain notice mismatch: {item['path']}")
    actual = {path for path in OUTPUT.iterdir() if path.is_file() and path != LOCK}
    if actual != expected:
        raise SystemExit("Go toolchain notice file set mismatch")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path)
    parser.add_argument("--verify-local", action="store_true")
    args = parser.parse_args()
    if not args.verify_local:
        if args.source is not None:
            capture(args.source)
        else:
            with tempfile.TemporaryDirectory(prefix="zagros-go-", dir=ROOT.parent) as directory:
                source = Path(directory) / "go.tar.gz"
                with urllib.request.urlopen(URL, timeout=300) as response, source.open("wb") as out:
                    while block := response.read(1024 * 1024):
                        out.write(block)
                capture(source)
    verify_local()
    print("Pinned Go toolchain license/notice evidence is current.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
