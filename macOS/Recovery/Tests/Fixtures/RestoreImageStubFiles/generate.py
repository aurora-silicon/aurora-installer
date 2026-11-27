#!/usr/bin/env python3
"""Regenerate the restore images and expected.json for RestoreImageStubFilesCheck.swift.

Built on ../RestoreImageStubPlan/generate.py's base image (every image here admits a plan):
- big.zip: the Recovery image and the kernel cache stored at 160 KiB + 3 and an all_flash
  firmware deflated at 192 KiB + 1, so with the check's 4 KiB and 64 KiB chunks a copy
  spans many chunks and a deflated one ends mid-chunk;
- aea.zip: the Recovery image and the kernel cache (stored) and the restore ticket
  (deflated), all at the top of the restore directory, and one all_flash firmware (not
  at the top) start with "AEA1"; the trust cache starts with "AEA" only;
- aea-decode.zip: real Apple Encrypted Archives (../RestoreImageArchive/aea.py, disposable
  key) as the Recovery image (a disk image: it ends in a "koly" trailer), the kernel cache
  (stored) and the restore ticket (deflated) at the top of the restore directory, and one
  all_flash firmware below it, which is copied as it is; aea-no-koly.zip the same with a
  Recovery image that doesn't end in a trailer, and aea-tampered.zip with one byte of the
  Recovery image's segment changed (the ZIP CRC is taken after the change);
- deflate-trailing / deflate-long / deflate-short / deflate-truncated / deflate-short-crc /
  stored-crc: one firmware body that decodes with trailing input, to more or fewer bytes
  than declared, stops before its end, decodes 4 bytes short to the declared CRC, or a
  stored body with a wrong CRC.
expected.json holds, for these images and for every image of ../RestoreImageStubPlan that
admits a plan, each member's SHA-256 as Python's zipfile reads it and the files left
pending without an archive key (Apple Encrypted Archives at the top of the restore
directory, decoded first, and the Recovery image if it is one, kept compressed) with
their receipt positions; for the aea-* images also the key, and either each decoded
member's length and SHA-256 or the failure a run with the key stops at. Deterministic.
Usage (from this directory; needs what ../RestoreImageArchive/generate.py needs):
python3 generate.py
"""
import hashlib
import json
import os
import random
import sys
import tempfile
import zipfile
import zlib

# The plan generator writes its own images when imported: let it, somewhere else.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                                "RestoreImageStubPlan"))
with tempfile.TemporaryDirectory() as scratch:
    _cwd = os.getcwd()
    os.chdir(scratch)
    import generate as plan  # noqa: E402
    os.chdir(_cwd)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                                "RestoreImageArchive"))
import aea as archive_writer  # noqa: E402

LLB = "Firmware/all_flash/LLB.j314s.RELEASE.im4p"
IBOOT = "Firmware/all_flash/iBoot.j314s.RELEASE.im4p"
KERNEL = "kernelcache.release.mac14j"
RECOVERY = "090-00001-001.dmg"
TRUST = "BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache"
TICKET = "Firmware/Manifests/restore/macOS Customer/apticket.j314s.im4m"


def plan_images():
    """The plan fixtures that admit a plan, with their members as zipfile reads them."""
    reference = json.load(open(os.path.join("..", "RestoreImageStubPlan", "expected.json")))
    admitted = {**reference["cases"], **reference["recovery_only"]}
    out = []
    for name in sorted(n for n, v in admitted.items() if isinstance(v, dict)):
        with zipfile.ZipFile(os.path.join("..", "RestoreImageStubPlan", name + ".zip")) as z:
            members = {}
            for i in z.infolist():
                kind = {0o100000: "file", 0o120000: "link", 0o040000: "dir"}[
                    (i.external_attr >> 16) & 0o170000]
                members[i.filename] = (z.read(i), kind, i.compress_type == 8)
        out.append((name, members))
    return out


def forge(prefix, target):
    """4 bytes that make crc32(prefix + bytes) == target: the CRC is affine in them."""
    base = zlib.crc32(prefix + bytes(4))
    columns = [zlib.crc32(prefix + (1 << i).to_bytes(4, "little")) ^ base for i in range(32)]
    # Gaussian elimination over GF(2): x whose set bits' columns XOR to target ^ base.
    basis = []
    for i, col in enumerate(columns):
        v, m = col, 1 << i
        for bv, bm in basis:
            if v ^ bv < v:
                v, m = v ^ bv, m ^ bm
        if v:
            basis.append((v, m))
            basis.sort(reverse=True)
    x, v = 0, target ^ base
    for bv, bm in basis:
        if v ^ bv < v:
            v, x = v ^ bv, x ^ bm
    assert v == 0
    assert zlib.crc32(prefix + x.to_bytes(4, "little")) == target
    return x.to_bytes(4, "little")


def pending(members, chosen):
    """The files the writer leaves pending, with their receipt positions."""
    restore = chosen["restorePath"].encode()
    out, position = [], 0
    for copy in chosen["copies"]:
        data, kind, _ = members[copy["member"]]
        path = copy["path"].encode()
        top = (copy["role"] == "Preboot" and path.startswith(restore + b"/")
               and b"/" not in path[len(restore) + 1:])
        if kind == "file" and top and data[:4] == b"AEA1":
            out.append({"member": copy["member"], "role": copy["role"], "path": copy["path"],
                        "installer_data": copy.get("installerDataName"), "aea": True,
                        "compressed": False, "position": position})
        else:
            position += 1
    position += 1  # BuildManifest.plist
    recovery = chosen["recovery"]
    # A Recovery image that isn't an Apple Encrypted Archive is copied, compressed.
    if members[recovery][0][:4] == b"AEA1":
        out.append({"member": recovery, "role": "Recovery",
                    "path": "usr/standalone/firmware/arm64eBaseSystem.dmg",
                    "installer_data": None, "aea": True, "compressed": True,
                    "position": position})
    return out


