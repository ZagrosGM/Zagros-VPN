#!/usr/bin/env python3
"""Capture and verify license evidence for the pinned wireguard-go module zips."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_LOCK = ROOT / "third_party" / "wireguard-go" / "module-lock.json"
OUTPUT = ROOT / "third_party" / "wireguard-go" / "module-licenses"
SOURCE_LOCK = ROOT / "third_party" / "wireguard-go" / "source-license-lock.json"


def sha256(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def zip_h1(path: Path) -> str:
    lines = []
    with zipfile.ZipFile(path) as archive:
        for name in sorted(item.filename for item in archive.infolist() if not item.is_dir()):
            lines.append(f"{sha256(archive.read(name))}  {name}\n")
    result = hashlib.sha256("".join(lines).encode()).digest()
    return "h1:" + base64.b64encode(result).decode()


def is_notice(name: str) -> bool:
    basename = name.rsplit("/", 1)[-1].lower()
    return basename.startswith(("license", "copying", "notice", "patents"))


def safe_name(value: str) -> str:
    return value.replace("/", "_").replace(":", "_")


def capture() -> None:
    lock = json.loads(MODULE_LOCK.read_text(encoding="utf-8"))
    OUTPUT.mkdir(parents=True, exist_ok=True)
    expected: set[Path] = set()
    records = []
    temp = ROOT.parent / ".wireguard-go-module.zip"
    try:
        for module in lock["modules"]:
            name, version = module["module"], module["version"]
            url = (
                "https://proxy.golang.org/"
                + urllib.parse.quote(name, safe="/")
                + "/@v/"
                + urllib.parse.quote(version, safe="")
                + ".zip"
            )
            with urllib.request.urlopen(url, timeout=120) as response, temp.open("wb") as out:
                while block := response.read(1024 * 1024):
                    out.write(block)
            actual_h1 = zip_h1(temp)
            if actual_h1 != module["go_sum"]:
                raise SystemExit(f"Go h1 mismatch for {name}@{version}: {actual_h1}")
            license_files = []
            with zipfile.ZipFile(temp) as archive:
                members = sorted(
                    (
                        item for item in archive.infolist()
                        if not item.is_dir() and is_notice(item.filename)
                    ),
                    key=lambda item: item.filename,
                )
                if not members:
                    raise SystemExit(f"No license/notice in {name}@{version}")
                directory = OUTPUT / safe_name(f"{name}_{version}")
                directory.mkdir(parents=True, exist_ok=True)
                for index, member in enumerate(members):
                    content = archive.read(member)
                    destination = directory / f"{index:02d}-{safe_name(member.filename)}"
                    destination.write_bytes(content)
                    expected.add(destination)
                    license_files.append(
                        {
                            "module_member": member.filename,
                            "path": str(destination.relative_to(ROOT)),
                            "size": len(content),
                            "sha256": sha256(content),
                        }
                    )
            records.append(
                {
                    "module": name,
                    "version": version,
                    "go_sum": module["go_sum"],
                    "source_url": url,
                    "zip_size": temp.stat().st_size,
                    "zip_sha256": sha256(temp.read_bytes()),
                    "license_notice_files": license_files,
                }
            )
    finally:
        temp.unlink(missing_ok=True)
    for existing in OUTPUT.rglob("*"):
        if existing.is_file() and existing not in expected:
            existing.unlink()
    for directory in sorted(OUTPUT.rglob("*"), reverse=True):
        if directory.is_dir() and not any(directory.iterdir()):
            directory.rmdir()
    SOURCE_LOCK.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "module_lock": str(MODULE_LOCK.relative_to(ROOT)),
                "modules": records,
                "acceptance_status": (
                    "PARTIAL: module zips match Go h1 sums and module-level "
                    "license/notice members are captured; Android reachable-package "
                    "and native reproduction evidence remain required."
                ),
            },
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )


def verify_local() -> None:
    lock = json.loads(SOURCE_LOCK.read_text(encoding="utf-8"))
    modules = json.loads(MODULE_LOCK.read_text(encoding="utf-8"))["modules"]
    if len(lock.get("modules", [])) != 8 or [
        (item["module"], item["version"], item["go_sum"])
        for item in lock["modules"]
    ] != [
        (item["module"], item["version"], item["go_sum"])
        for item in modules
    ]:
        raise SystemExit("Go source-license lock does not match module lock")
    expected = set()
    for module in lock["modules"]:
        for item in module["license_notice_files"]:
            path = ROOT / item["path"]
            expected.add(path)
            if (
                not path.is_file()
                or path.stat().st_size != item["size"]
                or sha256(path.read_bytes()) != item["sha256"]
            ):
                raise SystemExit(f"Go module license mismatch: {item['path']}")
    actual = {path for path in OUTPUT.rglob("*") if path.is_file()}
    if actual != expected:
        raise SystemExit("Go module license file set mismatch")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify-local", action="store_true")
    args = parser.parse_args()
    if not args.verify_local:
        capture()
    verify_local()
    print("Captured wireguard-go module license evidence is current.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
