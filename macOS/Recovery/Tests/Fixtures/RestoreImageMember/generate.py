#!/usr/bin/env python3
"""Regenerate the archives and expected.json for Tests/RestoreImageMemberCheck.swift.

Independent reference: Python's zipfile. classic.zip has stored and deflated
members; zip64-local.zip writes every member with force_zip64, so each local
header carries a ZIP64 extra field its central entry doesn't. Deterministic.
Usage (from this directory): python3 generate.py
"""
import json
import struct
import zipfile

members = [
    ("141-12144-174.dmg.aea", b"AEA1" + bytes(range(256)) * 4, zipfile.ZIP_STORED),
    ("BuildManifest.plist", b"<plist>" + b"x" * 2000 + b"</plist>", zipfile.ZIP_DEFLATED),
    ("Firmware/all_flash/LLB.im4p", b"\x30\x82" + b"\x00" * 100, zipfile.ZIP_STORED),
    ("Restore.plist", b"<plist/>", zipfile.ZIP_STORED),
]
expected = {}
for file, force in (("classic.zip", False), ("zip64-local.zip", True)):
    with zipfile.ZipFile(file, "w") as archive:
        for name, data, method in members:
            info = zipfile.ZipInfo(name, date_time=(2026, 11, 23, 0, 0, 0))
            info.compress_type = method
            with archive.open(info, "w", force_zip64=force) as out:
                out.write(data)
    raw = open(file, "rb").read()
    expected[file] = {}
    with zipfile.ZipFile(file) as archive:
        for info in archive.infolist():
            at = info.header_offset
            assert raw[at:at + 4] == b"PK\x03\x04"
            name_length, extra_length = struct.unpack_from("<HH", raw, at + 26)
            offset = at + 30 + name_length + extra_length
            stored = info.compress_type == zipfile.ZIP_STORED
            if stored:
                assert raw[offset:offset + info.file_size] == archive.read(info.filename)
            expected[file][info.filename] = {
                "stored": stored, "offset": offset, "size": info.file_size, "crc32": info.CRC}
json.dump(expected, open("expected.json", "w"), indent=2, sort_keys=True)
