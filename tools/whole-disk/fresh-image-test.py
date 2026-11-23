#!/usr/bin/env python3
"""Replays a fresh whole-disk installation on disk images.

The planner is the Recovery app's own (macOS/Recovery/Sources/FreshWholeDisk.swift,
built into fresh-whole-disk-tool). This script plays diskutil: it deletes the
macOS container's partition and adds each new partition right after its
predecessor in the GPT of a sparse disk image, the way `diskutil apfs
deleteContainer` and `diskutil addPartition <predecessor>` do, and writes the
EFI file system and the boot and root images into their partitions. The APFS
listings (which containers hold which volumes) are fixtures; the partition
geometry is real GPT on a real file.

The disk is the J473's (251 GB, 4096-byte sectors) as Apple ships it: its iSC
and System Recovery entries are the Mac's own bytes, and macOS fills the space
between them.

For every point an installation can stop at, it stops there, then resumes
from the disk alone (once with the reviewed reading, as Recovery's journal
keeps it, once without), and checks that every run ends with the same layout:
iSC, startup container, EFI, Boot, Root up to System Recovery, and System
Recovery, with iSC and System Recovery byte for byte as before. It also checks
that a disk holding anything else, or a change between review and deletion,
refuses with the image unchanged.

usage: fresh-image-test.py TOOL GPT WORKDIR
  TOOL        the built fresh-whole-disk-tool
  GPT         `j473` (the J473's factory table shape, built here) or a file
              with LBA 1-5 of a Mac (header and entries, 4096-byte sectors)
  WORKDIR     where the sparse images go (each is 251 GB apparent, a few MB used)
"""

import hashlib
import json
import os
import subprocess
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aurora_whole_disk as wd  # noqa: E402

SS = 4096
TYPES = {wd.ISC: "Apple_APFS_ISC", wd.APFS: "Apple_APFS", wd.RECOVERY: "Apple_APFS_Recovery",
         wd.EFI: "EFI", wd.LINUX: "Linux Filesystem"}
ADD_TYPES = {"apfs": wd.APFS, "%EFI%": wd.EFI, "%Linux%": wd.LINUX}
REQUEST = {"stubBytes": 5_999_951_872, "espBytes": 524_288_000, "bootBytes": 1_073_741_824,
           "rootMinimumBytes": 34_359_738_368, "label": "Aurora"}
MACOS_GROUP = "1C4CD44A-0C57-46F1-A834-58808BFF3A68"


def fail(msg):
    print("FAIL:", msg)
    sys.exit(1)


def j473_factory():
    """LBA 1-5 of a J473 as Apple ships it: the geometry, types and names of
    the Mac's own table (4096-byte sectors, first-lba 6, last-lba 61279338,
    iSC, macOS up to System Recovery, System Recovery in entry 7), with UUIDs
    made up here so no Mac's identifiers are in the repository."""
    import struct
    import zlib

    def guid(name):
        return uuid.uuid5(uuid.NAMESPACE_OID, "j473-factory/" + name).bytes_le

    ents = bytearray(128 * wd.ENTRY)
    for slot, (ptype, name, first, last, label) in {
            0: (wd.ISC, "isc", 6, 128005, "iBootSystemContainer"),
            1: (wd.APFS, "macos", 128006, 59968629, "Container"),
            6: (wd.RECOVERY, "sfr", 59968630, 61279338, "RecoveryOSContainer")}.items():
        e = bytearray(wd.ENTRY)
        e[0:16] = uuid.UUID(ptype).bytes_le
        e[16:32] = guid(name)
        struct.pack_into("<QQQ", e, 32, first, last, 0)
        enc = label.encode("utf-16-le")
        e[56:56 + len(enc)] = enc
        ents[slot * wd.ENTRY:(slot + 1) * wd.ENTRY] = e
    hdr = bytearray(SS)
    struct.pack_into("<8sIIIIQQQQ16sQIII", hdr, 0, b"EFI PART", 0x10000, 92, 0, 0, 1,
                     61279343, 6, 61279338, guid("disk"), 2, 128, wd.ENTRY,
                     zlib.crc32(ents) & 0xFFFFFFFF)
    struct.pack_into("<I", hdr, 16, zlib.crc32(hdr[:92]) & 0xFFFFFFFF)
    return bytes(hdr) + bytes(ents)


