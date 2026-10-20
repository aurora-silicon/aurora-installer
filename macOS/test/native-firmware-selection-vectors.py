#!/usr/bin/env python3
"""Verify native firmware/boot-object fixtures against locked source functions.

--runtime authenticates the archive and evaluates only the firmware chooser and
version comparison AST. No runtime entry point or host command is executed.
"""
import argparse
import ast
import base64
import collections
import copy
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import sys
import tarfile
from types import SimpleNamespace
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "Tests/OmarchyAppleInstallerTrustCoreTests/Fixtures/native-firmware-selection-vectors.json"


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def policy_source():
    text = (ROOT / "Sources/OmarchyAppleInstaller/NativeInspectionPolicySource.swift").read_text()
    return json.loads(text.split('static let json = #"""', 1)[1].split('"""#', 1)[0])


def archive(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as package:
        for name, data in sorted(files.items()):
            member = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            member.create_system = 3
            member.external_attr = 0o100644 << 16
            package.writestr(member, data)
    return output.getvalue()


def source_references(runtime):
    pin = (ROOT / "Sources/OmarchyAppleInstaller/ValidationEngineArtifact.swift").read_text()
    runtime_hash = re.search(r'public static let expectedDigest\s*=\s*"sha256:([0-9a-f]{64})"', pin)[1]
    with runtime.open("rb") as stream:
        assert hashlib.file_digest(stream, "sha256").hexdigest() == runtime_hash
    with tarfile.open(runtime) as package:
        def source(name):
            member = next(item for item in package.getmembers() if item.name.removeprefix("./") == name)
            return package.extractfile(member).read()
        main = source("main.py")
        util = source("util.py")
        adapter = source("omarchy_asahi.py")
        filtering = source("omarchy_firmware.py")
    assert adapter == (ROOT / "Engine/overlay/src/omarchy_asahi.py").read_bytes()
    assert filtering == (ROOT / "Engine/overlay/src/omarchy_firmware.py").read_bytes()
    lock = json.loads((ROOT / "Engine/source-lock.json").read_text())
    assert hashlib.sha256(adapter).hexdigest() == next(item["sha256"] for item
        in lock["downstream_overlay"]["files"] if item["path"] == "overlay/src/omarchy_asahi.py")
    policy = policy_source()
    assert policy["sourceSHA256"] == hashlib.sha256(main).hexdigest()
    tree = ast.parse(main)
    values = {node.targets[0].id: node.value for node in tree.body if isinstance(node, ast.Assign)
              and isinstance(node.targets[0], ast.Name)}
    rows = [list(map(ast.literal_eval, value.args)) for value in values["IPSW_VERSIONS"].elts]
    for record, row in zip(policy["firmware"], rows):
        assert record == dict(version=row[0], minimumMacOS=row[1], minimumBoot=row[2],
            minimumRecovery=row[3], expert=row[4], models=None if row[5] is None else
            [item.removesuffix("ap") for item in row[5]], sourceURL=row[6])
    firmware_type = collections.namedtuple("IPSW", "version min_macos min_iboot min_sfr expert_only devices url")
    scope = dict(sys=sys, CHIP_MIN_VER=ast.literal_eval(values["CHIP_MIN_VER"]),
                 IPSW_VERSIONS=[firmware_type(*row) for row in rows],
                 p_message=lambda *args: None, p_error=lambda *args: None, print=lambda *args: None)
    available = next(node for node in ast.parse(filtering).body if isinstance(node, ast.FunctionDef)
                     and node.name == "available_ipsws")
    filtering_scope = {}
    exec(compile(ast.Module(body=[available], type_ignores=[]), "locked-firmware-filter", "exec"), filtering_scope)
    scope["omarchy_firmware"] = SimpleNamespace(available_ipsws=filtering_scope["available_ipsws"])
    split = next(node for node in ast.parse(util).body if isinstance(node, ast.FunctionDef)
                 and node.name == "split_ver")
    chooser = next(node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)
                   and node.name == "choose_ipsw")
    scope["re"] = re
    exec(compile(ast.Module(body=[split, chooser], type_ignores=[]), "locked-firmware-chooser", "exec"), scope)
    allowed = {"STAGE1_MAGIC", "STAGE1_BODY", "STAGE1_BLOCK", "CANONICAL_UUID", "PLACEHOLDER_UUID",
               "BoardStage1", "COMMON_STAGE1", "BOARD_STAGE1", "ESP_SOURCE", "ESP_STAGE2", "BOARD_STAGE2"}
    nodes = [node for node in ast.parse(adapter).body if
             isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name) and node.targets[0].id in allowed
             or isinstance(node, ast.FunctionDef) and node.name in
             {"fill_aurora_stage1", "board_stage1", "common_stage1_allowed", "read_board_stage1", "esp_board_layout"}
             or isinstance(node, ast.ClassDef) and node.name == "AsahiAdapterError"]
    scope.update(collections=collections, struct=struct, zlib=zlib)
    exec(compile(ast.Module(body=nodes, type_ignores=[]), "locked-boot-object", "exec"), scope)
    preflight = next(node for node in ast.walk(ast.parse(adapter)) if isinstance(node, ast.FunctionDef)
                     and node.name == "preflight" and any(isinstance(child, ast.Assign) and
                     any(isinstance(target, ast.Name) and target.id == "allowed" for target in child.targets)
                     for child in node.body))
    start = next(index for index, node in enumerate(preflight.body) if isinstance(node, ast.Assign)
                 and any(isinstance(target, ast.Name) and target.id == "allowed" for target in node.targets))
    gate = ast.parse("def admit_board(self, board): pass").body[0]
    gate.body = preflight.body[start:start + 3]
    exec(compile(ast.fix_missing_locations(ast.Module(body=[gate], type_ignores=[])),
                 "locked-board-admission", "exec"), scope)
    return policy, scope, runtime_hash


