#!/usr/bin/env python3
"""Synthetic interoperability cases using only authenticated reference source."""
import argparse
import base64
import hashlib
import importlib
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import struct
import sys
import tarfile
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Tests/AuroraFirmwareTests/Fixtures/generic-firmware.json"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def der(tag, value):
    length = len(value)
    encoded = bytes([length]) if length < 128 else (
        bytes([128 + (length.bit_length() + 7) // 8])
        + length.to_bytes((length.bit_length() + 7) // 8, "big"))
    return bytes([tag]) + encoded + value


def integer(number):
    data = number.to_bytes(max(1, (number.bit_length() + 7) // 8), "big")
    return der(2, (b"\0" if data[0] & 128 else b"") + data)


def image(kind, data, compressed=False, count=None):
    metadata = b""
    if compressed:
        raw = data
        data = b"bvx-" + struct.pack("<I", len(raw)) + raw + b"bvx$"
        metadata = der(0x30, integer(1) + integer(len(raw) if count is None else count))
    return der(0x30, der(0x16, b"IM4P") + der(0x16, kind.encode())
               + der(0x16, b"synthetic") + der(4, data) + metadata)


def firmware_xml(value):
    return ET.tostring(ET.fromstring(plistlib.dumps(value, sort_keys=False))[0], encoding="ascii")


def trackpad():
    return [{"Type": "Config", "Config": {"Interface Config": [
        {"bInterfaceNumber": 9, "Flags": True, "Payload": b"one"},
        {"HIDRecorder Descriptor": b"recording", "bInterfaceNumber": 2},
    ]}}, {"Type": "Binary", "Payload": b"\x01\x02\x03\x04\x05", "Address": 0x12345678,
          "Small": 23, "Byte": 24, "Word": 65535, "Long": 65536, "Enabled": False}]


def touchbar():
    return [{"Type": "Config", "Config": {"SPI Config": {"Init Payload": b"abc"}}},
            {"Type": "Binary", "Address": 0x12345678, "Payload": b"\x01\x02\x03\x04\x05"},
            {"Type": "Property", "Address": 0x1234}, {"Type": "RequestCalibration"},
            {"Type": "ReadModifyWrite", "Address": 0x89abcdef, "Mask": 0xffff00ff, "Value": 0x80400001}]


def generate(runtime):
    pin = (ROOT / "Sources/OmarchyAppleInstaller/ValidationEngineArtifact.swift").read_text()
    digest = re.search(r'expectedDigest\s*=\s*"sha256:([0-9a-f]{64})"', pin)[1]
    with runtime.open("rb") as stream:
        assert hashlib.file_digest(stream, "sha256").hexdigest() == digest
    vectors, source_hashes = [], {}
    with tempfile.TemporaryDirectory(prefix="aurora-firmware-oracle-") as scratch:
        directory = Path(scratch)
        package = directory / "reference_firmware"
        package.mkdir()
        with tarfile.open(runtime) as archive:
            for member in archive:
                name = member.name.removeprefix("./")
                if name.startswith("asahi_firmware/") and name.endswith(".py"):
                    relative = name.removeprefix("asahi_firmware/")
                    assert "/" not in relative and member.size < 1 << 20
                    data = archive.extractfile(member).read()
                    (package / relative).write_bytes(data)
                    source_hashes[name] = sha(data)
        spec = importlib.util.spec_from_file_location("reference_firmware", package / "__init__.py",
                                                     submodule_search_locations=[str(package)])
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        wifi, bt, mt, im, controller = [importlib.import_module("reference_firmware." + name)
                                      for name in ("wifi", "bluetooth", "multitouch", "img4", "asmedia")]

        # The reference's platform decoder is replaced only for this standard
        # uncompressed LZFSE block; no native executable or hardware is called.
        def raw_lzfse(data, count):
            assert data[:4] == b"bvx-" and data[-4:] == b"bvx$"
            size, = struct.unpack_from("<I", data, 4)
            assert size == count and len(data) == size + 12
            return data[8:-4]
        im.decode_lzfse = raw_lzfse
        original = mt.device_key_to_kind
        mt.device_key_to_kind = lambda key: mt.DEVICE_KIND_TRACKPAD if key.startswith("C1FE") else original(key)

        def add(name, operation, inputs, machine="j314s", accepted=True):
            vector = dict(name=name, operation=operation, machine=machine,
                          inputs={key: base64.b64encode(value).decode() for key, value in inputs.items()})
            try:
                if operation in ("wifi", "bluetooth"):
                    with tempfile.TemporaryDirectory(dir=directory) as temporary:
                        root = Path(temporary)
                        for key, data in sorted(inputs.items()):
                            p = root / key
                            p.parent.mkdir(parents=True, exist_ok=True)
                            p.write_bytes(data)
                        collection = wifi.WiFiFWCollection(temporary) if operation == "wifi" else bt.BluetoothFWCollection(temporary)
                        outputs = {key: fw.data for key, fw in collection.files()}
                elif operation == "multitouch":
                    with tempfile.TemporaryDirectory(dir=directory) as temporary:
                        path = Path(temporary) / machine
                        path.mkdir()
                        (path / "Multitouch.im4p").write_bytes(inputs["image"])
                        outputs = {key: fw.data for key, fw in mt.MultitouchFWCollection(temporary).files()}
                elif operation == "image":
                    kind, data = im.img4p_extract(inputs["image"])
                    outputs = {kind: data}
                elif operation == "controller":
                    outputs = {fw.name: fw.data for fw in controller.extract_asmedia(inputs["kernel"])}
                vector.update(accepted=True, outputs={key: sha(data) for key, data in outputs.items()})
            except Exception as error:
                vector.update(accepted=False, referenceError=type(error).__name__)
            assert vector["accepted"] == accepted, (name, vector)
            vectors.append(vector)

        base = "C-4355__s-C1/"
        add("wifi-dimensions", "wifi", {base + "P-j314s__M-H__V-m__m-1__A-2.txt": b"  key  = value\nother=2\n",
                                       base + "j314s-2.trx": b"radio", base + "j314s-2.clmb": b"clm",
                                       base + "j314s-2.txcb": b"txcap", base + "j314s-2.sig": b"signature"})
        add("wifi-collapse-identical", "wifi", {base + "P-j314s__M-H.txt": b"a=1\n",
                                                base + "P-j314s__M-L.txt": b"a=1\n"})
        add("wifi-preserve-different", "wifi", {base + "P-j314s__M-H.txt": b"a=1\n",
                                                base + "P-j314s__M-L.txt": b"a=2\n"})
        add("wifi-exclusions", "wifi", {base + "perf/test.trx": b"excluded", base + "assert/test.trx": b"excluded",
                                         "C-4388__s-C2/test.trx": b"excluded", base + "j314s_gen.trx": b"excluded"})
        add("wifi-invalid-nvram", "wifi", {base + "P-j314s.txt": b"no equals"}, accepted=False)
        add("wifi-non-ascii", "wifi", {base + "P-j314s.txt": b"x=\xff"}, accepted=False)
        for vendor in ("AMKOR", "MUR", "USI", "GEN"):
            stem = "BCM4388B0_003.000_PCIE_macOS_Willamette_TokaraES2_" + vendor
            add("bluetooth-" + vendor, "bluetooth", {stem + ".bin": b"radio", stem + ".ptb": b"parameters"})
        add("bluetooth-no-bin", "bluetooth", {"BCM4388B0_PCIE_Tokara_MUR.ptb": b"orphan"})
        add("bluetooth-skip-dev-and-unknown", "bluetooth", {"BCM4388B0_PCIE_Tokara_MUR_DEV.bin": b"dev",
                                                            "unknown.bin": b"not supported", "legacy.hex": b"legacy"})
        add("bluetooth-ambiguous-vendor", "bluetooth", {"BCM4388B0_PCIE_Tokara_MUR_USI.bin": b"ambiguous"})
        for key, machine in (("C1FD0,0", "j314s"), ("C1FE0,0", "j700")):
            add("trackpad-" + machine, "multitouch", {"image": image("mtfw", firmware_xml({key: trackpad()}))}, machine)
        add("trackpad-lzfse", "multitouch", {"image": image("mtfw", firmware_xml({"C1FD0,0": trackpad()}), True)})
        add("touchbar-all-commands", "multitouch", {"image": image("mtfw", firmware_xml({"C1FB0,0": touchbar()}))})
        xml = firmware_xml({"C1FD0,0": trackpad()})
        xml = xml.replace(b"<true />", b'<true ID="flag" />').replace(b"<false />", b'<true IDREF="flag" />')
        add("trackpad-id-reference", "multitouch", {"image": image("mtfw", xml)})
        records = trackpad()
        records[1]["Name"] = "a&b"
        cdata = firmware_xml({"C1FD0,0": records}).replace(b"a&amp;b", b"<![CDATA[a&b]]>")
        add("trackpad-cdata", "multitouch", {"image": image("mtfw", cdata)})
        add("trackpad-missing-interface", "multitouch", {"image": image("mtfw", firmware_xml({"C1FD0,0": []}))}, accepted=False)
        add("trackpad-duplicate-output", "multitouch", {"image": image("mtfw", firmware_xml({"C1FD0,0": trackpad(),
                                                                                                "C1FE0,0": trackpad()}))}, accepted=False)
        add("image-plain", "image", {"image": image("krnl", b"synthetic kernel")})
        add("image-lzfse", "image", {"image": image("krnl", b"synthetic kernel", True)})
        add("image-truncated", "image", {"image": image("krnl", b"synthetic kernel")[:-1]}, accepted=False)
        add("image-lzfse-wrong-count", "image", {"image": image("krnl", b"synthetic kernel", True, 999)}, accepted=False)
        record = bytearray(0x33)
        record[:10] = b"2214A_RCFG"
        struct.pack_into("<I", record, 0x2f, 0x18000)
        add("controller-complete", "controller", {"kernel": b"prefix" + record + b"s" * 0x18000})
        add("controller-missing", "controller", {"kernel": b"no controller"}, accepted=False)
        struct.pack_into("<I", record, 0x2f, 0x1234)
        add("controller-wrong-length", "controller", {"kernel": bytes(record)}, accepted=False)
    return dict(runtimeSHA256=digest, referenceSources=source_hashes, vectors=vectors)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    if args.runtime:
        result = generate(args.runtime)
        encoded = json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n"
        if args.write:
            OUTPUT.write_text(encoded)
        elif OUTPUT.read_text() != encoded:
            raise SystemExit("Generic firmware vectors differ from authenticated reference source")
    else:
        result = json.loads(OUTPUT.read_text())
        pin = (ROOT / "Sources/OmarchyAppleInstaller/ValidationEngineArtifact.swift").read_text()
        assert result["runtimeSHA256"] == re.search(r'expectedDigest\s*=\s*"sha256:([0-9a-f]{64})"', pin)[1]
    print(f"Verified {len(result['vectors'])} shared native firmware conversion vectors")