def table_bytes(arg):
    return j473_factory() if arg == "j473" else open(arg, "rb").read()


class Disk:
    """A sparse image with the J473's factory table."""

    def __init__(self, path, lba1_5):
        hdr = wd.gpt_header(lba1_5[:SS])
        if not hdr:
            fail("captured GPT header unreadable")
        self.path = path
        self.size = (hdr["alt"] + 1) * SS
        with open(path, "wb") as f:
            f.truncate(self.size)
            # The protective MBR every GPT disk (and every Mac) has at LBA 0.
            import struct
            mbr = bytearray(512)
            mbr[446:462] = struct.pack("<BBBBBBBBII", 0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF, 1,
                                       min(self.size // SS - 1, 0xFFFFFFFF))
            mbr[510:512] = b"\x55\xaa"
            f.write(mbr)
        arr = lba1_5[SS:SS + hdr["n"] * wd.ENTRY]
        ents = [bytearray(arr[i:i + wd.ENTRY]) for i in range(0, len(arr), wd.ENTRY)]
        info = [wd.entry_info(e) if e[:16] != wd.ZERO_GUID else None for e in ents]
        isc = next(i for i, x in enumerate(info) if x and x["type"] == wd.ISC)
        sfr = next(i for i, x in enumerate(info) if x and x["type"] == wd.RECOVERY)
        mac = next(i for i, x in enumerate(info) if x and x["type"] == wd.APFS
                   and x["first"] == info[isc]["last"] + 1)
        # Factory: only iSC, macOS (up to System Recovery) and System Recovery.
        for i in range(len(ents)):
            if i not in (isc, mac, sfr):
                ents[i] = bytearray(wd.ENTRY)
        import struct
        struct.pack_into("<Q", ents[mac], 40, info[sfr]["first"] - 1)
        self.macos_uuid = info[mac]["uuid"]
        io = wd.FileIO(path)
        try:
            t = {"ss": SS, "primary": dict(hdr, raw=lba1_5[:SS]), "backup": None}
            wd.gpt_store(io, t, [bytes(e) for e in ents])
        finally:
            io.close()
        self.apple = {info[isc]["uuid"]: bytes(ents[isc]), info[sfr]["uuid"]: bytes(ents[sfr])}
        # Marks in Apple's containers and in macOS, to see what gets touched.
        for idx in (isc, sfr, mac):
            x = wd.entry_info(ents[idx])
            self.pwrite(x["first"] * SS, hashlib.sha256(x["uuid"].encode()).digest() * 32768)
            self.pwrite((x["last"] + 1) * SS - (1 << 20),
                        hashlib.sha256(x["uuid"].encode() + b"end").digest() * 32768)
        self.apple_marks = self.apple_hashes()

    def pwrite(self, off, data):
        fd = os.open(self.path, os.O_RDWR)
        try:
            os.pwrite(fd, data, off)
            os.fsync(fd)
        finally:
            os.close(fd)

    def pread(self, off, n):
        fd = os.open(self.path, os.O_RDONLY)
        try:
            return os.pread(fd, n, off)
        finally:
            os.close(fd)

    def table(self):
        io = wd.FileIO(self.path)
        try:
            t = wd.gpt_load(io, SS, self.size)
        finally:
            io.close()
        if not (t["primary"] and t["backup"]):
            fail("a GPT copy is invalid")
        if t["primary"]["array"] != t["backup"]["array"]:
            fail("GPT copies differ")
        return t

    def entries(self):
        return [(i, wd.entry_info(e)) for i, e in enumerate(self.table()["entries"])
                if e[:16] != wd.ZERO_GUID]

    def apple_hashes(self):
        out = {}
        for i, x in self.entries():
            if x["type"] in (wd.ISC, wd.RECOVERY):
                h = hashlib.sha256()
                for off in (x["first"] * SS, (x["last"] + 1) * SS - (1 << 20)):
                    h.update(self.pread(off, 1 << 20))
                out[x["uuid"]] = h.hexdigest()
        return out

    def layout(self):
        parts, containers = [], []
        for i, x in self.entries():
            ident = f"disk0s{i + 1}"
            parts.append({"identifier": ident, "uuid": x["uuid"], "type": TYPES[x["type"]],
                          "offset": x["first"] * SS, "size": (x["last"] + 1 - x["first"]) * SS})
            # What `diskutil apfs list` would say about each APFS partition.
            if x["type"] == wd.ISC:
                vols = [("iSCPreboot", "Preboot"), ("xART", "xART"), ("Hardware", "Hardware")]
            elif x["type"] == wd.RECOVERY:
                vols = [("Recovery", "Recovery")]
            elif x["type"] == wd.APFS and x["uuid"] == self.macos_uuid:
                vols = [("Macintosh HD", "System"), ("Data", "Data"), ("Preboot", "Preboot"),
                        ("Recovery", "Recovery"), ("Update", "Update"), ("VM", "VM")]
            elif x["type"] == wd.APFS:
                vols = [("Aurora", "System"), ("Aurora - Data", "Data"), ("Preboot", "Preboot"),
                        ("Recovery", "Recovery")]
            else:
                continue
            cid = str(uuid.uuid5(uuid.NAMESPACE_OID, "c" + x["uuid"])).upper()
            group = MACOS_GROUP if x["uuid"] == self.macos_uuid else str(
                uuid.uuid5(uuid.NAMESPACE_OID, "g" + x["uuid"])).upper()
            v = []
            for name, role in vols:
                vid = group if role == "Data" else str(
                    uuid.uuid5(uuid.NAMESPACE_OID, name + x["uuid"])).upper()
                v.append({"uuid": vid, "name": name, "roles": [role],
                          "group": group if role in ("System", "Data") else None})
            containers.append({"uuid": cid, "reference": f"disk{len(containers) + 1}",
                               "storeUUID": x["uuid"], "volumes": v})
        return {"disk": "disk0", "diskSize": self.size, "partitions": parts,
                "containers": containers}

    def edit(self, fn):
        t = self.table()
        ents = fn([bytes(e) for e in t["entries"]], t)
        io = wd.FileIO(self.path)
        try:
            wd.gpt_store(io, t, ents)
        finally:
            io.close()


def tool(binary, workdir, reviewed, layout):
    req = os.path.join(workdir, "request.json")
    cur = os.path.join(workdir, "current.json")
    with open(req, "w") as f:
        json.dump(REQUEST, f)
    with open(cur, "w") as f:
        json.dump(layout, f)
    rev = "-"
    if reviewed is not None:
        rev = os.path.join(workdir, "reviewed.json")
        with open(rev, "w") as f:
            json.dump(reviewed, f)
    p = subprocess.run([binary, "step", req, rev, cur], capture_output=True, text=True)
    if p.returncode not in (0, 2):
        fail(f"tool exited {p.returncode}: {p.stderr}")
    return json.loads(p.stdout), p.returncode


def payload(name, size):
    """A deterministic stand-in for boot.img / root.img, with its pin."""
    block = hashlib.sha256(name.encode()).digest() * (1 << 15)  # 1 MiB
    data = block * (size // len(block))
    return data, hashlib.sha256(data).hexdigest()


def perform(disk, step, counter):
    """What diskutil (and the installer's writes) do for one step."""
    if step["step"] == "removeMacOS":
        target = step["macOSPartitionUUID"]

        def drop(ents, t):
            i = wd._slot(ents, target)
            return ents[:i] + [bytes(wd.ENTRY)] + ents[i + 1:]
        disk.edit(drop)
        return
    args = step["arguments"]
    assert args[0] == "addPartition", args
    pred, kind, size = args[1], args[2], int(args[-1])
    slot = int(pred.rsplit("s", 1)[1]) - 1
    entries = disk.table()["entries"]
    start = (wd.entry_info(entries[slot])["last"] + 1) * SS
    counter[0] += 1
    uid = str(uuid.uuid5(uuid.NAMESPACE_OID, f"new-{counter[0]}")).upper()
    name = args[3] if kind == "apfs" else ""
    t = disk.table()
    disk.edit(lambda ents, _: wd.gpt_apply(
        ents, SS, [("add", start, size, ADD_TYPES[kind], name, uid)],
        t["primary"]["first"], t["primary"]["last"]))
    role = step["role"]
    if role == "stub":
        disk.pwrite(start, b"APFS stub stand-in".ljust(SS, b"\0"))
    elif role == "esp":
        fat = disk.path + ".esp"
        with open(fat, "wb") as f:
            f.truncate(size)
        subprocess.run(["mkfs.vfat", "-F", "32", "-n", "EFI - AUROR", "-i", "4f4d5801", fat],
                       check=True, capture_output=True)
        with open(fat, "rb") as f:
            disk.pwrite(start, f.read())
        os.unlink(fat)
    else:
        image, pin = payload(role + ".img", 64 << 20)
        if hashlib.sha256(image).hexdigest() != pin or len(image) > size:
            fail("pin check")
        disk.pwrite(start, image)
        if hashlib.sha256(disk.pread(start, len(image))).hexdigest() != pin:
            fail(f"{role}.img read back differs")


def run(binary, disk, workdir, reviewed, stop_after=None, counter=None):
    counter = counter if counter is not None else [0]
    steps = []
    while True:
        out, rc = tool(binary, workdir, reviewed, disk.layout())
        if rc:
            fail(f"refused mid-run: {out}")
        steps.append(out["step"] if out["step"] != "create" else "create-" + out["role"])
        if out["step"] == "laidOut":
            return steps, out
        if stop_after is not None and len(steps) > stop_after:
            return steps, None
        perform(disk, out, counter)
        if len(steps) > 8:
            fail("does not terminate")


def final_checks(disk, out, label):
    ents = disk.entries()
    types = [TYPES[x["type"]] for _, x in sorted(ents, key=lambda e: e[1]["first"])]
    want = ["Apple_APFS_ISC", "Apple_APFS", "EFI", "Linux Filesystem", "Linux Filesystem",
            "Apple_APFS_Recovery"]
    if types != want:
        fail(f"{label}: layout {types}")
    ordered = [x for _, x in sorted(ents, key=lambda e: e[1]["first"])]
    for a, b in zip(ordered, ordered[1:]):
        if a["last"] + 1 != b["first"]:
            fail(f"{label}: gap or overlap at LBA {a['last']}")
    raw = disk.table()["entries"]
    for i, x in ents:
        if x["uuid"] in disk.apple and bytes(raw[i]) != disk.apple[x["uuid"]]:
            fail(f"{label}: Apple entry {x['uuid']} changed")
    if disk.apple_hashes() != disk.apple_marks:
        fail(f"{label}: data in iSC or System Recovery changed")
    for role in ("boot", "root"):
        image, pin = payload(role + ".img", 64 << 20)
        uid = out["verified"][role]
        x = next(x for _, x in ents if x["uuid"] == uid)
        if hashlib.sha256(disk.pread(x["first"] * SS, len(image))).hexdigest() != pin:
            fail(f"{label}: {role} contents")
    v = subprocess.run(["sfdisk", "--verify", "--sector-size", str(SS), disk.path],
                       capture_output=True, text=True)
    if v.returncode or "No errors detected" not in v.stdout:
        fail(f"{label}: sfdisk --verify: {v.stdout}{v.stderr}")
    j = json.loads(subprocess.run(["sfdisk", "--json", "--sector-size", str(SS), disk.path],
                                  check=True, capture_output=True, text=True).stdout)
    if len(j["partitiontable"]["partitions"]) != 6:
        fail(f"{label}: sfdisk sees {len(j['partitiontable']['partitions'])} partitions")
    root = ordered[4]
    return [(TYPES[x["type"]], x["first"], x["last"]) for x in ordered], root


def main():
    binary, gpt_path, workdir = sys.argv[1:4]
    os.makedirs(workdir, exist_ok=True)
    lba = table_bytes(gpt_path)
    results = []

    # One full run, with the reviewed reading kept.
    disk = Disk(os.path.join(workdir, "fresh.img"), lba)
    reviewed = disk.layout()
    first, _ = tool(binary, workdir, reviewed, reviewed)
    print(first["describe"])
    steps, out = run(binary, disk, workdir, reviewed)
    want = ["removeMacOS", "create-stub", "create-esp", "create-boot", "create-root", "laidOut"]
    if steps != want:
        fail(f"steps {steps}")
    golden, root = final_checks(disk, out, "full run")
    if (root["last"] + 1) != next(x["first"] for _, x in disk.entries()
                                  if x["type"] == wd.RECOVERY):
        fail("root doesn't end at System Recovery")
    results.append(f"full run: {' -> '.join(steps)}")
    for t, a, b in golden:
        results.append(f"  {t:22} LBA {a:>9} .. {b:>9}  ({(b - a + 1) * SS / 1e9:.2f} GB)")
    record = out["record"]
    if record["layout"] != "fresh-whole-disk" or record["removedPartitionUUID"] != disk.macos_uuid:
        fail(f"record {record}")
    os.unlink(disk.path)

    # Stop after every step, then resume with and without the journal.
    for k in range(len(want) - 1):
        for journal in (True, False):
            disk = Disk(os.path.join(workdir, f"stop{k}.img"), lba)
            reviewed = disk.layout()
            counter = [0]
            run(binary, disk, workdir, reviewed, stop_after=k, counter=counter)
            before = disk.layout()
            if not journal and k == 0:
                # Stopped before macOS went: without a journal this is a new review.
                resumed, out = run(binary, disk, workdir, before, counter=counter)
            else:
                resumed, out = run(binary, disk, workdir, reviewed if journal else None,
                                   counter=counter)
            got, _ = final_checks(disk, out, f"stop after {k}, journal={journal}")
            if got != golden:
                fail(f"stop after {k}, journal={journal}: layout differs {got}")
            results.append(f"stopped before {want[k]}, resumed "
                           f"{'with' if journal else 'without'} journal: OK ({' -> '.join(resumed)})")
            os.unlink(disk.path)

    # Refusals leave the image as it was.
    disk = Disk(os.path.join(workdir, "refuse.img"), lba)
    reviewed = disk.layout()
    t = disk.table()
    mac = next(x for _, x in disk.entries() if x["uuid"] == disk.macos_uuid)

    def shrink(ents, t):
        i = wd._slot(ents, disk.macos_uuid)
        e = bytearray(ents[i])
        import struct
        struct.pack_into("<Q", e, 40, mac["last"] - (1 << 30) // SS)
        return ents[:i] + [bytes(e)] + ents[i + 1:]
    disk.edit(shrink)
    snapshot = disk.pread(0, 6 * SS)
    out, rc = tool(binary, workdir, reviewed, disk.layout())
    if rc != 2 or "changed since it was reviewed" not in out.get("refused", ""):
        fail(f"changed-after-review not refused: {out}")
    results.append("macOS resized after review: refused (" + out["refused"][:60] + "...)")
    end = mac["last"] - (1 << 30) // SS + 1
    disk.edit(lambda ents, _: wd.gpt_apply(
        ents, SS, [("add", end * SS, 1 << 30, wd.LINUX, "", str(uuid.uuid4()))],
        t["primary"]["first"], t["primary"]["last"]))
    snapshot = disk.pread(0, 6 * SS)
    out, rc = tool(binary, workdir, None, disk.layout())
    if rc != 2 or "more than macOS" not in out.get("refused", ""):
        fail(f"extra partition not refused: {out}")
    if disk.pread(0, 6 * SS) != snapshot:
        fail("refusal changed the image")
    results.append("Linux partition beside macOS: refused, image unchanged")
    os.unlink(disk.path)

    print("\n".join(results))
    print(f"fresh-image-test: PASS ({len(results)} lines)")


if __name__ == "__main__":
    main()
