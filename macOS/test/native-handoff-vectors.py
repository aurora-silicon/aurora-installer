#!/usr/bin/env python3
"""Synthetic native handoff fixtures from the locked stage/layout contract."""
import argparse
import ast
import base64
import collections
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests/OmarchyAppleInstallerTrustCoreTests/Fixtures"
sys.path.insert(0, str(ROOT / "Engine/overlay/src"))
from omarchy_contract import Journal


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def uid(number):
    return str(uuid.UUID(int=number)).upper()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def reference():
    lock = json.loads((ROOT / "Engine/source-lock.json").read_text())
    name = "overlay/src/omarchy_asahi.py"
    record = next(item for item in lock["downstream_overlay"]["files"] if item["path"] == name)
    source = (ROOT / "Engine" / name).read_bytes()
    assert digest(source) == record["sha256"]
    allowed = {"BoardStage1", "COMMON_STAGE1", "BOARD_STAGE1", "ESP_SOURCE", "ESP_STAGE2", "BOARD_STAGE2"}
    nodes = [node for node in ast.parse(source).body if
             isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name) and node.targets[0].id in allowed
             or isinstance(node, ast.FunctionDef) and node.name == "esp_board_layout"
             or isinstance(node, ast.ClassDef) and node.name == "AsahiAdapterError"]
    values = {"collections": collections}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), "locked-esp-layout", "exec"), values)
    return values["esp_board_layout"], digest(source)