def generate(runtime):
    policy, reference, runtime_hash = source_references(runtime)
    vectors = []
    baseline = dict(bootVersion="mBoot-18000.161.10", macOSVersion="26.6.2", recoveryVersion="25.7.83.0.0,0")
    for device, chip in [("j314s", 0x6000), ("j413", 0x8112), ("j613", 0x8122), ("j700", 0x8140)]:
        for index, whitelist in enumerate([None, [], ["26.6"], ["26.6.2"], ["13.5", "14.8.3"], ["12.3", "12.3.1"]]):
            for version_case in ["current", "old-boot", "old-os", "old-recovery", "missing-recovery", "bad-os"]:
                hardware = dict(baseline, chipID=chip)
                if version_case == "old-boot": hardware["bootVersion"] = "iBoot-7459.101.2"
                if version_case == "old-os": hardware["macOSVersion"] = "12.1"
                if version_case == "old-recovery": hardware["recoveryVersion"] = "21.5.230.0.0,0"
                if version_case == "missing-recovery": hardware["recoveryVersion"] = None
                if version_case == "bad-os": hardware["macOSVersion"] = "unreadable"
                template = dict(omarchy_target="apple-silicon-full-os", default_os_name="Fixture",
                                partitions=[dict(size="1GiB")])
                if whitelist is not None: template["supported_fw"] = whitelist
                metadata = encoded(dict(os_list=[template]))
                instance = SimpleNamespace(expert=False, sysinfo=SimpleNamespace(chip_id=chip,
                    sys_firmware=hardware["bootVersion"], macos_ver=hardware["macOSVersion"],
                    sfr_full_ver=hardware["recoveryVersion"], device_class=device + "ap"),
                    device=SimpleNamespace(min_ver=policy["devices"][device]["minimum"]))
                selected = None
                try:
                    chosen = reference["choose_ipsw"](instance, whitelist)
                    selected = dict(version=chosen.version, sourceURL=chosen.url,
                                    stubBytes=5_999_951_872 if reference["split_ver"](chosen.version)
                                    >= reference["split_ver"]("26.0") else 2_499_805_184)
                except (SystemExit, IndexError, ValueError, TypeError):
                    pass
                vectors.append(dict(name=f"{device}-{index}-{version_case}", device="apple," + device,
                                    hardware=hardware, metadata=metadata, expected=selected))
    fill = reference["fill_aurora_stage1"]
    raw = b"synthetic code" + reference["STAGE1_MAGIC"] + struct.pack("<II40s192s", 1, 0, b"", b"") + bytes(4) + bytes(32) + b"STACKBOT"
    fill_vectors = []
    for window in [0, 5000, 99999]:
        filled = fill(raw, "12345678-1234-1234-1234-123456789abc", "m1n1/boot.bin", window)
        fill_vectors.append(dict(window=window, sha256=hashlib.sha256(filled).hexdigest()))
    boot_files = {"esp/aurora/stage1.bin": raw, "esp/aurora/stage1-j700.bin": raw,
                  "esp/aurora/stage1-j613.bin": raw, "esp/m1n1/boot.bin": b"generic",
                  "esp/m1n1/boot-j700.bin": b"neo", "esp/EFI/BOOT/BOOTAA64.EFI": b"efi"}
    archives = {"all": archive(boot_files)}
    for name, removed in [("no-common", "esp/aurora/stage1.bin"), ("no-neo", "esp/aurora/stage1-j700.bin"),
                          ("no-m3", "esp/aurora/stage1-j613.bin"), ("no-neo-stage2", "esp/m1n1/boot-j700.bin")]:
        files = dict(boot_files)
        del files[removed]
        archives[name] = archive(files)
    files = dict(boot_files)
    files["esp/aurora/stage1.bin"] = b"invalid"
    archives["bad-common"] = archive(files)
    boot_vectors = []
    for device, firmware in [("j700ap", "26.6.2"), ("j613ap", "26.6.2"), ("j613ap", "14.8.3"), ("j314sap", "13.5")]:
        for qualified in [False, True]:
            for archive_name, archive_data in archives.items():
                template = dict(omarchy_target="apple-silicon-full-os", next_object="m1n1/boot.bin")
                if qualified:
                    template["aurora_stage1"] = dict(kind="common-raw-v1", qualified_machines={device: [firmware]})
                expected = None
                with zipfile.ZipFile(io.BytesIO(archive_data)) as package:
                    members = package.namelist()
                    common = reference["COMMON_STAGE1"].member in members and reference["common_stage1_allowed"](template, device, firmware)
                    try:
                        stage = reference["board_stage1"](device, firmware, members, common_allowed=common)
                        if stage is not None: reference["read_board_stage1"](stage, package.read)
                        layout = reference["esp_board_layout"](device, members, common_allowed=common)
                        stage2 = "esp/m1n1/boot-j700.bin" if device == "j700ap" and not common else "esp/m1n1/boot.bin"
                        if package.getinfo(stage2).file_size <= 0: raise ValueError("empty stage2")
                        expected = dict(member=None if stage is None else stage.member,
                                        window=0 if stage is None else stage.window_ms, layout=layout)
                    except (RuntimeError, KeyError, ValueError):
                        pass
                boot_vectors.append(dict(name=f"{device}-{firmware}-{qualified}-{archive_name}",
                    device="apple," + device.removesuffix("ap"), firmware=firmware,
                    metadata=encoded(dict(os_list=[template])), archive=archive_name, expected=expected))
    original = next(value for value in boot_vectors if value["name"] == "j700ap-26.6.2-True-all")
    for name, changes in [("allow-own", {"allowed_device_classes":["j700ap"]}),
                          ("allow-other", {"allowed_device_classes":["j613ap"]}),
                          ("allow-empty", {"allowed_device_classes":[]}),
                          ("allow-null", {"allowed_device_classes":None}),
                          ("exclude-own", {"excluded_device_classes":["j700ap"]}),
                          ("exclude-other", {"excluded_device_classes":["j613ap"]}),
                          ("exclude-null", {"excluded_device_classes":None}),
                          ("unrelated-supported-key", {"supported_device_classes":["j613ap"]})]:
        value = copy.deepcopy(original)
        document = json.loads(value["metadata"])
        document["os_list"][0].update(changes)
        value.update(name=name,metadata=encoded(document))
        try:
            reference["admit_board"](SimpleNamespace(template=document["os_list"][0]), "j700ap")
        except (RuntimeError, TypeError):
            value["expected"] = None
        boot_vectors.append(value)
    # One complete package exercises the production preflight coordinator.
    complete = dict(boot_files)
    boot = bytearray(0x11000)
    boot[0x438:0x43a] = b"\x53\xef"
    root = bytearray(0x11000)
    root[0x10040:0x10048] = b"_BHRfS_M"
    complete.update({"boot.img": bytes(boot), "root.img": bytes(root), "aurora-volume.icns": b"icon"})
    complete_template = dict(omarchy_target="apple-silicon-full-os", default_os_name="Fedora Aurora Remix",
        layout_kind="fedora-btrfs-v1", installation_profile="fedora-kde", package="payload.zip",
        boot_object="m1n1.bin", next_object="m1n1/boot.bin", icon="aurora-volume.icns",
        supported_fw=["26.6.2"], aurora_stage1=dict(kind="common-raw-v1", qualified_machines={"j700ap":["26.6.2"]}),
        partitions=[dict(name="EFI",type="EFI",source="esp",format="fat",copy_firmware=True,copy_installer_data=True,size="1GiB"),
            dict(name="Boot",type="Linux",image="boot.img",size="1GiB"),
            dict(name="Root",type="Linux",image="root.img",expand=True,size="2GiB")])
    return dict(runtimeSHA256=runtime_hash, sourceSHA256=policy["sourceSHA256"],
        adapterSHA256=hashlib.sha256((ROOT / "Engine/overlay/src/omarchy_asahi.py").read_bytes()).hexdigest(),
        firmware=vectors, boot=boot_vectors, archives={key:base64.b64encode(data).decode() for key,data in archives.items()},
        stage1=base64.b64encode(raw).decode(), filled=fill_vectors,
        completeArchive=base64.b64encode(archive(complete)).decode(), completeMetadata=encoded(dict(os_list=[complete_template])))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    if args.write and args.runtime is None: parser.error("--write requires authenticated --runtime")
    expected = generate(args.runtime) if args.runtime else json.loads(FIXTURE.read_text())
    if args.write: FIXTURE.write_text(encoded(expected) + "\n")
    elif expected != json.loads(FIXTURE.read_text()): raise SystemExit("stale native firmware selection fixture")
    policy = policy_source()
    pin = (ROOT / "Sources/OmarchyAppleInstaller/ValidationEngineArtifact.swift").read_text()
    assert '"sha256:' + expected["runtimeSHA256"] + '"' in pin
    assert expected["sourceSHA256"] == policy["sourceSHA256"]
    assert expected["adapterSHA256"] == hashlib.sha256((ROOT / "Engine/overlay/src/omarchy_asahi.py").read_bytes()).hexdigest()
    print(f"Verified {len(expected['firmware'])} firmware and {len(expected['boot'])} boot-object reference vectors")
