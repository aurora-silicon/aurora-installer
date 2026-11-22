#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Write the synthetic seed corpus for each fuzz harness.

Every seed is generated here or taken from the package's synthetic test
fixtures; none comes from an Apple file. Usage: make-seeds.py <output-dir>.
"""

import base64
import io
import json
import struct
import sys
import zipfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Tests" / "AuroraFirmwareTests" / "Fixtures"
NEO = ROOT / "Tests" / "NativeFirmwareFixtureSupport" / "Fixtures"

SEGMENT_BYTES = 1 << 20
CLUSTER_WIDTH = 256
CLUSTER_HEADER_BYTES = CLUSTER_WIDTH * 72 + 32


def le(value, width):
    return value.to_bytes(width, "little")


def be(value, width):
    return value.to_bytes(width, "big")


def write(out, target, name, data):
    path = out / target / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def zip_seeds():
    seeds = {}
    for archive in json.loads((FIXTURES / "zip-interop.json").read_text())["archives"]:
        seeds["fixture-" + archive["name"]] = base64.b64decode(archive["data"])

    def build(name, entries, force_zip64=False):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            for info, body in entries:
                with archive.open(info, "w", force_zip64=force_zip64) as member:
                    member.write(body)
        seeds[name] = buffer.getvalue()

    def info(name, method=zipfile.ZIP_STORED, mode=0o100644):
        entry = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
        entry.compress_type = method
        entry.external_attr = mode << 16
        return entry

    body = b"Aurora synthetic restore member\n" * 8
    build("stored", [(info("BuildManifest.plist"), body)])
    build("deflate", [(info("BuildManifest.plist", zipfile.ZIP_DEFLATED), body)])
    build(
        "tree",
        [
            (info("Firmware/", mode=0o040755), b""),
            (info("Firmware/a.im4p", zipfile.ZIP_DEFLATED), body),
            (info("Firmware/link", mode=0o120777), b"a.im4p"),
            (info("Restore.plist"), b"<plist/>"),
        ],
    )
    build("zip64", [(info("big.dmg", zipfile.ZIP_DEFLATED), body)], force_zip64=True)

    # A data descriptor: written through a stream that cannot seek back.
    class Forward(io.RawIOBase):
        def __init__(self):
            self.data = bytearray()

        def writable(self):
            return True

        def write(self, chunk):
            self.data += chunk
            return len(chunk)

    stream = Forward()
    with zipfile.ZipFile(stream, "w") as archive:
        with archive.open(info("stream.bin", zipfile.ZIP_DEFLATED), "w") as member:
            member.write(body)
    seeds["descriptor"] = bytes(stream.data)
    return seeds


def update_image_member(chunks, output, chunk_bytes=4096, control=0):
    stream = b"pbzx" + be(chunk_bytes, 8)
    for out_len, stored in chunks:
        stream += be(out_len, 8) + be(len(stored), 8) + stored
    # The fuzz build's SHA-1 is constant zero.
    return (
        b"BXDIFF50" + bytes(8) + le(output, 8) + le(control, 8) + le(len(stream), 8)
        + bytes(20) + stream
    )


def update_image_seeds():
    stored = bytes(range(256)) * 16
    # A "compressed" chunk for the Compression shim: decoded size at byte 4.
    packed = b"\xfd7zX" + le(4096, 4) + b"XZ"
    seeds = {
        "stored": bytes([255]) + update_image_member([(4096, stored)], 4096),
        "mixed": bytes([7])
        + update_image_member([(4096, packed), (4096, stored), (100, stored[:100])], 8292),
        "control": bytes([0]) + update_image_member([(16, bytes(16))], 16, control=5),
    }
    return seeds


def fuzz_hash(index):
    return "0" * 62 + "%02x" % index


def aea_prefix(decoded, system):
    url = b"https://wkms-public.apple.com/fcs-keys/" + b"A" * 43 + b"="
    response = json.dumps({"enc-request": "AA==", "wrapped-key": "AA=="}).encode()
    entries = [b"com.apple.wkms.fcs-key-url\0" + url, b"com.apple.wkms.fcs-response\0" + response]
    body = b"".join(le(len(entry) + 4, 4) + entry for entry in entries)
    header = le(decoded, 8) + le(system, 8) + le(SEGMENT_BYTES, 4) + le(CLUSTER_WIDTH, 4)
    header += b"e" + bytes([2])
    header += bytes(48 - len(header))
    # The root header's last field is cluster 0's MAC, which the recipe pins.
    root = bytes(32) + header + bytes.fromhex(fuzz_hash(4))
    return b"AEA1" + le(1, 4) + le(len(body), 4) + body + bytes(32) + root


def aea_seed(segment, plain):
    prefix_len = None
    decoded = plain
    # The system size covers the prefix, the cluster header and the segment.
    probe = aea_prefix(decoded, 0)
    prefix_len = len(probe)
    offset = prefix_len + CLUSTER_HEADER_BYTES
    system = offset + len(segment)
    prefix = aea_prefix(decoded, system)
    table = le(plain, 4) + le(len(segment), 4) + bytes(32)
    table += bytes(CLUSTER_WIDTH * 40 - len(table))
    cluster = table + bytes(CLUSTER_HEADER_BYTES - len(table))
    head = le(decoded, 4) + le(system, 4) + le(offset, 4) + le(len(segment), 3)
    return head + le(len(prefix), 3) + prefix + cluster + segment, (decoded, system, offset, prefix)


def aea_seeds():
    stored, _ = aea_seed(bytes(range(256)) * 16, 4096)
    lzfse = b"bvxn" + le(4096, 4) + le(16, 4) + bytes(16) + b"bvx$"
    packed, _ = aea_seed(lzfse, 4096)
    return {"stored": stored, "lzfse": packed}


def recipe_seeds():
    _, (decoded, system, offset, prefix) = aea_seed(bytes(4096), 4096)
    recipe = {
        "schema": 1,
        "source": {
            "url": "https://updates.cdn-apple.com/fuzz.ipsw",
            "size_bytes": system + 31,
            "sha256": fuzz_hash(6),
        },
        "system_image": {
            "member": "s",
            "size_bytes": system,
            "sha256": fuzz_hash(7),
            "decoded": {"size_bytes": decoded, "sha256": fuzz_hash(8)},
        },
        "member_offset": 31,
        "zip_header": {"offset": 0, "size": 31, "sha256": fuzz_hash(1)},
        "prefix": {"offset": 0, "size": len(prefix), "sha256": fuzz_hash(2)},
        "headers": [
            {
                "offset": len(prefix),
                "size": CLUSTER_HEADER_BYTES,
                "sha256": fuzz_hash(3),
                "cluster": 0,
                "expected_mac": fuzz_hash(4),
            }
        ],
        "segments": {"0": {"offset": offset, "size": 4096, "sha256": fuzz_hash(5)}},
        "files": [
            {
                "source": "s",
                "name": "dir/f",
                "transform": "nvram",
                "compressed": True,
                "raw_sha256": fuzz_hash(9),
                "sha256": fuzz_hash(9),
                "size": 100,
                "storage": [
                    {"size": 16, "sha256": fuzz_hash(10), "spans": [{"offset": 0, "size": 16}]},
                    {"size": 84, "sha256": fuzz_hash(11), "spans": [{"offset": 16, "size": 84}]},
                ],
            }
        ],
    }
    seeds = {"synthetic": json.dumps(recipe).encode()}
    go = json.loads((FIXTURES / "go-aea.json").read_text())["recipe"]
    seeds["go-aea"] = json.dumps(go).encode()
    return seeds


def apfs_seeds():
    def attr(kind, size, tail=b""):
        return b"fpmc" + le(kind, 4) + le(size, 8) + tail

    def inline(data):
        return bytes([0]) + le(len(data), 2) + data

    def forked(attribute, fork):
        return bytes([6]) + le(len(attribute), 2) + attribute + fork

    text = b"synthetic decmpfs block " * 4
    lzvn = bytes([0xE8]) + bytes([6, 0, 0, 0, 0, 0, 0, 0]) + bytes([6, 0, 0, 0, 0, 0, 0, 0])
    zlib_block = zlib.compress(text)
    table_entries = le(264 + 8 - 260, 4) + le(len(zlib_block), 4)
    zlib_fork = be(256, 4) + bytes(256) + le(1, 4) + table_entries + zlib_block
    raw_block = bytes([6]) + text
    lzvn_fork = le(8, 4) + le(8 + len(raw_block), 4) + raw_block
    lzfse = b"bvx-" + le(len(text), 4) + text + b"bvx$"
    lzfse_fork = le(8, 4) + le(8 + len(lzfse), 4) + lzfse
    return {
        "zlib-inline": inline(attr(3, len(text), zlib_block)),
        "raw-inline": inline(attr(3, len(text), b"\xff" + text)),
        "zlib-fork": forked(attr(4, len(text)), zlib_fork),
        "lzvn-inline": inline(attr(7, 8, lzvn + b"\xa5")),
        "lzvn-fork": forked(attr(8, len(text)), lzvn_fork),
        "lzfse-inline": inline(attr(11, len(text), lzfse)),
        "lzfse-fork": forked(attr(12, len(text)), lzfse_fork),
        "lzfse-blocks": bytes([1]) + le(4096, 3)
        + b"bvxn" + le(64, 4) + le(4, 4) + bytes(4) + b"bvx-" + le(4, 4) + b"abcd" + b"bvx$",
        "lzvn": bytes([2]) + le(8, 3) + lzvn + b"\xa5",
    }


def thin_macho(section_address, section_size, symbols, code):
    """A thin 64-bit Mach-O: one section holding `code`, and a symbol table."""
    strings = b"\0"
    entries = b""
    for name, value in symbols:
        entries += struct.pack("<IBBHQ", len(strings), 0x0F, 1, 0, value)
        strings += name.encode() + b"\0"
    segment_size = 72 + 80
    commands = segment_size + 24
    code_offset = 32 + commands
    symbols_offset = code_offset + len(code)
    strings_offset = symbols_offset + len(entries)
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 0xB, 2, commands, 0, 0)
    segment = struct.pack("<II16sQQQQiiII", 0x19, segment_size, b"__TEXT", section_address,
                          section_size, 0, len(code), 5, 5, 1, 0)
    section = struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", section_address,
                          section_size, code_offset, 2, 0, 0, 0, 0, 0, 0)
    symtab = struct.pack("<IIIIII", 0x2, 24, symbols_offset, len(symbols), strings_offset,
                         len(strings))
    return header + segment + section + symtab + code + entries + strings


def firmware_format_seeds():
    seeds = {}
    # MOVZ w0, #0x6041; ADRP x1, 0; ADD x1, x1, #0; RET
    code = struct.pack("<IIII", 0x52880820, 0x90000001, 0x91000021, 0xD65F03C0)
    address = 0xFFFFFE0007004000
    seeds["prores-thin"] = bytes([2]) + thin_macho(
        address, len(code),
        [("_tunableh_prores_figs_5_apply_to", address), ("_after", address + len(code)),
         ("_tunableh_prores_figs_5.figs", address)],
        code)
    # Section geometry the ProRes reader must refuse: an end past the address
    # space, and code further into a section than any file offset.
    seeds["prores-wrap"] = bytes([2]) + thin_macho(
        address, 2**64 - 0x1000, [("_tunableh_prores_figs_5_apply_to", address)], code)
    far = 2**63 + 0x1000
    seeds["prores-far"] = bytes([2]) + thin_macho(
        0, 2**64 - 1,
        [("_tunableh_prores_figs_5_apply_to", far), ("_after", far + len(code))], code)
    generic = json.loads((FIXTURES / "generic-firmware.json").read_text())
    selector = {"image": 0, "controller": 1, "multitouch": 3}
    for vector in generic["vectors"]:
        if vector["operation"] in selector:
            for data in vector["inputs"].values():
                seeds["generic-" + vector["name"]] = bytes(
                    [selector[vector["operation"]]]
                ) + base64.b64decode(data)
                if vector["operation"] == "controller":
                    seeds["prores-" + vector["name"]] = bytes([2]) + base64.b64decode(data)
    neo = json.loads((NEO / "neo-conversion-vectors.json").read_text())
    selector = {
        "camera": 5, "als": 6, "address": 7, "config": 8, "factory": 9, "oca": 10,
        "bluetooth": 11, "ptx": 12, "policy": 13,
    }
    for vector in neo["vectors"]:
        if vector["operation"] in selector and vector["data"]:
            seeds["neo-" + vector["name"]] = bytes(
                [selector[vector["operation"]]]
            ) + base64.b64decode(vector["data"])
    sensor = json.loads((FIXTURES / "sensor-calibration.json").read_text())
    for vector in sensor["vectors"]:
        data = base64.b64decode(vector["input"])
        for choice in (15, 16, 17, 19):
            seeds["sensor-%d-%s" % (choice, vector["name"])] = bytes([choice]) + data
        seeds["sensor-18-" + vector["name"]] = bytes([18]) + le(len(data), 2) + data
    for index, key in enumerate(sensor["rootKeys"]):
        seeds["rootkey-%d" % index] = bytes([14]) + base64.b64decode(key["input"])
    seeds["plist"] = bytes([4]) + (
        b'<?xml version="1.0"?><plist version="1.0"><dict><key>a</key><array>'
        b"<integer>1</integer><data>AAE=</data><string>x</string><true/></array></dict></plist>"
    )
    return seeds


def firmware_input_seeds():
    def records(selector, files):
        data = bytes([selector])
        for name, body in files.items():
            raw = name.encode()
            data += bytes([len(raw)]) + raw + le(len(body), 2) + body
        return data

    seeds = {}
    generic = json.loads((FIXTURES / "generic-firmware.json").read_text())
    selector = {"wifi": 0, "bluetooth": 1}
    for vector in generic["vectors"]:
        if vector["operation"] in selector:
            files = {name: base64.b64decode(data) for name, data in vector["inputs"].items()}
            seeds[vector["name"]] = records(selector[vector["operation"]], files)
    package = json.loads((FIXTURES / "package-interop.json").read_text())
    files = {entry["name"]: base64.b64decode(entry["base64"]) for entry in package["files"]}
    seeds["package"] = records(2, files)
    return seeds


def template_seeds():
    import plistlib

    info = plistlib.dumps(
        {
            "CFBundleDisplayName": "Aurora Installer",
            "CFBundleExecutable": "OmarchyRecovery",
            "OmarchyRecoveryBuildMode": "recovery",
            "OmarchyRecoveryDataLayout": "external-install-data-v1",
        }
    )

    def archive(files):
        encoded = {name: base64.b64encode(body).decode() for name, body in files.items()}
        return json.dumps(encoded, sort_keys=True).encode()

    app = {
        "Contents/Info.plist": info,
        "Contents/MacOS/OmarchyRecovery": b"\xcf\xfa\xed\xfe synthetic",
        "Contents/Resources/a/b.txt": b"resource",
    }
    return {
        "app": archive(app),
        "no-executable": archive({"Contents/Info.plist": info}),
        "bad-name": archive({"Contents/../x": b"x"}),
    }


def transcript_seeds():
    digest = "sha256:" + "0" * 64
    lines = [
        {"schema_version": 1, "sequence": 1, "type": "inspection",
         "payload": {"device_identifier": "apple,j314s", "support": "supported"}},
        {"schema_version": 1, "sequence": 2, "type": "inventory",
         "payload": {"layout_digest": digest, "system_store_identifier": "disk0",
                     "candidates": [{"kind": "free", "source_identifier": "disk0s3",
                                     "offset_bytes": 2000, "length_bytes": 1000,
                                     "minimum_install_bytes": 500,
                                     "minimum_container_bytes": 0}]}},
        {"schema_version": 1, "sequence": 3, "type": "plan",
         "payload": {"plan_digest": digest, "device_identifier": "apple,j314s",
                     "store_identifier": "disk0", "layout_digest": digest,
                     "candidate_kind": "free", "source_identifier": "disk0s3",
                     "offset_bytes": 2000, "length_bytes": 1000, "engine_version": "1",
                     "engine_digest": digest, "metadata_digest": digest,
                     "payload_digest": digest, "required_human_steps": []}},
        {"schema_version": 1, "sequence": 4, "type": "completion",
         "payload": {"plan_digest": digest, "outcome": "succeeded"}},
    ]
    text = b"".join(json.dumps(line).encode() + b"\n" for line in lines)
    return {"transcript": text, "short": text.split(b"\n")[0] + b"\n"}


def fat_image():
    """A tiny FAT32 partition: one-sector clusters, a 16-cluster data area."""
    sector = 512
    reserved, fats, fat_sectors, clusters = 1, 2, 1, 16
    total = reserved + fats * fat_sectors + clusters
    boot = bytearray(sector)
    boot[0:3] = b"\xeb\x58\x90"
    boot[3:11] = b"AURORA  "
    struct.pack_into("<HBHBHHBHHHII", boot, 11, sector, 1, reserved, fats, 0, 0, 0xF8, 0,
                     32, 64, 0, total)
    struct.pack_into("<IHHI", boot, 36, fat_sectors, 0, 0, 2)
    boot[510:512] = b"\x55\xaa"
    fat = [0x0FFFFFF8, 0x0FFFFFFF] + [0] * (sector // 4 - 2)
    data = [bytearray(sector) for _ in range(clusters)]

    def checksum(short):
        total = 0
        for byte in short:
            total = (((total >> 1) | ((total & 1) << 7)) + byte) & 0xFF
        return total

    def entry(short, attributes, cluster, size):
        record = bytearray(32)
        record[0:11] = short
        record[11] = attributes
        struct.pack_into("<H", record, 20, cluster >> 16)
        struct.pack_into("<HI", record, 26, cluster & 0xFFFF, size)
        return bytes(record)

    def long_name(name, short):
        units = list(name.encode("utf-16-le"))
        units = [units[i] | units[i + 1] << 8 for i in range(0, len(units), 2)] + [0]
        pieces = [units[i:i + 13] for i in range(0, len(units), 13)]
        records = []
        for order, piece in enumerate(pieces, 1):
            piece = piece + [0xFFFF] * (13 - len(piece))
            record = bytearray(32)
            record[0] = order | (0x40 if order == len(pieces) else 0)
            record[11] = 0x0F
            record[13] = checksum(short)
            positions = list(range(1, 11, 2)) + list(range(14, 26, 2)) + list(range(28, 32, 2))
            for at, unit in zip(positions, piece):
                struct.pack_into("<H", record, at, unit)
            records.append(bytes(record))
        return b"".join(reversed(records))

    conf = b"format=1\nencrypt=0\nlane=stable\n"
    boot_bin = b"##aura_ver##1.0\0" + bytes(600)
    # Root (2): omarchy/ (3), m1n1/ (4); omarchy/install.conf (5);
    # m1n1/boot.bin (6, 7).
    root = long_name("omarchy", b"OMARCHY    ") + entry(b"OMARCHY    ", 0x10, 3, 0)
    root += entry(b"M1N1       ", 0x10, 4, 0)
    data[0][: len(root)] = root
    short = b"INSTAL~1CON"
    omarchy = entry(b".          ", 0x10, 3, 0) + long_name("install.conf", short)
    omarchy += entry(short, 0x20, 5, len(conf))
    data[1][: len(omarchy)] = omarchy
    data[2][:32] = entry(b"BOOT    BIN", 0x20, 6, len(boot_bin))
    data[3][: len(conf)] = conf
    data[4][:] = boot_bin[:sector]
    data[5][: len(boot_bin) - sector] = boot_bin[sector:]
    for cluster in (2, 3, 4, 5, 7):
        fat[cluster] = 0x0FFFFFFF
    fat[6] = 7
    table = b"".join(struct.pack("<I", value) for value in fat)
    return bytes(boot) + table * fats + b"".join(bytes(block) for block in data)


def main():
    out = Path(sys.argv[1])
    for target, seeds in [
        ("ipsw_zip", zip_seeds()),
        ("update_image", update_image_seeds()),
        ("aea_ranges", aea_seeds()),
        ("range_recipe", recipe_seeds()),
        ("apfs_storage", apfs_seeds()),
        ("firmware_formats", firmware_format_seeds()),
        ("firmware_inputs", firmware_input_seeds()),
        ("recovery_template", template_seeds()),
        ("fat_volume", {"esp": fat_image()}),
        ("engine_transcript", transcript_seeds()),
    ]:
        for name, data in seeds.items():
            write(out, target, name, data)


if __name__ == "__main__":
    main()
