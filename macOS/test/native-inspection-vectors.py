#!/usr/bin/env python3
"""Compare native inspection with pure functions from the pinned runtime.

--runtime reads the authenticated archive in place; no runtime is executed or
extracted. Only public Python class/function ASTs needed for synthetic geometry
are evaluated. Host/device collection, filesystem mutation and subprocesses are
never called. --write deliberately regenerates the checked-in vectors.
Without --runtime, verify fixture pins and the shared transcript contract.
"""
import argparse
import ast
import copy
from dataclasses import dataclass
import hashlib
import json
import logging
from pathlib import Path
import re
import sys
import tarfile
from types import ModuleType, SimpleNamespace
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Engine/overlay/src"))
import omarchy_contract
import omarchy_firmware

FIXTURE = ROOT / "Tests/OmarchyAppleInstallerTrustCoreTests/Fixtures/native-inspection-vectors.json"


def identifier(value):
    return str(uuid.UUID(int=value)).upper()


def policy_source():
    source = (ROOT / "Sources/OmarchyAppleInstaller/NativeInspectionPolicySource.swift").read_text()
    return json.loads(source.split('static let json = #"""', 1)[1].split('"""#', 1)[0])


def reference(archive):
    pin = (ROOT / "Sources/OmarchyAppleInstaller/ValidationEngineArtifact.swift").read_text()
    digest = re.search(r'public static let expectedDigest\s*=\s*"sha256:([0-9a-f]{64})"', pin)[1]
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != digest:
            raise ValueError("reference archive differs from the pinned runtime")
    with tarfile.open(archive) as runtime:
        def source(name):
            member = next(item for item in runtime.getmembers() if item.name.removeprefix("./") == name)
            return runtime.extractfile(member).read()
        main = source("main.py")
        runtime_source = source("omarchy_runtime.py")
        for name in ("omarchy_planner", "omarchy_firmware", "omarchy_contract"):
            if source(name + ".py") != (ROOT / "Engine/overlay/src" / (name + ".py")).read_bytes():
                raise ValueError("local reference module differs from authenticated archive: " + name)
        util = ast.parse(source("util.py"))
        disk = ast.parse(source("diskutil.py"))
        osinstall = ast.parse(source("osinstall.py"))
        tree = ast.parse(main)
        metadata = json.loads(source("installer_data.json"))
    namespace = {"__name__": __name__, "re": re, "logging": logging, "sys": sys,
                 "dataclass": dataclass, "PackageInstaller": object}
    nodes = [node for node in util.body if isinstance(node, ast.FunctionDef)
             and node.name in ("psize", "split_ver", "align_up", "align_down")]
    nodes += [node for node in disk.body if isinstance(node, ast.ClassDef)
              and node.name in ("Partition", "DiskUtil")]
    nodes += [node for node in osinstall.body if isinstance(node, ast.ClassDef)
              and node.name == "OSInstaller"]
    main_class = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "InstallerMain")
    main_class.body = [node for node in main_class.body if isinstance(node, ast.FunctionDef)
                       and node.name in ("can_resize", "get_min_free_space", "get_resize_bounds")]
    nodes.append(main_class)
    namespace.update(MIN_FREE_OS=38_000_000_000, MIN_FREE=1_000_000_000,
                     PART_ALIGN=1_048_576)
    exec(compile(ast.Module(body=nodes, type_ignores=[]), "pinned-inspection-reference", "exec"), namespace)
    module = ModuleType("osinstall")
    module.OSInstaller = namespace["OSInstaller"]
    sys.modules["osinstall"] = module
    util_module = ModuleType("util")
    util_module.align_down = namespace["align_down"]
    sys.modules["util"] = util_module
    import omarchy_planner
    values = {node.targets[0].id: node.value for node in tree.body if isinstance(node, ast.Assign)
              and isinstance(node.targets[0], ast.Name)}
    chips = ast.literal_eval(values["CHIP_MIN_VER"])
    devices = {ast.literal_eval(key).removesuffix("ap"):
               {"minimum": ast.literal_eval(value.args[0]), "expert": ast.literal_eval(value.args[1])}
               for key, value in zip(values["DEVICES"].keys, values["DEVICES"].values)}
    firmware = []
    for value in values["IPSW_VERSIONS"].elts:
        version, mac, boot, recovery, expert, models, url = map(ast.literal_eval, value.args)
        firmware.append(dict(version=version, minimumMacOS=mac, minimumBoot=boot,
                             minimumRecovery=recovery, expert=expert,
                             models=None if models is None else [item.removesuffix("ap") for item in models],
                             sourceURL=url))
    policy = dict(runtimeVersion="v0.9.2-aurora.8", sourceSHA256=hashlib.sha256(main).hexdigest(),
                  chipMinimum={str(key): value for key, value in chips.items()}, devices=devices,
                  firmware=firmware, baselineMetadata=metadata)
    if policy != policy_source():
        raise ValueError("native policy differs from pinned runtime source")
    selection = next(node for node in ast.walk(ast.parse(runtime_source))
                     if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                     and isinstance(node.func.value, ast.Name) and node.func.value.id == "omarchy_planner"
                     and node.func.attr == "collect_inventory")
    namespace.update(planner=omarchy_planner, policy=policy, runtime_sha256=digest,
                     selection_source_sha256=hashlib.sha256(runtime_source).hexdigest(),
                     select_resize=compile(ast.Expression(selection.args[2]), "pinned-runtime-selection", "eval"))
    return namespace


