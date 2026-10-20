#!/usr/bin/env python3
"""Public synthetic byte vectors for native Neo firmware conversion."""
import argparse
import ast
import base64
import collections
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

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Tests/NativeFirmwareFixtureSupport/Fixtures/neo-conversion-vectors.json"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def module(name):
    import importlib.util
    path = ROOT / "Engine/overlay/src" / (name + ".py")
    lock = json.loads((ROOT / "Engine/source-lock.json").read_text())
    assert digest(path.read_bytes()) == next(x["sha256"] for x in lock["downstream_overlay"]["files"]
                                           if x["path"] == "overlay/src/" + name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def helpers(name, names, namespace):
    source = ROOT / "Engine/overlay/tests" / name
    nodes = [node for node in ast.parse(source.read_bytes()).body
             if isinstance(node, ast.FunctionDef) and node.name in names]
    exec(compile(ast.Module(body=nodes, type_ignores=[]), "synthetic-firmware-helpers", "exec"), namespace)


def generate(runtime):
    mt, isp, als = (module(name) for name in ("omarchy_mt7932", "omarchy_isp", "omarchy_als"))
    pin = (ROOT / "Sources/OmarchyAppleInstaller/ValidationEngineArtifact.swift").read_text()
    expected = re.search(r'public static let expectedDigest\s*=\s*"sha256:([0-9a-f]{64})"', pin)[1]
    with runtime.open("rb") as stream: assert hashlib.file_digest(stream, "sha256").hexdigest() == expected
    with tarfile.open(runtime) as archive:
        entry = next(x for x in archive.getmembers() if x.name.removeprefix("./") == "asahi_firmware/isp.py")
        source = archive.extractfile(entry).read()
    assignment = next(node for node in ast.parse(source).body if isinstance(node, ast.Assign)
                      and any(isinstance(target, ast.Name) and target.id == "ISP_SETFILES" for target in node.targets))
    registry = [isp.SetFile(*map(ast.literal_eval, item.args)) for item in assignment.value.elts]
    registry = isp.extended_setfiles(registry)
    h = {"struct": struct, "mt": mt}
    helpers("test_omarchy_mt7932.py", {"der", "ia5", "field", "bwc2", "oca2", "ptx", "config", "bluetooth_firmware"}, h)
    helpers("test_omarchy_mt7932_policy.py", {"synthetic_policy"}, h)
    camera = bytearray()
    for entry in registry:
        camera.extend(bytes((-len(camera)) % 4096))
        size = (entry.size + 63) & ~63
        blob = bytearray(size)
        struct.pack_into(">8I", blob, 0, entry.magic, entry.sensor, 0, 0, 0x01000000, 0x01010000, 0, 0x03c00000)
        camera.extend(blob)
    camera = bytes(camera)
    lsci = bytearray(156)
    lsci[:2] = b"\x05\x04"
    struct.pack_into("<H", lsci, 4, 156)
    struct.pack_into("<5i", lsci, 28, 65536, -32768, 12345, -2147483648, 2147483647)
    for index, offset in enumerate((58, 60, 62, 64, 66, 68)): struct.pack_into("<h", lsci, offset, 255 + index)
    lsci = bytes(lsci)
    factory = h["bwc2"]({b"OCA2": h["oca2"](), b"WCAL": b"BLOB" + b"w" * 764,
                         b"BCAL": b"c" * 128, b"OCAL": b"older"})
    raw = {"camera/synthetic.bin": camera, "sunrise/" + mt.WIFI_PATCH: b"synthetic patch",
           "sunrise/" + mt.WIFI_RAM: b"synthetic RAM", "sunrise/IZUBA_PPR_MT7932.bin": b"BLOB" + b"p" * 408,
           "sunrise/IZUBA_wifi.cfg": h["config"]().encode(), "bluetooth/" + mt.BT_PTX: h["ptx"]()}
    for name in mt.BT_FIRMWARE: raw["bluetooth/" + name] = h["bluetooth_firmware"]()
    address = bytes([1, 2, 3, 4, 5, 6])
    # Exercise the exact collector with bounded injected synthetic reads.
    original_read, original_glob, original_open = mt._read, mt.glob.glob, getattr(mt, "open", None)
    def read(root, *parts): return raw["/".join(parts)]
    mt._read = read
    mt.glob.glob = lambda pattern: ["synthetic-factory-record"]
    mt.open = lambda *args, **kwargs: io.BytesIO(factory)
    try: radio = mt.collect(raw_directory="synthetic", chosen={"mac-address-bluetooth0": address})
    finally:
        mt._read, mt.glob.glob = original_read, original_glob
        if original_open is None: del mt.open
        else: mt.open = original_open
    camera_outputs = isp.extract(camera, registry)
    world = h["synthetic_policy"]("XZ")
    payload = io.BytesIO()
    with zipfile.ZipFile(payload, "w") as archive:
        info = zipfile.ZipInfo("installer-inputs/mt7932-policy/world-XZ.bin", (1980, 1, 1, 0, 0, 0))
        info.create_system = 3
        info.external_attr = 0o100644 << 16
        archive.writestr(info, world)
    payload = payload.getvalue()
    metadata = json.dumps({"os_list": [{"omarchy_target": "apple-silicon-full-os", "neo_regulatory_policy": {
        "kind": "original-j7rp-v1", "files": {"world-XZ.bin": "installer-inputs/mt7932-policy/world-XZ.bin"}}}]}, sort_keys=True, separators=(",", ":"))
    outputs = dict(camera_outputs, **radio)
    outputs[als.FIRMWARE_NAME] = als.calibration(lsci)
    outputs["fallback/lsci.bin"] = lsci
    outputs["mediatek/mt7932/policy/world-XZ.bin"] = world
    records = {}
    for name, data in outputs.items():
        role = "camera" if name in camera_outputs else "radio" if name in radio else "als" if name == als.FIRMWARE_NAME else "lsci" if name == "fallback/lsci.bin" else "policy"
        records[name] = dict(role=role, bytes=len(data), sha256=digest(data))
    manifest = dict(schema=1, converter="neo-v1", device_identifier="apple,j700", binding_digest="sha256:" + "b" * 64,
        plan_digest="c" * 64, metadata_digest="sha256:" + digest(metadata.encode()),
        payload_digest="sha256:" + digest(payload), recipe_sha256="a" * 64,
        local_inputs={"factory": digest(factory), "lsci": digest(lsci), "address": digest(address)}, files=records)
    vectors = []
    functions = {"camera": lambda data, country: isp.extract(data, registry),
        "factory": lambda data, country: mt.bwc2_fields(data), "oca": lambda data, country: (mt.validate_oca2(data), data)[1],
        "config": lambda data, country: mt.j7cf(data.decode("ascii")), "bluetooth": lambda data, country: (mt.validate_bluetooth_firmware(data), data)[1],
        "ptx": lambda data, country: (mt.validate_ptx(data), data)[1], "address": lambda data, country: mt.bluetooth_address({"mac-address-bluetooth0": data}),
        "als": lambda data, country: als.calibration(data), "policy": lambda data, country: mt.validate_policy(data, country)}
    def add(name, operation, data, country="XZ"):
        success, sha, files = True, None, None
        try:
            value = functions[operation](data, country)
            if isinstance(value, dict): files = {name: digest(blob) for name, blob in value.items()}
            else: sha = digest(value)
        except (ValueError, RuntimeError, struct.error, IndexError): success = False
        vectors.append(dict(name=name, operation=operation, data=base64.b64encode(data).decode(), country=country,
                            success=success, sha256=sha, files=files))
    for operation, data in [("camera", camera), ("factory", factory), ("oca", h["oca2"]()),
        ("config", h["config"]().encode()), ("bluetooth", h["bluetooth_firmware"]()), ("ptx", h["ptx"]()),
        ("address", address), ("als", lsci), ("policy", world)]:
        add(operation + "-valid", operation, data)
    for operation, data in [("factory", factory[:-1]), ("oca", h["oca2"]()[:-1]), ("ptx", h["ptx"]()[:-1]),
                            ("bluetooth", bytes(64)), ("address", bytes(6)), ("address", bytes([255] * 6)),
                            ("address", bytes(5)), ("als", lsci[:-1]), ("policy", world + b"!")]:
        add(operation + "-bad-" + str(len(vectors)), operation, data)
    add("factory-duplicate", "factory", h["bwc2"]([(b"OCA2", b"one"), (b"OCA2", b"two")]))
    for data in [h["config"](63).encode(), (h["config"]() + "Sta5gBw 1\n").encode(), b"\xff" * 64]: add("bad-config-" + str(len(vectors)), "config", data)
    add("config-65", "config", h["config"](65).encode())
    add("config-crlf", "config", h["config"]().replace("\n", "\r\n").encode())
    for offset in [0, 4, 58, 60, 62, 64, 66, 68]:
        data = bytearray(lsci); data[offset] = 0; data[offset + 1] = 0
        add("bad-lsci-" + str(offset), "als", bytes(data))
    for offset in [4, 6, 8, 9, 12, 16, 16 + 656 + 2]:
        data = bytearray(world); data[offset] ^= 0xff
        add("bad-policy-" + str(offset), "policy", bytes(data))
    add("country-policy", "policy", h["synthetic_policy"]("CA"), "CA")
    add("wrong-country", "policy", world, "CA")
    return dict(runtimeSHA256=expected, registry=[dict(magic=x.magic,name=x.name,size=x.size) for x in registry],
        sourceSHA256={name:digest((ROOT / "Engine/overlay/src" / (name + ".py")).read_bytes()) for name in
                      ("omarchy_isp", "omarchy_mt7932", "omarchy_als")},
        vectors=vectors, rawFiles={name:base64.b64encode(data).decode() for name,data in raw.items()},
        local={"factory":base64.b64encode(factory).decode(),"lsci":base64.b64encode(lsci).decode(),"address":base64.b64encode(address).decode()},
        payload=base64.b64encode(payload).decode(), metadata=metadata, manifest=manifest,
        outputSHA256={name:digest(data) for name,data in outputs.items()})


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    if args.write and args.runtime is None: parser.error("--write requires authenticated --runtime")
    expected = generate(args.runtime) if args.runtime else json.loads(OUTPUT.read_text())
    if args.write: OUTPUT.write_text(json.dumps(expected,sort_keys=True,separators=(",", ":")) + "\n")
    elif expected != json.loads(OUTPUT.read_text()): raise SystemExit("stale native Neo conversion fixture")
    for name, sha in expected["sourceSHA256"].items(): assert digest((ROOT / "Engine/overlay/src" / (name + ".py")).read_bytes()) == sha
    print(f"Verified {len(expected['vectors'])} native Neo conversion reference vectors")