def generate():
    layout, source_hash = reference()
    files = {"fedora.icns": b"synthetic icon", "boot.img": b"boot" * 1024,
             "root.img": b"root" * 1024, "esp/EFI/BOOT/BOOTAA64.EFI": b"synthetic EFI",
             "esp/m1n1/boot.bin": b"generic stage2", "esp/m1n1/boot-j700.bin": b"neo stage2",
             "esp/aurora/stage1.bin": b"common stage1", "esp/aurora/stage1-j700.bin": b"neo stage1",
             "esp/aurora/stage1-j613.bin": b"other stage1"}
    payload = io.BytesIO()
    with zipfile.ZipFile(payload, "w") as archive:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_STORED
            archive.writestr(info, data)
    payload = payload.getvalue()
    unit = 1 << 20
    partitions = [
        dict(identifier="disk0s1", uuid=uid(1), type="Apple_APFS_ISC", offset=20480, size=unit // 2, name=""),
        dict(identifier="disk0s2", uuid=uid(2), type="Apple_APFS", offset=unit, size=32 * unit, name="Macintosh HD"),
        dict(identifier="disk0s4", uuid=uid(4), type="Apple_APFS", offset=64 * unit, size=8 * unit, name="Fedora Aurora Remix"),
        dict(identifier="disk0s5", uuid=uid(5), type="EFI", offset=72 * unit, size=8 * unit, name="EFI - FEDOR"),
        dict(identifier="disk0s6", uuid=uid(6), type="Linux Filesystem", offset=80 * unit, size=16 * unit, name=""),
        dict(identifier="disk0s7", uuid=uid(7), type="Linux Filesystem", offset=96 * unit, size=32 * unit, name=""),
        dict(identifier="disk0s3", uuid=uid(3), type="Apple_APFS_Recovery", offset=240 * unit, size=8 * unit, name=""),
    ]

    def volume(number, identifier, role, group=None):
        return dict(uuid=uid(number), identifier=identifier, name=role, roles=[role], group=group)

    snapshot = dict(disk="disk0", devicePath="synthetic/internal", diskSize=256 * unit,
                    macOSStoreUUID=uid(2), macOSContainerUUID=uid(101), partitions=partitions,
                    containers=[dict(uuid=uid(101), storeUUID=uid(2), volumes=[
                        volume(10, "disk4s1", "System", uid(90)), volume(11, "disk4s2", "Data", uid(90)),
                        volume(12, "disk4s3", "Preboot"), volume(13, "disk4s4", "Recovery")]),
                        dict(uuid=uid(102), storeUUID=uid(4), volumes=[
                        volume(20, "disk8s1", "System", uid(91)), volume(21, "disk8s2", "Data", uid(91)),
                        volume(22, "disk8s3", "Preboot"), volume(23, "disk8s4", "Recovery")])])
    cases = []
    for title, device, common in [("neo-common", "j700", True), ("neo-board", "j700", False),
                                   ("m1-common", "j314s", True), ("m1-generic", "j314s", False),
                                   ("neo-common-replace", "j700", True)]:
        board = device + "ap"
        mapping = layout(board, [name for name in files if name.startswith("esp/")], common_allowed=common)
        tree_hash = hashlib.sha256()
        for name in sorted(mapping):
            raw = name.encode()
            tree_hash.update(len(raw).to_bytes(8, "big") + raw + hashlib.sha256(files[name]).digest())
        template = dict(omarchy_target="apple-silicon-full-os", icon="fedora.icns", partitions=[
            dict(name="EFI", type="EFI", source="esp"), dict(name="Boot", type="Linux", image="boot.img"),
            dict(name="Root", type="Linux", image="root.img")])
        if common:
            template["aurora_stage1"] = dict(kind="common-raw-v1", qualified_machines={board: ["26.6.2"]})
        metadata = encoded(dict(os_list=[template]))
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "journal.jsonl"
            journal = Journal(str(path))
            journal.inspection("apple," + device, "supported")
            kind = "replace" if title.endswith("-replace") else "free"
            candidate = dict(kind=kind, source_identifier="disk0s2",
                offset_bytes=64 * unit, length_bytes=64 * unit, minimum_install_bytes=40 * unit,
                minimum_container_bytes=0)
            if kind == "replace":
                candidate["identity_digest"] = "sha256:" + digest(b"synthetic prior installation")
            layout_digest = journal.inventory("disk0", [candidate])
            plan_digest = journal.plan(device_identifier="apple," + device, layout_digest=layout_digest,
                candidate_kind=kind, source_identifier="disk0s2", requested_length_bytes=64 * unit,
                engine_version="fixture", engine_digest="sha256:" + digest(b"synthetic engine"),
                metadata_digest="sha256:" + digest(metadata), payload_digest="sha256:" + digest(payload),
                required_human_steps=["enterOneTrueRecovery"])
            target = encoded(dict(plan_digest=plan_digest, partition_identifier="disk0s4", uuid=uid(4),
                                  offset_bytes=64 * unit, size_bytes=8 * unit))
            populated = []
            for index, (name, population) in enumerate([("EFI", "esp"), ("Boot", "boot.img"), ("Root", "root.img")]):
                part = partitions[3 + index]
                populated.append(dict(name=name, population=population, partition_identifier=part["identifier"],
                    partition_uuid=part["uuid"].lower(), partition_size_bytes=part["size"],
                    installed_bytes=sum(len(files[key]) for key in mapping) if index == 0 else len(files[population]),
                    verification=["copied-tree-sha256", "raw-prefix-sha256", "source-sha256-write-flushed-v1"][index],
                    content_sha256=tree_hash.hexdigest() if index == 0 else digest(files[population])))
            installed = encoded(dict(plan_digest=plan_digest, apfs_vgid=uid(91), system_volume="disk8s1",
                efi_partition=uid(5).lower(), populated_partitions=populated,
                startup_volume_icon=dict(member="fedora.icns", installed_bytes=len(files["fedora.icns"]),
                    verification="stub-file-sha256", content_sha256=digest(files["fedora.icns"]))))
            removal = encoded(dict(plan_digest=plan_digest, removed="synthetic previous installation"))
            if kind == "replace":
                journal.event("existing_removal_started")
                journal.checkpoint("existing-install-removed", "existing_removal", removal)
            journal.event("apfs_preparation_started")
            journal.checkpoint("apfs-target-prepared", "apfs_preparation", target)
            journal.event("stub_and_esp_started")
            journal.checkpoint("stub-and-esp-installed", "stub_and_esp", installed)
            transcript = path.read_text()
        config = dict(schema=2, volumeName="Fedora Aurora Remix", systemUUID=uid(20), groupUUID=uid(91),
            prebootUUID=uid(22), espUUID=uid(5), bootMode="raw", stage2Path="m1n1/boot.bin",
            bootstrap=dict(mode="source-volume-owner", sourceSystemUUID=uid(10), sourceGroupUUID=uid(90), ownerUUIDs=[uid(900)]))
        evidence = {"apfs-target-prepared": target.decode(), "stub-and-esp-installed": installed.decode()}
        if kind == "replace":
            evidence["existing-install-removed"] = removal.decode()
        cases.append(dict(name=title, intent=kind, device="apple," + device, snapshot=snapshot, metadata=metadata.decode(),
            planDigest=plan_digest, transcript=transcript, config=config, evidence=evidence,
            espLayout=mapping, espFiles={destination: base64.b64encode(files[source]).decode() for source, destination in mapping.items()},
            rawDigests={"disk0s6": digest(files["boot.img"]), "disk0s7": digest(files["root.img"])},
            icon=base64.b64encode(files["fedora.icns"]).decode(), ownerUUID=uid(900)))
    return payload, encoded(dict(referenceSHA256=source_hash, vectors=cases)) + b"\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    options = parser.parse_args()
    payload, vectors = generate()
    outputs = {"native-handoff-payload.zip": payload, "native-handoff-vectors.json": vectors}
    for name, content in outputs.items():
        path = FIXTURES / name
        if options.write:
            path.write_bytes(content)
        elif path.read_bytes() != content:
            raise SystemExit("stale native handoff fixture: " + name)
    print("Native handoff fixtures match the locked ESP layout and journal contract")


if __name__ == "__main__":
    main()