def cases(policy):
    unit = 1_048_576
    gib = 1024**3
    size = 256 * gib
    parts = [dict(identifier="disk0s1", uuid=identifier(1), type="Apple_APFS_ISC",
                  offset=20_480, size=512 * unit, name=""),
             dict(identifier="disk0s2", uuid=identifier(2), type="Apple_APFS",
                  offset=514 * unit, size=160 * gib, name="Macintosh HD"),
             dict(identifier="disk0s3", uuid=identifier(3), type="Apple_APFS_Recovery",
                  offset=size - 5 * gib, size=5 * gib - 20_480, name="")]
    snapshot = dict(disk="disk0", devicePath="synthetic-internal", diskSize=size,
                    macOSStoreUUID=identifier(2), macOSContainerUUID=identifier(102),
                    partitions=parts, containers=[])
    facts = [dict(storeUUID=identifier(2), capacity=160 * gib, free=100 * gib,
                  preferredMinimum=70 * gib,
                  systems=[dict(group=identifier(202), label="Macintosh HD", stub=False, version="26.6.2")])]
    hardware = dict(chipID=0x6000, bootVersion="iBoot-12000.1.1", macOSVersion="26.6.2",
                    recoveryVersion="25.7.83.0.0,0")
    base = dict(name="free-and-resize", device="apple,j314s", snapshot=snapshot, containers=facts,
                hardware=hardware, metadata=policy["baselineMetadata"])
    result = [copy.deepcopy(base)]
    def case(name):
        value = copy.deepcopy(base)
        value["name"] = name
        result.append(value)
        return value
    for name, gap in (("gap-exact-threshold", 16 * unit), ("gap-above-threshold", 16 * unit + 4096)):
        value = case(name)
        value["snapshot"]["partitions"][1]["offset"] = 20_480 + 512 * unit + gap
    value = case("multiple-apfs-and-unrelated")
    offset = parts[1]["offset"] + parts[1]["size"]
    value["snapshot"]["partitions"].extend([
        dict(identifier="disk0s4", uuid=identifier(4), type="Microsoft Basic Data",
             offset=offset + 20 * gib, size=8 * gib, name="Keep me"),
        dict(identifier="disk0s5", uuid=identifier(5), type="Apple_APFS",
             offset=offset + 40 * gib, size=32 * gib, name="Other container")])
    value["snapshot"]["partitions"].sort(key=lambda part: part["offset"])
    value["containers"].append(dict(storeUUID=identifier(5), capacity=32 * gib, free=30 * gib,
                                    preferredMinimum=4 * gib, systems=[]))
    case("snapshot-exhausted")["containers"][0]["preferredMinimum"] = 159 * gib
    case("low-free-macos")["containers"][0].update(free=20 * gib, preferredMinimum=152 * gib)
    case("zero-free-macos")["containers"][0].update(free=0, preferredMinimum=160 * gib)
    value = case("low-free-stub")
    value["containers"][0].update(free=20 * gib, preferredMinimum=152 * gib)
    value["containers"][0]["systems"][0]["stub"] = True
    value = case("education-exhausted")
    value["snapshot"]["diskSize"] = 128 * gib
    value["snapshot"]["partitions"][1]["size"] = 100 * gib
    value["snapshot"]["partitions"][2]["offset"] = 123 * gib
    value["containers"][0].update(capacity=100 * gib, free=10 * gib, preferredMinimum=95 * gib)
    for name in ("neo", "m3-modern-firmware", "m3-mixed-firmware", "m3-unreadable-recovery"):
        value = case(name)
        value["device"] = "apple,j700" if name == "neo" else "apple,j613"
        value["hardware"].update(chipID=0x8140 if name == "neo" else 0x8122,
                                 bootVersion="mBoot-18000.161.10")
        value["metadata"]["os_list"][0]["supported_fw"] = ["26.6.2"]
        if name == "m3-mixed-firmware":
            value["metadata"]["os_list"][0]["supported_fw"].append("14.8.3")
        if name == "m3-unreadable-recovery":
            value["hardware"]["recoveryVersion"] = None
    value = case("partition-rounding-and-unrelated-template")
    value["metadata"]["os_list"][0]["partitions"][0]["size"] = "500.1MB"
    value["metadata"]["os_list"].append({"omarchy_target": "other"})
    for name in ("complete-install", "partial-install"):
        value = case(name)
        start = offset + 5 * gib
        extra = []
        for index, (kind, length, label) in enumerate([
                ("Apple_APFS", 2_499_805_184, "Omarchy"), ("EFI", 512 * unit, "EFI - OMARC"),
                ("Linux Filesystem", 2 * gib, ""), ("Linux Filesystem", 40 * gib, "")]):
            extra.append(dict(identifier=f"disk0s{index + 4}", uuid=identifier(index + 4), type=kind,
                              offset=start, size=length, name=label))
            start += length
        value["snapshot"]["partitions"].extend(extra if name == "complete-install" else extra[:-1])
        value["snapshot"]["partitions"].sort(key=lambda part: part["offset"])
        value["containers"].append(dict(storeUUID=identifier(4), capacity=2_499_805_184,
                                        free=1_800_000_000, preferredMinimum=1_000_000_000,
                                        systems=[dict(group=identifier(204), label="Omarchy", stub=True, version="26.6.2")]))
    return result