def noise(seed, count):
    r = random.Random(seed)
    return bytes(r.getrandbits(8) for _ in range(count))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    os.chdir(here)
    expected = {}

    def record(name, members, path=None):
        chosen = plan.plan(members)
        assert chosen is not None, name
        # Each member as Python's zipfile reads it back from the written image.
        with zipfile.ZipFile(path or name + ".zip") as archive:
            sums = {i.filename: hashlib.sha256(archive.read(i)).hexdigest()
                    for i in archive.infolist() if (i.external_attr >> 16) & 0o170000 == 0o100000}
        assert sums == {n: hashlib.sha256(d).hexdigest()
                        for n, (d, kind, _) in members.items() if kind == "file"}, name
        expected[name] = {"sha256": sums, "pending": pending(members, chosen)}

    big = plan.base()
    big[RECOVERY] = (noise(1, (160 << 10) + 3), "file", False)
    big[KERNEL] = (noise(2, (160 << 10) + 3), "file", False)
    # Compressible but not trivially (16 symbols at random): a long deflated body whose
    # input and output both span many chunks.
    symbols = random.Random(3)
    big[IBOOT] = (bytes(symbols.choice(b"iBoot0123456789!") for _ in range((192 << 10) + 1)),
                  "file", True)
    plan.write("big.zip", big)
    record("big", big)

    aea = plan.base()
    aea[RECOVERY] = (b"AEA1" + noise(4, 300), "file", False)
    aea[KERNEL] = (b"AEA1" + noise(5, 200), "file", False)
    aea[LLB] = (b"AEA1" + noise(6, 100), "file", True)
    aea[TRUST] = (b"AEA" + noise(7, 61), "file", False)
    aea[TICKET] = (b"AEA1" + bytes(400), "file", True)
    plan.write("aea.zip", aea)
    record("aea", aea)
    assert [p["member"] for p in expected["aea"]["pending"]] == [TICKET, KERNEL, RECOVERY] or \
        [p["member"] for p in expected["aea"]["pending"]] == [KERNEL, TICKET, RECOVERY]

    # Real archives under one disposable key.
    key = bytes(range(100, 132))
    disk = noise(8, 6000) + b"koly" + bytes(508)
    kernel = noise(9, 5000)
    ticket = bytes(range(256)) * 3
    firmware = archive_writer.build(noise(10, 700), key)[0]
    decoded = {RECOVERY: disk, KERNEL: kernel, TICKET: ticket}

    def encrypted(recovery):
        members = plan.base()
        # Padded past its last segment, as Apple's Recovery images are.
        members[RECOVERY] = (archive_writer.build(recovery, key, extra=noise(11, 2000))[0],
                             "file", False)
        members[KERNEL] = (archive_writer.build(kernel, key)[0], "file", False)
        members[TICKET] = (archive_writer.build(ticket, key)[0], "file", True)
        members[LLB] = (firmware, "file", True)
        return members

    for name, recovery, refuse in [("aea-decode", disk, None),
                                   ("aea-no-koly", noise(8, 6512), "invalidImage"),
                                   ("aea-tampered", disk, "authentication")]:
        members = encrypted(recovery)
        if name == "aea-tampered":
            body = bytearray(members[RECOVERY][0])
            body[-2100] ^= 0x01  # in the segment, before the 2000 bytes of padding
            members[RECOVERY] = (bytes(body), "file", False)
        plan.write(name + ".zip", members)
        record(name, members)
        expected[name]["key"] = key.hex()
        if refuse:
            expected[name]["refuse"] = refuse
        else:
            expected[name]["decoded"] = {
                n: {"bytes": len(d), "sha256": hashlib.sha256(d).hexdigest()}
                for n, d in decoded.items()}

    # Every image of the plan fixtures that admits a plan, from its own members.
    for name, members in plan_images():
        record("plan/" + name, members, os.path.join("..", "RestoreImageStubPlan", name + ".zip"))

    body = plan.base()[LLB][0]
    bad = {
        "deflate-trailing": plan.raw_deflate(body) + b"\x00junk",
        "deflate-long": plan.raw_deflate(body + b"more"),
        "deflate-short": plan.raw_deflate(body[:-1]),
        "deflate-truncated": plan.raw_deflate(body)[:-3],
        # 4 bytes short, with the declared CRC: only the length shows it.
        "deflate-short-crc": plan.raw_deflate(body[:-8] + forge(body[:-8], zlib.crc32(body))),
    }
    for name, raw in bad.items():
        plan.write_raw(name + ".zip", plan.base(), (LLB, raw))
        expected[name] = "refuse"
    # A stored body with one byte changed after its CRC was taken.
    members = plan.base()
    plan.write("stored-crc.zip", members)
    data = bytearray(open("stored-crc.zip", "rb").read())
    trust = members[TRUST][0]
    at = data.index(trust)
    data[at + 10] ^= 0xFF
    open("stored-crc.zip", "wb").write(bytes(data))
    expected["stored-crc"] = "refuse"

    with open("expected.json", "w") as out:
        json.dump(expected, out, indent=1, sort_keys=True)
        out.write("\n")


if __name__ == "__main__":
    main()
