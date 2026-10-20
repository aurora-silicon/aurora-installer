#!/usr/bin/env python3
"""Source-only parity vectors for native full-OS payload admission."""
import argparse
import ast
import base64
import copy
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import sys
from types import SimpleNamespace
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "Tests/OmarchyAppleInstallerTrustCoreTests/Fixtures/native-payload-vectors.json"


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def reference():
    source = (ROOT / "Engine/overlay/src/omarchy_asahi.py").read_bytes()
    lock = json.loads((ROOT / "Engine/source-lock.json").read_text())
    expected = next(item["sha256"] for item in lock["downstream_overlay"]["files"]
                    if item["path"] == "overlay/src/omarchy_asahi.py")
    assert hashlib.sha256(source).hexdigest() == expected
    tree = ast.parse(source)
    adapter = next(node for node in tree.body if isinstance(node, ast.ClassDef)
                   and node.name == "AsahiStage1Adapter")
    method = next(node for node in adapter.body if isinstance(node, ast.FunctionDef)
                  and node.name == "_validate_full_os_package")
    errors = next(node for node in tree.body if isinstance(node, ast.ClassDef)
                  and node.name == "AsahiAdapterError")
    # The actual size parser is independently covered by native inspection
    # vectors. These capacities are deliberately in bytes to avoid test stubs
    # defining an alternate unit convention.
    scope = dict(os=os, PurePosixPath=PurePosixPath,
                 osinstall=SimpleNamespace(psize=lambda value: int(value[:-1])),
                 omarchy_recovery=SimpleNamespace(PAYLOAD_DIRECTORY="recovery", MANIFEST_NAME="manifest.json"))
    exec(compile(ast.Module(body=[errors, method], type_ignores=[]), "locked-payload-contract", "exec"), scope)
    return scope["_validate_full_os_package"], expected


def archive(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as package:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_STORED
            package.writestr(info, data)
    return output.getvalue()


def generate():
    validate, digest = reference()
    header = bytearray(0x11000)
    header[0x438:0x43a] = b"\x53\xef"
    btrfs = bytearray(len(header))
    btrfs[0x10040:0x10048] = b"_BHRfS_M"
    files = {"boot.img": bytes(header), "root.img": bytes(btrfs),
             "aurora-volume.icns": b"icon", "omarchy-volume.icns": b"legacy icon",
             "esp/m1n1/boot.bin": b"stage2", "esp/EFI/BOOT/BOOTAA64.EFI": b"efi"}
    archives = {"btrfs": archive(files)}
    files["root.img"] = bytes(header)
    archives["ext4"] = archive(files)
    files["root.img"] = b"bad" * 4096
    archives["bad-root"] = archive(files)
    files["root.img"] = bytes(header) + b"!"
    archives["unaligned"] = archive(files)
    files["root.img"] = bytes(header)
    del files["esp/m1n1/boot.bin"]
    archives["missing"] = archive(files)
    files["esp/m1n1/boot.bin"] = b""
    archives["empty"] = archive(files)
    base = dict(omarchy_target="apple-silicon-full-os", package="payload.zip",
                layout_kind="fedora-btrfs-v1", installation_profile="fedora-kde",
                boot_object="m1n1.bin", next_object="m1n1/boot.bin", icon="aurora-volume.icns",
                recovery_gui="omarchy-native-v1", partitions=[
                    dict(name="EFI", type="EFI", source="esp", format="fat", copy_firmware=True,
                         copy_installer_data=True, size="1048576B"),
                    dict(name="Boot", type="Linux", image="boot.img", size="1048576B"),
                    dict(name="Root", type="Linux", image="root.img", expand=True, size="2097152B")])
    vectors = []

    def add(name, template, payload="btrfs", duplicate=False):
        document = {"os_list": [template, copy.deepcopy(template)] if duplicate else [template]}
        accepted = True
        with zipfile.ZipFile(io.BytesIO(archives[payload])) as package:
            instance = SimpleNamespace(template=template, payload_path="/private/payload.zip",
                osins=SimpleNamespace(pkg=package), recovery_app="signed-helper-template")
            try:
                if duplicate:
                    raise ValueError("exactly one target required by outer preflight")
                validate(instance)
            except (RuntimeError, ValueError):
                accepted = False
        vectors.append(dict(name=name, metadata=encoded(document), archive=payload, accepted=accepted))

    for layout, prefix, filesystem in [("fedora-btrfs-v1", "fedora", "btrfs"),
        ("alarm-ext4-v1", "arch", "ext4"), ("alarm-btrfs-v1", "arch", "btrfs"),
        ("nixos-ext4-v1", "nixos", "ext4"), ("nixos-btrfs-v1", "nixos", "btrfs")]:
        for desktop in ("kde", "gnome", "minimal"):
            template = copy.deepcopy(base)
            template.update(layout_kind=layout, installation_profile=prefix + "-" + desktop)
            add(layout + "-" + desktop, template, filesystem)
    legacy = copy.deepcopy(base)
    del legacy["layout_kind"]
    del legacy["installation_profile"]
    legacy["icon"] = "omarchy-volume.icns"
    add("legacy-contract", legacy)
    for key, value in [("layout_kind", "unknown"), ("installation_profile", "arch-kde"),
                       ("package", "other.zip"), ("boot_object", "other.bin"),
                       ("next_object", "other.bin"), ("icon", "omarchy-volume.icns"),
                       ("recovery_gui", "unknown")]:
        template = copy.deepcopy(base)
        template[key] = value
        add("bad-" + key, template)
    for key, value in [("name", "Other"), ("type", "EFI"), ("source", "esp"),
                       ("image", "boot.img"), ("expand", False), ("size", "1B")]:
        template = copy.deepcopy(base)
        template["partitions"][2][key] = value
        add("bad-root-" + key, template)
    for key in ("format", "copy_firmware", "copy_installer_data"):
        template = copy.deepcopy(base)
        template["partitions"][0].pop(key)
        add("missing-efi-" + key, template)
    for payload in ("ext4", "bad-root", "unaligned", "missing", "empty"):
        add("payload-" + payload, copy.deepcopy(base), payload)
    add("duplicate-target", copy.deepcopy(base), duplicate=True)
    return dict(referenceSHA256=digest, archives={name: base64.b64encode(data).decode()
                                                for name, data in archives.items()}, vectors=vectors)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    options = parser.parse_args()
    result = generate()
    if options.write:
        FIXTURE.write_text(encoded(result) + "\n")
    elif json.loads(FIXTURE.read_text()) != result:
        raise SystemExit("stale native payload preflight fixtures")
    print(f"Verified {len(result['vectors'])} native payload admission reference vectors")