def generate(ref):
    policy = ref["policy"]
    versions = [SimpleNamespace(version=item["version"], min_macos=item["minimumMacOS"],
                                min_iboot=item["minimumBoot"], min_sfr=item["minimumRecovery"],
                                expert_only=item["expert"],
                                devices=None if item["models"] is None else [model + "ap" for model in item["models"]])
                for item in policy["firmware"]]
    vectors = cases(policy)
    for value in vectors:
        snapshot, facts, hardware = value["snapshot"], value["containers"], value["hardware"]
        by_uuid = {item["storeUUID"]: item for item in facts}
        parts = {}
        for item in snapshot["partitions"]:
            part = ref["Partition"](name=item["identifier"], offset=item["offset"], size=item["size"],
                                    free=False, type=item["type"], uuid=item["uuid"], label=item["name"])
            if item["uuid"] in by_uuid:
                fact = by_uuid[item["uuid"]]
                part.container = dict(CapacityCeiling=fact["capacity"], CapacityFree=fact["free"])
                part.os = [SimpleNamespace(stub=s["stub"], label=s["label"], vgid=s["group"], version=s["version"])
                           for s in fact["systems"]]
            parts[part.name] = part
        dutil = ref["DiskUtil"]()
        dutil.disk_parts = {snapshot["disk"]: dict(Size=snapshot["diskSize"],
                           Partitions=[dict(DeviceIdentifier=key) for key in parts])}
        dutil.get_partition_info = parts.__getitem__
        dutil.get = lambda *args: {"MinimumSizePreferred": by_uuid[parts[args[2]].uuid]["preferredMinimum"]}
        installer = ref["InstallerMain"]()
        installer.dutil, installer.sys_disk = dutil, snapshot["disk"]
        installer.data, installer.expert = value["metadata"], False
        installer.is_edu_128gb = snapshot["diskSize"] < 150 * 1024**3
        installer.parts = dutil.get_partitions(snapshot["disk"])
        sysinfo = SimpleNamespace(chip_id=hardware["chipID"], sys_firmware=hardware["bootVersion"],
                                  macos_ver=hardware["macOSVersion"], sfr_full_ver=hardware["recoveryVersion"],
                                  device_class=value["device"].removeprefix("apple,") + "ap")
        device = SimpleNamespace(min_ver=policy["devices"][sysinfo.device_class.removesuffix("ap")]["minimum"])
        stub = omarchy_firmware.stub_size(versions, {int(k): v for k, v in policy["chipMinimum"].items()},
                                         sysinfo, device, value["metadata"], ref["split_ver"],
                                         default_size=2_499_805_184, macos26_size=5_999_951_872)
        resizable = [part for part in installer.parts if part.container is not None and installer.can_resize(part)]
        selected = eval(ref["select_resize"], {"installer": installer, "resizable_parts": resizable, "is_gpt": True})
        inventory = ref["planner"].collect_inventory(installer,
                    [part for part in installer.parts if part.free and part.size >= 2_499_805_184],
                    selected,
                    stub, 1_048_576)
        value["expectedInventory"] = omarchy_contract.normalized_inventory(**inventory)
        value["stubBytes"] = stub
    return dict(schema=1, runtimeSHA256=ref["runtime_sha256"],
                selectionSourceSHA256=ref["selection_source_sha256"], policy=policy, vectors=vectors)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    if args.write and not args.runtime:
        parser.error("--write requires the authenticated --runtime")
    expected = generate(reference(args.runtime)) if args.runtime else json.loads(FIXTURE.read_text())
    pin_source = (ROOT / "Sources/OmarchyAppleInstaller/ValidationEngineArtifact.swift").read_text()
    pin_digest = re.search(r'public static let expectedDigest\s*=\s*"sha256:([0-9a-f]{64})"', pin_source)[1]
    if expected["runtimeSHA256"] != pin_digest:
        raise SystemExit("inspection fixture runtime pin is stale")
    if args.write:
        FIXTURE.write_text(json.dumps(expected, indent=2, sort_keys=True) + "\n")
    elif expected != json.loads(FIXTURE.read_text()):
        raise SystemExit("native inspection vectors differ from the pinned runtime")
    if expected["policy"] != policy_source():
        raise SystemExit("native source-pinned inspection policy differs from fixtures")
    for vector in expected["vectors"]:
        inventory = vector["expectedInventory"]
        if inventory != omarchy_contract.normalized_inventory(inventory["system_store_identifier"], inventory["candidates"]):
            raise SystemExit("native inspection fixture has an invalid contract")
    print(f"Verified {len(expected['vectors'])} native inspection reference vectors")
