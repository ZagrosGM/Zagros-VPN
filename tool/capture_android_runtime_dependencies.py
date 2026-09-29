#!/usr/bin/env python3
"""Capture and reverify the Android adapter's resolved runtime dependency evidence."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import shutil
import tarfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "third_party" / "android-runtime"
LICENSES = OUTPUT / "licenses"
LOCK = OUTPUT / "lock.json"
SBOM = OUTPUT / "android-runtime-sbom.cdx.json"
DESUGAR_COMMIT = "73170c345e6a762fc6a1f0301bb15218850023ef"
DESUGAR_SOURCE = OUTPUT / "desugar-jdk-libs-2.1.5-source-candidate.tar.gz"
DESUGAR_SOURCE_URL = (
    "https://codeload.github.com/google/desugar_jdk_libs/tar.gz/" + DESUGAR_COMMIT
)
DESUGAR_SOURCE_SIZE = 18_251_068
DESUGAR_SOURCE_SHA256 = "4cd2faa88ecb2450522fd4f0dcd11d6df878d7197b2276fb35532c50267f7a64"

# group|module|version|artifact|sha256|repository|SPDX expression
_ARTIFACT_TEXT = """
androidx.annotation|annotation|1.9.1|annotation-1.9.1.module|f204b05b728a97561718bc716242e47c629c0085a80ee74fca53d4d638bcbe3f|google|Apache-2.0
androidx.annotation|annotation-jvm|1.9.1|annotation-jvm-1.9.1.jar|1e343917ebf27ba96fe4dc52b1cad7fd32b738fbc6355bb6cd5b3b305d7212d0|google|Apache-2.0
androidx.annotation|annotation-jvm|1.9.1|annotation-jvm-1.9.1.module|03fb659177c8618e47425925c11bc91f384703ea26c265be9b25cd79292b511c|google|Apache-2.0
androidx.collection|collection|1.5.0|collection-1.5.0.module|bfeb7bd84f3f7dda7bd73b6709d4a1f61f5a37f843728bae08a067e3df9a0aef|google|Apache-2.0
androidx.collection|collection-jvm|1.5.0|collection-jvm-1.5.0.jar|70b35924e4babcdffa37d0e575ee039c56a2d97123342624c48b603233704341|google|Apache-2.0
androidx.collection|collection-jvm|1.5.0|collection-jvm-1.5.0.module|dde85e292509231b5471bb091b575099d4f43161eb281e87385038a0161072e6|google|Apache-2.0
org.jetbrains.kotlin|kotlin-stdlib|2.2.10|kotlin-stdlib-2.2.10.jar|9c67cc79efd6b9215b49d2a4308f5f3433537376c7c88e89bdd6729bd096e61a|central|Apache-2.0
org.jetbrains.kotlin|kotlin-stdlib|2.2.10|kotlin-stdlib-2.2.10.module|db78df08283591cb67c8b9d2796109eb52b6088d4dfe102b545f20118249713f|central|Apache-2.0
org.jetbrains|annotations|23.0.0|annotations-23.0.0.jar|7b0f19724082cbfcbc66e5abea2b9bc92cf08a1ea11e191933ed43801eb3cd05|central|Apache-2.0
org.jetbrains|annotations|23.0.0|annotations-23.0.0.pom|c9490f655132328df2cfbcfdf743f53fc3916d6c1d10437175a6ca6e3a67771c|central|Apache-2.0
org.jetbrains.kotlinx|kotlinx-coroutines-android|1.10.2|kotlinx-coroutines-android-1.10.2.jar|e713f1f874244115a07571065cffa0f24f5e78300e9720fea16de3af1d75fd41|central|Apache-2.0
org.jetbrains.kotlinx|kotlinx-coroutines-android|1.10.2|kotlinx-coroutines-android-1.10.2.module|092fe38103eec62e94540ca0cd61039ef8f7d8e46694ec033be1f63f0ea2013d|central|Apache-2.0
org.jetbrains.kotlinx|kotlinx-coroutines-core|1.10.2|kotlinx-coroutines-core-1.10.2.module|8fe254177e711a7cd18a3c06d8242fce945f41c2cca13dc19b33ae42a5435016|central|Apache-2.0
org.jetbrains.kotlinx|kotlinx-coroutines-core-jvm|1.10.2|kotlinx-coroutines-core-jvm-1.10.2.jar|5ca175b38df331fd64155b35cd8cae1251fa9ee369709b36d42e0a288ccce3fd|central|Apache-2.0
org.jetbrains.kotlinx|kotlinx-coroutines-core-jvm|1.10.2|kotlinx-coroutines-core-jvm-1.10.2.module|e9e4a74b4dbfe0f5ebeed88d49f3546c3ec3089419b20e5250403135c2c64c53|central|Apache-2.0
org.jetbrains.kotlinx|kotlinx-coroutines-bom|1.10.2|kotlinx-coroutines-bom-1.10.2.pom|faf0c6538e53ddc0499a63664d8e763c216580b2e18e722ccbdf1b431a6afe26|central|Apache-2.0
com.android.tools|desugar_jdk_libs|2.1.5|desugar_jdk_libs-2.1.5.jar|d8044befae095781b9a80bf1faa92edc30382d75d437476784c1bf991598a976|google|GPL-2.0-only WITH Classpath-exception-2.0
com.android.tools|desugar_jdk_libs|2.1.5|desugar_jdk_libs-2.1.5.pom|2e195880f15d4545c8d60b2d2cac52201ccf98db7a29db2577ad5826a930fcca|google|GPL-2.0-only WITH Classpath-exception-2.0
com.android.tools|desugar_jdk_libs_configuration|2.1.5|desugar_jdk_libs_configuration-2.1.5.jar|7bc9051b3a1ec19806311dcb6aa9b9ba7ef9c22caa6f4810da55bde285fb7770|google|BSD-3-Clause
com.android.tools|desugar_jdk_libs_configuration|2.1.5|desugar_jdk_libs_configuration-2.1.5.pom|b2099735b93905d6f01b52e136d1364280cd6a72c6e7ea3be274a6c67703f2b4|google|BSD-3-Clause
"""
ARTIFACTS = [tuple(line.split("|")) for line in _ARTIFACT_TEXT.splitlines() if line]

LOCAL = (
    "ai.zagros.thirdparty",
    "wireguard-tunnel-go-only",
    "1.0.20260102",
)
LOCAL_FILES = {
    "wireguard-tunnel-go-only-1.0.20260102.aar":
        "b8a8c73b701b4f6bd6baf99ae4251f8c90973ccf5b1c6201725f59b39c603931",
    "wireguard-tunnel-go-only-1.0.20260102.pom":
        "b62d9e384476e7a80b59c6582da9806e9bd20c79f8f5df7af8d4e0dd671cd4bc",
}

# filename|immutable URL|sha256
_LICENSE_TEXT = """
LICENSE-KOTLIN-APACHE-2.0.txt|https://raw.githubusercontent.com/JetBrains/kotlin/v2.2.10/license/LICENSE.txt|cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30
LICENSE-JETBRAINS-ANNOTATIONS-APACHE-2.0.txt|https://raw.githubusercontent.com/JetBrains/java-annotations/23.0.0/LICENSE.txt|8c1e966c7855fb54027bcaf6ebe7a43abe4785791e8cf9148c363761d493d097
LICENSE-KOTLINX-COROUTINES-APACHE-2.0.txt|https://raw.githubusercontent.com/Kotlin/kotlinx.coroutines/1.10.2/LICENSE.txt|b1febe6399dffb10d19d35e7663ab16300c93cb0476a94115df1cc0097a8ffd8
LICENSE-DESUGAR-GPL-2.0-WITH-CLASSPATH-EXCEPTION.txt|https://raw.githubusercontent.com/google/desugar_jdk_libs/73170c345e6a762fc6a1f0301bb15218850023ef/LICENSE|4b9abebc4338048a7c2dc184e9f800deb349366bdf28eb23c2677a77b4c87726
"""
REMOTE_LICENSES = [tuple(line.split("|")) for line in _LICENSE_TEXT.splitlines() if line]

EDGES = {
    "pkg:generic/ai.zagros/tunnel-interface@0.2.0?type=android-library": [
        "pkg:maven/ai.zagros.thirdparty/wireguard-tunnel-go-only@1.0.20260102",
        "pkg:maven/androidx.annotation/annotation@1.9.1",
        "pkg:maven/androidx.collection/collection@1.5.0",
        "pkg:maven/org.jetbrains.kotlin/kotlin-stdlib@2.2.10",
        "pkg:maven/org.jetbrains.kotlinx/kotlinx-coroutines-android@1.10.2",
        "pkg:maven/com.android.tools/desugar_jdk_libs@2.1.5",
    ],
    "pkg:maven/ai.zagros.thirdparty/wireguard-tunnel-go-only@1.0.20260102": [
        "pkg:maven/androidx.annotation/annotation@1.9.1",
        "pkg:maven/androidx.collection/collection@1.5.0",
    ],
    "pkg:maven/androidx.annotation/annotation@1.9.1": [
        "pkg:maven/androidx.annotation/annotation-jvm@1.9.1"
    ],
    "pkg:maven/androidx.annotation/annotation-jvm@1.9.1": [
        "pkg:maven/org.jetbrains.kotlin/kotlin-stdlib@2.2.10"
    ],
    "pkg:maven/androidx.collection/collection@1.5.0": [
        "pkg:maven/androidx.collection/collection-jvm@1.5.0"
    ],
    "pkg:maven/androidx.collection/collection-jvm@1.5.0": [
        "pkg:maven/androidx.annotation/annotation@1.9.1",
        "pkg:maven/org.jetbrains.kotlin/kotlin-stdlib@2.2.10",
    ],
    "pkg:maven/org.jetbrains.kotlin/kotlin-stdlib@2.2.10": [
        "pkg:maven/org.jetbrains/annotations@23.0.0"
    ],
    "pkg:maven/org.jetbrains.kotlinx/kotlinx-coroutines-android@1.10.2": [
        "pkg:maven/org.jetbrains.kotlinx/kotlinx-coroutines-core@1.10.2",
        "pkg:maven/org.jetbrains.kotlinx/kotlinx-coroutines-bom@1.10.2",
        "pkg:maven/org.jetbrains.kotlin/kotlin-stdlib@2.2.10",
    ],
    "pkg:maven/org.jetbrains.kotlinx/kotlinx-coroutines-core@1.10.2": [
        "pkg:maven/org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm@1.10.2"
    ],
    "pkg:maven/org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm@1.10.2": [
        "pkg:maven/org.jetbrains/annotations@23.0.0",
        "pkg:maven/org.jetbrains.kotlinx/kotlinx-coroutines-bom@1.10.2",
        "pkg:maven/org.jetbrains.kotlin/kotlin-stdlib@2.2.10",
    ],
    "pkg:maven/com.android.tools/desugar_jdk_libs@2.1.5": [
        "pkg:maven/com.android.tools/desugar_jdk_libs_configuration@2.1.5"
    ],
}


def digest(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def download(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=300) as response:
        return response.read()


def checked(content: bytes, expected: str, label: str) -> bytes:
    actual = digest(content)
    if actual != expected:
        raise SystemExit(f"SHA-256 mismatch for {label}: {actual}")
    return content


def maven_url(group: str, name: str, version: str, artifact: str, repo: str) -> str:
    base = (
        "https://dl.google.com/dl/android/maven2"
        if repo == "google"
        else "https://repo1.maven.org/maven2"
    )
    return f"{base}/{group.replace('.', '/')}/{name}/{version}/{artifact}"


def purl(group: str, name: str, version: str) -> str:
    return f"pkg:maven/{group}/{name}@{version}"


def capture(desugar_source: Path | None) -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    LICENSES.mkdir(parents=True, exist_ok=True)
    records: list[dict[str, object]] = []
    downloaded: dict[str, bytes] = {}
    for group, name, version, artifact, sha, repo, license_id in ARTIFACTS:
        url = maven_url(group, name, version, artifact, repo)
        content = checked(download(url), sha, url)
        downloaded[artifact] = content
        records.append(
            {
                "component": f"{group}:{name}:{version}",
                "purl": purl(group, name, version),
                "artifact": artifact,
                "url": url,
                "size": len(content),
                "sha256": sha,
                "license": license_id,
            }
        )

    local_root = (
        ROOT / "third_party" / "maven" / "ai" / "zagros" / "thirdparty"
        / "wireguard-tunnel-go-only" / "1.0.20260102"
    )
    for artifact, sha in LOCAL_FILES.items():
        path = local_root / artifact
        content = checked(path.read_bytes(), sha, str(path))
        records.append(
            {
                "component": ":".join(LOCAL),
                "purl": purl(*LOCAL),
                "artifact": artifact,
                "path": str(path.relative_to(ROOT)),
                "size": len(content),
                "sha256": sha,
                "license": "NOASSERTION; see native-engine and Go module locks",
            }
        )

    license_records: list[dict[str, object]] = []
    for filename, url, sha in REMOTE_LICENSES:
        content = checked(download(url), sha, url)
        path = LICENSES / filename
        path.write_bytes(content)
        license_records.append(
            {"path": str(path.relative_to(ROOT)), "url": url,
             "size": len(content), "sha256": sha}
        )

    embedded = [
        (
            "LICENSE-ANDROIDX-APACHE-2.0.txt",
            "annotation-jvm-1.9.1.jar",
            "META-INF/androidx/annotation/annotation/LICENSE.txt",
            "809fa1ed21450f59827d1e9aec720bbc4b687434fa22283c6cb5dd82a47ab9c0",
        ),
        (
            "LICENSE-DESUGAR-CONFIG-BSD-3-CLAUSE.txt",
            "desugar_jdk_libs_configuration-2.1.5.jar",
            "LICENSE",
            "68834f116f8ff545f05d14753357b620748156d60ee36b26beab4cb3f317efe4",
        ),
    ]
    for filename, artifact, member, sha in embedded:
        with zipfile.ZipFile(io.BytesIO(downloaded[artifact])) as archive:
            content = checked(archive.read(member), sha, f"{artifact}!/{member}")
        path = LICENSES / filename
        path.write_bytes(content)
        license_records.append(
            {"path": str(path.relative_to(ROOT)),
             "artifact_member": f"{artifact}!/{member}",
             "size": len(content), "sha256": sha}
        )
    with zipfile.ZipFile(io.BytesIO(downloaded["collection-jvm-1.5.0.jar"])) as archive:
        collection_license = archive.read(
            "META-INF/androidx/collection/collection/LICENSE.txt"
        )
    checked(
        collection_license,
        "809fa1ed21450f59827d1e9aec720bbc4b687434fa22283c6cb5dd82a47ab9c0",
        "collection-jvm embedded AndroidX license",
    )

    if desugar_source is None:
        source_content = download(DESUGAR_SOURCE_URL)
        DESUGAR_SOURCE.write_bytes(source_content)
    else:
        shutil.copyfile(desugar_source, DESUGAR_SOURCE)
        source_content = DESUGAR_SOURCE.read_bytes()
    checked(source_content, DESUGAR_SOURCE_SHA256, "desugar source candidate")
    if len(source_content) != DESUGAR_SOURCE_SIZE:
        raise SystemExit("desugar source candidate size mismatch")
    source_legal = [
        (
            "DESUGAR-ADDITIONAL_LICENSE_INFO.txt",
            "ADDITIONAL_LICENSE_INFO",
            "a69bce275ba7a3570af6579cb0f55682cd75fedfcd49e0e8e9022270c447c916",
        ),
        (
            "DESUGAR-ASSEMBLY_EXCEPTION.txt",
            "ASSEMBLY_EXCEPTION",
            "a44eb7b5caf5534c6ef536b21edb40b4d6babf91bf97d9d45596868618b2c6fb",
        ),
    ]
    with tarfile.open(fileobj=io.BytesIO(source_content), mode="r:gz") as archive:
        for filename, member_name, member_sha in source_legal:
            full_name = f"desugar_jdk_libs-{DESUGAR_COMMIT}/{member_name}"
            stream = archive.extractfile(full_name)
            if stream is None:
                raise SystemExit(f"desugar source legal member missing: {member_name}")
            content = checked(stream.read(), member_sha, full_name)
            path = LICENSES / filename
            path.write_bytes(content)
            license_records.append(
                {
                    "path": str(path.relative_to(ROOT)),
                    "source_member": full_name,
                    "size": len(content),
                    "sha256": member_sha,
                }
            )

    lock = {
        "schema_version": 1,
        "scope": ["releaseRuntimeClasspath", "coreLibraryDesugaring"],
        "resolved_with": {
            "gradle": "9.3.1",
            "agp": "9.1.0",
            "agp_built_in_kotlin_stdlib": "2.2.10",
        },
        "artifacts": sorted(records, key=lambda item: (item["component"], item["artifact"])),
        "licenses": sorted(license_records, key=lambda item: item["path"]),
        "desugar_source_candidate": {
            "version_file_value": "2.1.5",
            "commit": DESUGAR_COMMIT,
            "commit_signature": "unsigned",
            "url": DESUGAR_SOURCE_URL,
            "path": str(DESUGAR_SOURCE.relative_to(ROOT)),
            "size": DESUGAR_SOURCE_SIZE,
            "sha256": DESUGAR_SOURCE_SHA256,
        },
        "acceptance_status": (
            "BLOCKED: standalone adapter runtime/desugaring resolution, artifact hashes, "
            "licenses, and a version-matching desugar source candidate are captured. "
            "A final Flutter APK/AAB graph and reproducible desugar artifact-to-source "
            "mapping are still required before distribution."
        ),
    }
    LOCK.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
    SBOM.write_text(
        json.dumps(build_sbom(lock), indent=2) + "\n",
        encoding="utf-8",
    )


def build_sbom(lock: dict[str, object]) -> dict[str, object]:
    grouped: dict[str, list[dict[str, object]]] = {}
    for item in lock["artifacts"]:  # type: ignore[index]
        grouped.setdefault(item["purl"], []).append(item)  # type: ignore[index]
    components = []
    for component_purl, items in sorted(grouped.items()):
        group_name, version = items[0]["component"].rsplit(":", 1)
        group, name = group_name.rsplit(":", 1)
        license_value = items[0]["license"]
        license_entry = (
            {"expression": license_value}
            if not str(license_value).startswith("NOASSERTION")
            else {"license": {"name": "Composite; see locked native notices"}}
        )
        components.append(
            {
                "type": "library",
                "bom-ref": component_purl,
                "group": group,
                "name": name,
                "version": version,
                "purl": component_purl,
                "hashes": [
                    {"alg": "SHA-256", "content": item["sha256"]}
                    for item in sorted(items, key=lambda value: value["artifact"])
                ],
                "licenses": [license_entry],
                "properties": [
                    {"name": "zagros:artifact", "value": item["artifact"]}
                    for item in sorted(items, key=lambda value: value["artifact"])
                ],
            }
        )
    all_refs = {item["bom-ref"] for item in components}
    all_refs.add("pkg:generic/ai.zagros/tunnel-interface@0.2.0?type=android-library")
    dependencies = []
    for ref in sorted(all_refs):
        dependencies.append({"ref": ref, "dependsOn": sorted(EDGES.get(ref, []))})
    sbom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": "urn:uuid:7b9374dd-74a1-5db6-a920-b8a8c73b701b",
        "version": 1,
        "metadata": {
            "component": {
                "type": "library",
                "bom-ref": "pkg:generic/ai.zagros/tunnel-interface@0.2.0?type=android-library",
                "group": "ai.zagros",
                "name": "tunnel-interface",
                "version": "0.2.0",
            },
            "properties": [
                {"name": "zagros:scope", "value": "standalone-adapter-not-final-app"},
                {"name": "zagros:acceptance", "value": "BLOCKED"},
            ],
        },
        "components": components,
        "dependencies": dependencies,
    }
    return sbom


def verify_local() -> None:
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    expected_count = len(ARTIFACTS) + len(LOCAL_FILES)
    if (
        lock.get("scope") != ["releaseRuntimeClasspath", "coreLibraryDesugaring"]
        or lock.get("resolved_with", {}).get("agp_built_in_kotlin_stdlib") != "2.2.10"
        or len(lock.get("artifacts", [])) != expected_count
        or len(lock.get("licenses", [])) != len(REMOTE_LICENSES) + 4
        or not str(lock.get("acceptance_status", "")).startswith("BLOCKED:")
    ):
        raise SystemExit("Android runtime lock metadata mismatch")
    expected_remote = {
        (
            f"{group}:{name}:{version}",
            artifact,
            sha,
            maven_url(group, name, version, artifact, repo),
            license_id,
        )
        for group, name, version, artifact, sha, repo, license_id in ARTIFACTS
    }
    actual_remote = {
        (
            item["component"],
            item["artifact"],
            item["sha256"],
            item["url"],
            item["license"],
        )
        for item in lock["artifacts"]
        if "url" in item
    }
    if actual_remote != expected_remote:
        raise SystemExit("Android remote runtime artifact lock differs from pinned inputs")
    expected_local = {(artifact, sha) for artifact, sha in LOCAL_FILES.items()}
    actual_local = {
        (item["artifact"], item["sha256"])
        for item in lock["artifacts"]
        if "path" in item
    }
    if actual_local != expected_local:
        raise SystemExit("Android local runtime artifact lock differs from pinned inputs")
    for item in lock["licenses"]:
        path = ROOT / item["path"]
        if (
            not path.is_file()
            or path.stat().st_size != item["size"]
            or digest(path.read_bytes()) != item["sha256"]
        ):
            raise SystemExit(f"Android runtime license mismatch: {item['path']}")
    source = lock["desugar_source_candidate"]
    source_path = ROOT / source["path"]
    if (
        not source_path.is_file()
        or source_path.stat().st_size != source["size"]
        or digest(source_path.read_bytes()) != source["sha256"]
    ):
        raise SystemExit("desugar source candidate mismatch")
    for item in lock["artifacts"]:
        if "path" not in item:
            continue
        path = ROOT / item["path"]
        if (
            not path.is_file()
            or path.stat().st_size != item["size"]
            or digest(path.read_bytes()) != item["sha256"]
        ):
            raise SystemExit(f"local Android artifact mismatch: {item['path']}")
    expected_sbom = json.dumps(build_sbom(lock), indent=2) + "\n"
    if not SBOM.is_file() or SBOM.read_text(encoding="utf-8") != expected_sbom:
        raise SystemExit("Android runtime SBOM is stale")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--desugar-source", type=Path)
    parser.add_argument("--verify-local", action="store_true")
    args = parser.parse_args()
    if not args.verify_local:
        capture(args.desugar_source)
    verify_local()
    print("Android adapter runtime dependency/license evidence is current.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
