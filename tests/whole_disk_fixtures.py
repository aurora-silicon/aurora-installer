# SPDX-License-Identifier: MIT
# Copyright (c) 2026 The Aurora Silicon Contributors
"""Synthetic APFS containers for the whole-disk tests.

Builds the smallest container apfs_ro reads: a container superblock, an
object map with one leaf node, and one superblock per volume (name, role,
volume group, encryption flag). Layout from Apple's public "Apple File
System Reference"; no file-system trees, so only volume listings work.
"""
import struct
import uuid

BS = 4096
NX_MAGIC, APFS_MAGIC = b"NXSB", b"APSB"
OBJ_PHYSICAL, OBJ_VIRTUAL = 0x40000000, 0
T_NX, T_OMAP, T_BTREE, T_FS = 1, 0xB, 2, 0xD
ROLE = {"System": 1, "Recovery": 4, "VM": 8, "Preboot": 0x10, "Data": 0x40, "Update": 0xC0,
        "xART": 0x100, "Hardware": 0x140}


def fletcher64(block):
    s1 = s2 = 0
    for (w,) in struct.iter_unpack("<I", block[8:]):
        s1 = (s1 + w) % 0xFFFFFFFF
        s2 = (s2 + s1) % 0xFFFFFFFF
    c1 = 0xFFFFFFFF - ((s1 + s2) % 0xFFFFFFFF)
    c2 = 0xFFFFFFFF - ((s1 + c1) % 0xFFFFFFFF)
    return (c2 << 32) | c1


def _obj(oid, xid, otype):
    b = bytearray(BS)
    struct.pack_into("<QQII", b, 8, oid, xid, otype, 0)
    return b


def _seal(b):
    struct.pack_into("<Q", b, 0, fletcher64(bytes(b)))
    return bytes(b)


def container(volumes, xid=1):
    """volumes: [(name, role, group-uuid-or-None, encrypted)]. Returns the
    container's first blocks as bytes."""
    n = len(volumes)
    blocks = []
    nx = _obj(1, xid, OBJ_PHYSICAL | T_NX)
    nx[32:36] = NX_MAGIC
    struct.pack_into("<I", nx, 36, BS)
    struct.pack_into("<I", nx, 104, 0)          # no checkpoint descriptor area
    struct.pack_into("<Q", nx, 160, 1)          # omap at block 1
    struct.pack_into("<I", nx, 180, 100)        # max file systems
    for i in range(n):
        struct.pack_into("<Q", nx, 184 + 8 * i, 0x400 + i)
    blocks.append(_seal(nx))
    om = _obj(1, xid, OBJ_PHYSICAL | T_OMAP)
    struct.pack_into("<Q", om, 48, 2)           # tree at block 2
    blocks.append(_seal(om))
    node = _obj(2, xid, OBJ_PHYSICAL | T_BTREE)
    struct.pack_into("<HHI", node, 32, 1 | 2 | 4, 0, n)  # root, leaf, fixed
    struct.pack_into("<HH", node, 40, 0, 4 * n)
    kstart = 56 + 4 * n
    vend = BS - 40
    for i in range(n):
        struct.pack_into("<HH", node, 56 + 4 * i, 16 * i, 16 * (i + 1))
        struct.pack_into("<QQ", node, kstart + 16 * i, 0x400 + i, xid)
        struct.pack_into("<IIQ", node, vend - 16 * (i + 1), 0, BS, 3 + i)
    blocks.append(_seal(node))
    for i, (name, role, group, encrypted) in enumerate(volumes):
        sb = _obj(0x400 + i, xid, OBJ_VIRTUAL | T_FS)
        sb[32:36] = APFS_MAGIC
        struct.pack_into("<Q", sb, 264, 0 if encrypted else 1)
        sb[240:256] = uuid.uuid4().bytes
        enc = name.encode()[:255]
        sb[704:704 + len(enc)] = enc
        struct.pack_into("<H", sb, 964, ROLE[role])
        if group:
            sb[1008:1024] = uuid.UUID(group).bytes
        blocks.append(_seal(sb))
    return b"".join(blocks)


MAC_GROUP = "1c4cd44a-0c57-46f1-a834-58808bff3a68"
STUB_GROUP = "0e3f2fc4-18de-42ed-955f-2cf407eb27e2"
ISC_VOLUMES = [("iSCPreboot", "Preboot", None, False), ("xART", "xART", None, False),
               ("Hardware", "Hardware", None, False), ("Recovery", "Recovery", None, False)]
MAC_VOLUMES = [("Macintosh HD", "System", MAC_GROUP, False), ("Preboot", "Preboot", None, False),
               ("Recovery", "Recovery", None, False), ("Update", "Update", None, False),
               ("Data", "Data", MAC_GROUP, True), ("VM", "VM", None, False)]
STUB_VOLUMES = [("Aurora - Data", "Data", STUB_GROUP, True), ("Aurora", "System", STUB_GROUP, False),
                ("Preboot", "Preboot", None, False), ("Recovery", "Recovery", None, False)]
RECOVERY_VOLUMES = [("Recovery", "Recovery", None, False), ("Update", "Update", None, False)]

# Partition plan in MiB: (name, type, size) in disk order; the last takes the rest.
LAYOUT = [("isc", "69646961-6700-11AA-AA11-00306543ECAC", 512),
          ("macos", "7C3457EF-0000-11AA-AA11-00306543ECAC", 6144),
          ("stub", "7C3457EF-0000-11AA-AA11-00306543ECAC", 1024),
          ("esp", "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", 512),
          ("boot", "0FC63DAF-8483-4772-8E79-3D69D8477DE4", 1024),
          ("root", "0FC63DAF-8483-4772-8E79-3D69D8477DE4", 4096),
          ("recovery", "52637672-7900-11AA-AA11-00306543ECAC", 1024)]
CONTENTS = {"isc": ISC_VOLUMES, "macos": MAC_VOLUMES, "stub": STUB_VOLUMES,
            "recovery": RECOVERY_VOLUMES}


def sfdisk_script(sector, layout=LAYOUT, first_mib=1):
    """An sfdisk script for the layout, 1 MiB aligned, partitions in order."""
    per = (1 << 20) // sector
    lines, at = ["label: gpt"], first_mib * per
    for name, ptype, mib in layout:
        lines.append(f"start={at}, size={mib * per}, type={ptype}, name=\"{name}\"")
        at += mib * per
    return "\n".join(lines) + "\n"
