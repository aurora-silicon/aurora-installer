# SPDX-License-Identifier: MIT
"""asahi_firmware/apfs_ro.py: what a malformed container can make it do.

The reader runs as root at every boot on whatever APFS containers the disk
holds, so a damaged one must cost a bounded amount of time and
memory and end in ApfsError, the error its callers skip a device on.

Synthetic images only, a few blocks each, built here from the layout in
Apple's public "Apple File System Reference". Every case runs the reader in
a child process with a capped address space and a time limit.
"""
import hashlib
import json
import pathlib
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOL = ROOT

BS = 4096
MIB = 1 << 20
AS_LIMIT = 512 * MIB
TIME_LIMIT = 30
DECMPFS = 0x636D7066
SYSTEM_VERSION = "/System/Library/CoreServices/SystemVersion.plist"
PLIST = plistlib.dumps({"ProductBuildVersion": "99Z999", "ProductVersion": "99.0"})

# The child: open the container, take its System volume, then read one file,
# list one directory, copy a tree (copy_tree) or walk one (walk). One JSON
# line: how it ended, block reads, peak RSS. The last argument is JSON:
# walk's keyword arguments, copy's destination, or the byte offset at which
# the device fails with EIO.
CHILD = r"""
import errno, hashlib, json, os, resource, sys
sys.path.insert(0, sys.argv[1])
from asahi_firmware import apfs_ro
reads = [0]
plain_read = apfs_ro.Device.read
def read(self, paddr, n=1):
    reads[0] += 1
    return plain_read(self, paddr, n)
apfs_ro.Device.read = read
op, path, kw = sys.argv[3], sys.argv[4], json.loads(sys.argv[5])
dev = sys.argv[2]
eio = kw.pop("eio_at", None)
if eio is not None:
    class Failing:
        fd = os.open(dev, os.O_RDONLY)
        @classmethod
        def pread(cls, n, off):
            if off <= eio < off + n:
                raise OSError(errno.EIO, os.strerror(errno.EIO))
            return os.pread(cls.fd, n, off)
    dev = Failing
res = {}
try:
    vol = apfs_ro.Container(dev).volume(role=apfs_ro.ROLE_SYSTEM)
    if op == "read":
        data = vol.read_file(vol.resolve(path)[0])
        res.update(end="ok", size=len(data), sha256=hashlib.sha256(data).hexdigest())
    elif op == "ls":
        res.update(end="ok", names=sorted(vol.children(vol.resolve(path)[0])))
    elif op == "walk":
        res.update(end="ok", entries=[[rel, kind, None if data is None else hashlib.sha256(data).hexdigest()]
                                      for rel, ino, kind, data in apfs_ro.walk(vol, path, **kw)])
    else:
        dest = kw.pop("dest")
        try:
            res.update(end="ok", count=apfs_ro.copy_tree(vol, path, dest, **kw))
        finally:
            res["copied"] = sorted(os.path.relpath(os.path.join(d, n), dest) for d, ds, fs in os.walk(dest)
                                   for n in ds + fs)
except apfs_ro.ApfsError as e:
    res.update(end="ApfsError", message=str(e))
except BaseException as e:
    res.update(end=type(e).__name__, message=str(e)[:200])
res.update(reads=reads[0], rss_mib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // 1024)
print(json.dumps(res))
"""


def _limit_memory():
    import resource
    try:
        resource.setrlimit(resource.RLIMIT_AS, (AS_LIMIT, AS_LIMIT))
    except (ValueError, OSError):
        pass  # a host without an address-space limit: the time limit still holds


def fletcher64(block):
    s1 = s2 = 0
    for (w,) in struct.iter_unpack("<I", block[8:]):
        s1 = (s1 + w) % 0xFFFFFFFF
        s2 = (s2 + s1) % 0xFFFFFFFF
    c1 = 0xFFFFFFFF - ((s1 + s2) % 0xFFFFFFFF)
    c2 = 0xFFFFFFFF - ((s1 + c1) % 0xFFFFFFFF)
    return (c2 << 32) | c1


def seal(b):
    b = bytearray(b.ljust(BS, b"\0"))
    assert len(b) == BS
    struct.pack_into("<Q", b, 0, 0)
    struct.pack_into("<Q", b, 0, fletcher64(bytes(b)))
    return bytes(b)


def node(flags, level, kvs, fixed=False, info_flags=0):
    """A b-tree node of [(key, value)]. flags: 1 root, 2 leaf."""
    root = flags & 1
    b = bytearray(BS)
    if fixed:
        flags |= 4
    toc_len = (4 if fixed else 8) * len(kvs)
    struct.pack_into("<HHI", b, 32, flags, level, len(kvs))
    struct.pack_into("<HH", b, 40, 0, toc_len)
    kstart = 56 + toc_len
    vend = BS - (40 if root else 0)
    ko = vo = 0
    for i, (k, v) in enumerate(kvs):
        vo += len(v)
        b[kstart + ko:kstart + ko + len(k)] = k
        b[vend - vo:vend - vo + len(v)] = v
        if fixed:
            struct.pack_into("<HH", b, 56 + 4 * i, ko, vo)
        else:
            struct.pack_into("<HHHH", b, 56 + 8 * i, ko, len(k), vo, len(v))
        ko += len(k)
        assert kstart + ko <= vend - vo, "node full"
    if root:
        struct.pack_into("<I", b, BS - 40, info_flags)
    return seal(bytes(b))


def omap_obj(tree):
    b = bytearray(BS)
    struct.pack_into("<Q", b, 48, tree)
    return seal(bytes(b))


def omap_tree(entries):
    return node(3, 0, [(struct.pack("<QQ", o, x), struct.pack("<IIQ", 0, BS, p))
                       for o, x, p in sorted(entries)], fixed=True)


def jk(oid, typ):
    return struct.pack("<Q", oid | (typ << 60))


def drec(parent, name, ino, kind):
    n = name.encode() + b"\0"
    return jk(parent, 9) + struct.pack("<H", len(n)) + n, struct.pack("<QQH", ino, 0, kind)


def inode(ino, mode=0o100644, size=None, bsd_flags=0):
    v = bytearray(92)
    struct.pack_into("<Q", v, 8, ino)
    struct.pack_into("<I", v, 68, bsd_flags)
    struct.pack_into("<H", v, 80, mode)
    if size is not None:
        v += struct.pack("<HH", 1, 40) + struct.pack("<BBH", 8, 0, 40) + struct.pack("<QQQQQ", size, size, 0, 0, 0)
    return jk(ino, 3), bytes(v)


def xattr(ino, name, flags, data):
    n = name.encode() + b"\0"
    return jk(ino, 4) + struct.pack("<H", len(n)) + n, struct.pack("<HH", flags, len(data)) + data


def extent(oid, logical, length, pblock):
    return jk(oid, 8) + struct.pack("<Q", logical), struct.pack("<QQQ", length, pblock, 0)


def decmpfs(ctype, usize, body=b""):
    return struct.pack("<IIQ", DECMPFS, ctype, usize) + body


class Image:
    """Blocks: 0 container superblock, 1 its object map, 2 that map's tree,
    3 volume superblock, 4 its object map, 5 that map's tree, 6 the fs
    tree's root; whatever a case adds follows."""
    ROOT_OID = 0x404
    FILE = 19   # SystemVersion.plist's inode
    RSRC = 77   # the data stream of its resource fork

    def __init__(self):
        self.blocks = {}
        self.xid = 10
        self.block_size = BS
        self.desc_blocks = self.desc_base = 0
        self.fext = 0
        self.next = 7
        self.root_node = None
        self.vol_omap = None  # the volume object map's tree root (block 5)
        self.records = [drec(2, "System", 16, 4), drec(16, "Library", 17, 4),
                        drec(17, "CoreServices", 18, 4),
                        drec(18, "SystemVersion.plist", self.FILE, 8)]

    def add(self, block):
        p = self.next
        self.blocks[p] = block
        self.next += 1
        return p

    def add_data(self, data):
        first = self.next
        for i in range(0, len(data), BS):
            self.add(data[i:i + BS].ljust(BS, b"\0"))
        return first

    def plain_file(self, data=PLIST):
        p = self.add_data(data)
        self.records += [inode(self.FILE, size=len(data)),
                         extent(self.FILE, 0, (len(data) + BS - 1) // BS * BS, p)]
        return p

    def compressed_file(self, header, rsrc=None, rsrc_size=None):
        """decmpfs header in the attribute; the resource fork in a stream."""
        self.records += [inode(self.FILE, bsd_flags=0x20),
                         xattr(self.FILE, "com.apple.decmpfs", 2, header)]
        if rsrc is not None:
            p = self.add_data(rsrc)
            size = len(rsrc) if rsrc_size is None else rsrc_size
            self.records += [xattr(self.FILE, "com.apple.ResourceFork", 1, struct.pack("<QQ", self.RSRC, size)),
                             extent(self.RSRC, 0, (len(rsrc) + BS - 1) // BS * BS, p)]

    def superblock(self, xid):
        nx = bytearray(BS)
        nx[32:36] = b"NXSB"
        struct.pack_into("<Q", nx, 16, xid)
        struct.pack_into("<I", nx, 36, self.block_size)
        struct.pack_into("<Q", nx, 40, max(self.blocks, default=6) + 1)
        struct.pack_into("<I", nx, 104, self.desc_blocks)
        struct.pack_into("<Q", nx, 112, self.desc_base)
        struct.pack_into("<Q", nx, 160, 1)
        struct.pack_into("<I", nx, 180, 1)
        struct.pack_into("<Q", nx, 184, 0x402)
        return seal(bytes(nx))

    def build(self):
        self.blocks[1] = omap_obj(2)
        self.blocks[2] = omap_tree([(0x402, self.xid, 3)])
        sb = bytearray(BS)
        sb[32:36] = b"APSB"
        struct.pack_into("<Q", sb, 16, self.xid)
        struct.pack_into("<QQ", sb, 128, 4, self.ROOT_OID)
        struct.pack_into("<Q", sb, 264, 1)       # APFS_FS_UNENCRYPTED
        sb[704:708] = b"Test"
        struct.pack_into("<H", sb, 964, 1)       # role System
        struct.pack_into("<Q", sb, 1032, self.fext)
        self.blocks[3] = seal(bytes(sb))
        self.blocks[4] = omap_obj(5)
        self.blocks[5] = self.vol_omap or omap_tree([(self.ROOT_OID, self.xid, 6)])
        self.blocks[6] = self.root_node or node(3, 0, sorted(self.records, key=lambda r: struct.unpack_from(
            "<Q", r[0])[0] & 0x0FFFFFFFFFFFFFFF))
        self.blocks[0] = self.superblock(self.xid)
        out = bytearray(BS * (max(self.blocks) + 1))
        for p, b in self.blocks.items():
            out[p * BS:(p + 1) * BS] = b
        return bytes(out)


def zeros_deflated(size):
    """A zlib stream that inflates to `size` zero bytes, made in pieces."""
    c = zlib.compressobj(9)
    piece = bytes(MIB)
    out = b"".join(c.compress(piece) for _ in range(size // MIB))
    return out + c.flush()


def lzvn_literals(data):
    """An LZVN stream of literal runs only."""
    out = bytearray()
    for i in range(0, len(data), 200):
        run = data[i:i + 200]
        out += bytes([0xE0, len(run) - 16]) if len(run) >= 16 else bytes([0xE0 | len(run)])
        out += run
    return bytes(out) + b"\x06"


def pattern(n):
    return bytes((i * 7 + (i >> 8)) & 0xFF for i in range(n))


class ReaderCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_reader(self, image, op="read", path=SYSTEM_VERSION, **kw):
        if isinstance(image, Image):
            image = image.build()
        img = pathlib.Path(self.tmp.name) / f"{self.id().rsplit('.', 1)[-1]}.img"
        img.write_bytes(image)
        try:
            p = subprocess.run([sys.executable, "-I", "-c", CHILD, str(TOOL), str(img), op, path, json.dumps(kw)],
                               capture_output=True, text=True, timeout=TIME_LIMIT, preexec_fn=_limit_memory)
        except subprocess.TimeoutExpired:
            return {"end": f"still running after {TIME_LIMIT} s"}
        if not p.stdout.strip():
            return {"end": f"exit {p.returncode}", "message": p.stderr[-300:]}
        return json.loads(p.stdout)

    def refused(self, image, **kw):
        """The reader gave up on the container with ApfsError."""
        res = self.run_reader(image, **kw)
        self.assertEqual(res["end"], "ApfsError", res)
        return res

    def copied(self, image, path, **kw):
        """copy_tree of path into a fresh directory."""
        dest = tempfile.mkdtemp(dir=self.tmp.name)
        return self.run_reader(image, op="copy", path=path, dest=f"{dest}/out", **kw)

    def reads_back(self, image, data):
        res = self.run_reader(image)
        self.assertEqual((res["end"], res.get("size"), res.get("sha256")),
                         ("ok", len(data), hashlib.sha256(data).hexdigest()), res)
        return res


class Malformed(ReaderCase):
    """Each of these ended in another exception, ran for hours or took
    hundreds of MiB before the reader was bounded."""

    def test_block_size(self):
        for bs in (0, 1, 512, 4097, 12288, 1 << 17, 1 << 31):
            with self.subTest(block_size=bs):
                im = Image()
                im.plain_file()
                im.block_size = bs
                self.assertIn("block size", self.refused(im)["message"])

    def test_checkpoint_descriptor_count(self):
        # 2^31 - 1 blocks to probe, none of them in the image.
        im = Image()
        im.plain_file()
        im.desc_blocks, im.desc_base = 0x7FFFFFFF, 0x100000
        self.assertLess(self.refused(im)["reads"], 64)

    def test_checkpoint_descriptor_area_outside_container(self):
        im = Image()
        im.plain_file()
        im.desc_blocks, im.desc_base = 4096, 7
        self.assertLess(self.refused(im)["reads"], 64)

    def fanout(self, k, levels):
        """An fs tree of `levels` index levels over one leaf; every index
        node holds the same key k times, each naming the next level."""
        im = Image()
        key = jk(2, 9)
        first = im.next
        for level in range(levels - 1, 0, -1):
            im.add(node(0, level, [(key, struct.pack("<Q", im.next + 1))] * k))
        im.add(node(2, 0, [drec(2, "x", 99, 8)]))
        im.root_node = node(1, levels, [(key, struct.pack("<Q", first))] * k, info_flags=0x10)
        return im

    def test_fs_tree_equal_key_fanout(self):
        # 8^16 leaf visits for the first lookup.
        res = self.refused(self.fanout(8, 16))
        self.assertLess(res["reads"], 10000)

    def test_fs_tree_child_level(self):
        # An index root of level 2 whose child is a leaf: not a b-tree.
        im = Image()
        im.plain_file()
        leaf = im.add(node(2, 0, sorted(im.records, key=lambda r: struct.unpack_from("<Q", r[0])[0]
                                        & 0x0FFFFFFFFFFFFFFF)))
        im.root_node = node(1, 2, [(jk(2, 3), struct.pack("<Q", leaf))], info_flags=0x10)
        self.assertIn("level", self.refused(im)["message"])

    def sealed(self, fext_nodes):
        """A plain file whose extents are in a file-extent tree."""
        im = Image()
        im.records.append(inode(im.FILE, size=len(PLIST)))
        im.add_data(PLIST)
        im.fext = im.next
        for n in fext_nodes(im.fext):
            im.add(n)
        return im

    def test_extent_tree_names_itself(self):
        key = struct.pack("<QQ", Image.FILE, 0)
        im = self.sealed(lambda at: [node(0, 1, [(key, struct.pack("<Q", at))], fixed=True)])
        self.assertLess(self.refused(im)["reads"], 64)

    def test_extent_tree_equal_key_fanout(self):
        key = struct.pack("<QQ", Image.FILE, 0)

        def nodes(at):
            out = [node(0, level, [(key, struct.pack("<Q", at + 16 - level))] * 8, fixed=True)
                   for level in range(15, 0, -1)]
            return out + [node(2, 0, [(key, struct.pack("<QQ", BS, 7))], fixed=True)]

        res = self.refused(self.sealed(nodes))
        self.assertLess(res["reads"], 10000)

    def test_inode_extended_field_count(self):
        im = Image()
        k, v = inode(im.FILE, size=10)
        v = bytearray(v)
        struct.pack_into("<H", v, 92, 0xFFFF)
        im.records.append((k, bytes(v)))
        self.refused(im)

    def test_overlapping_extents(self):
        im = Image()
        p = im.plain_file()
        im.records += [extent(im.FILE, 0, BS, p)] * 8
        self.assertIn("overlapping", self.refused(im)["message"])

    def test_decmpfs_inline_zlib_broken(self):
        im = Image()
        im.compressed_file(decmpfs(3, 100, b"\x78garbage"))
        self.refused(im)

    def test_decmpfs_inline_zlib_truncated(self):
        im = Image()
        im.compressed_file(decmpfs(3, len(PLIST), zlib.compress(PLIST)[:-6]))
        self.refused(im)

    def test_decmpfs_inline_zlib_inflates_past_its_size(self):
        # 600 MiB behind a header that declares 100 bytes; the header and
        # the stream sit in the attribute's own data stream.
        im = Image()
        hdr = decmpfs(3, 100, zeros_deflated(600 * MIB))
        p = im.add_data(hdr)
        im.records += [inode(im.FILE, bsd_flags=0x20),
                       xattr(im.FILE, "com.apple.decmpfs", 1, struct.pack("<QQ", im.RSRC, len(hdr))),
                       extent(im.RSRC, 0, (len(hdr) + BS - 1) // BS * BS, p)]
        self.assertLess(self.refused(im)["rss_mib"], 128)

    def chunk_table(self, blob, count):
        """A type 4 resource fork whose `count` entries all name `blob`."""
        table = struct.pack("<II", 4 + 8 * count, len(blob)) * count
        return struct.pack(">I", 0) + struct.pack("<I", count) + table + blob

    def test_decmpfs_chunk_inflates_past_file_size(self):
        im = Image()
        im.compressed_file(decmpfs(4, 4096), self.chunk_table(zeros_deflated(600 * MIB), 1))
        self.assertLess(self.refused(im)["rss_mib"], 128)

    def test_decmpfs_chunk_count(self):
        # 24 entries, each 32 MiB inflated, for a file of 4096 bytes.
        im = Image()
        im.compressed_file(decmpfs(4, 4096), self.chunk_table(zeros_deflated(32 * MIB), 24))
        self.assertLess(self.refused(im)["rss_mib"], 128)

    def test_decmpfs_offset_table_size(self):
        # A sparse 128 MiB resource fork whose first word says it is all
        # offset table: 32 million entries for a file of 4096 bytes.
        size = 128 * MIB
        im = Image()
        im.compressed_file(decmpfs(8, 4096), struct.pack("<I", size - 4), rsrc_size=size)
        self.assertLess(self.refused(im)["rss_mib"], 336)

    # ------------------------------------------------ review of the bounds

    def test_sparse_file_held_once(self):
        # An inode of 256 MiB with no extents reads back as zeros, within
        # the child's 512 MiB address space.
        im = Image()
        im.records.append(inode(im.FILE, size=256 * MIB))
        self.reads_back(im, bytes(256 * MIB))

    def test_device_read_error(self):
        im = Image()
        p = im.plain_file()
        res = self.refused(im, eio_at=p * BS)
        self.assertIn("errno 5", res["message"])

    def rsrc4(self, chunks, spans=None):
        """A type 4 resource fork of chunks; spans [(offset, length)]
        replace the table the chunks give."""
        if spans is None:
            spans, off = [], 4 + 8 * len(chunks)
            for c in chunks:
                spans.append((off, len(c)))
                off += len(c)
        table = b"".join(struct.pack("<II", o, n) for o, n in spans)
        return struct.pack(">I", 0) + struct.pack("<I", len(spans)) + table + b"".join(chunks)

    def test_decmpfs_chunk_spans(self):
        data = pattern(0x10000)
        z = zlib.compress(data)
        start = 4 + 16
        cases = {
            # Both entries name the same chunk.
            "overlapping": (2 * len(data), [z], [(start, len(z)), (start, len(z))]),
            # A stored chunk over 64 KiB and the reader's 4 KiB headroom.
            "over": (len(data), [b"\xff" + data + bytes(0x1000)], None),
            # A chunk that runs past the end of the fork.
            "outside": (len(data), [b"\xff" + data], [(start, len(data) + 1 + 4096)]),
        }
        for want, (usize, chunks, spans) in cases.items():
            with self.subTest(want):
                im = Image()
                im.compressed_file(decmpfs(4, usize), self.rsrc4(chunks, spans if spans else None))
                self.assertIn(want, self.refused(im)["message"])

    def test_decmpfs_chunk_inflates_past_chunk_size(self):
        # One zlib chunk of 128 KiB for a file of 128 KiB: a chunk is 64 KiB.
        data = pattern(0x20000)
        im = Image()
        im.compressed_file(decmpfs(4, len(data)), self.rsrc4([zlib.compress(data)]))
        self.assertIn("zlib", self.refused(im)["message"])

    def rsrc8(self, chunks, offs=None):
        if offs is None:
            offs, off = [], 4 * (len(chunks) + 1)
            for c in chunks:
                offs.append(off)
                off += len(c)
            offs.append(off)
        return b"".join(struct.pack("<I", o) for o in offs) + b"".join(chunks)

    def test_decmpfs_chunk_offsets(self):
        data = pattern(0x10000)
        a, b = b"\x06" + data[:0x8000], b"\x06" + data[0x8000:]
        cases = {
            "decreasing": (len(data), [a, b], [12, 12 + len(a), 12]),
            "past the fork": (len(data), [a, b], [12, 12 + len(a), 12 + len(a) + len(b) + 4096]),
            "over 68 KiB": (len(data), [b"\x06" + data + bytes(0x1000)], None),
        }
        for name, (usize, chunks, offs) in cases.items():
            with self.subTest(name):
                im = Image()
                im.compressed_file(decmpfs(8, usize), self.rsrc8(chunks, offs))
                self.assertIn("chunk offsets", self.refused(im)["message"])

    def test_lzvn_nop_flood(self):
        # No-op opcodes, then one literal byte.
        flood = b"\x0e" * (4 * MIB) + b"\xe1A\x06"
        with self.subTest("attribute stream (type 7)"):
            im = Image()
            hdr = decmpfs(7, 1, flood)
            p = im.add_data(hdr)
            im.records += [inode(im.FILE, bsd_flags=0x20),
                           xattr(im.FILE, "com.apple.decmpfs", 1, struct.pack("<QQ", im.RSRC, len(hdr))),
                           extent(im.RSRC, 0, (len(hdr) + BS - 1) // BS * BS, p)]
            self.assertIn("no-op", self.refused(im)["message"])
        with self.subTest("resource fork chunk (type 8)"):
            im = Image()
            im.compressed_file(decmpfs(8, 1), self.rsrc8([b"\x16" * 0x8000 + b"\xe1A\x06"]))
            self.assertIn("no-op", self.refused(im)["message"])

    def virtual_fanout(self, k, levels, omap_levels):
        """fanout() with virtual children, each behind an object-map path of
        omap_levels nodes."""
        im = Image()
        key = jk(2, 9)
        oid = [0x500 + level for level in range(levels)]
        at = {}
        for level in range(levels - 1, 0, -1):
            at[oid[level]] = im.add(node(0, level, [(key, struct.pack("<Q", oid[level - 1]))] * k))
        at[oid[0]] = im.add(node(2, 0, [drec(2, "x", 99, 8)]))
        im.root_node = node(1, levels, [(key, struct.pack("<Q", oid[levels - 1]))] * k)
        entries = sorted([(Image.ROOT_OID, im.xid, 6)] + [(o, im.xid, p) for o, p in at.items()])
        okey = struct.pack("<QQ", 0, 0)
        child = im.add(node(2, 0, [(struct.pack("<QQ", o, x), struct.pack("<IIQ", 0, BS, p))
                                   for o, x, p in entries], fixed=True))
        for level in range(1, omap_levels - 1):
            child = im.add(node(0, level, [(okey, struct.pack("<Q", child))], fixed=True))
        im.vol_omap = node(1, omap_levels - 1, [(okey, struct.pack("<Q", child))], fixed=True)
        return im

    def test_object_map_reads_in_lookup_budget(self):
        res = self.refused(self.virtual_fanout(8, 16, 16), op="ls", path="/")
        self.assertLess(res["reads"], 10000)

    def test_object_map_child_level(self):
        # An object-map root of level 2 whose child is its leaf.
        im = Image()
        im.plain_file()
        leaf = im.add(node(2, 0, [(struct.pack("<QQ", Image.ROOT_OID, im.xid), struct.pack("<IIQ", 0, BS, 6))],
                           fixed=True))
        im.vol_omap = node(1, 2, [(struct.pack("<QQ", 0, 0), struct.pack("<Q", leaf))], fixed=True)
        self.assertIn("object map", self.refused(im)["message"])

    # ---------------------------------------------- directory walks

    def tree(self, recs):
        """An image whose /fw (inode 30) holds recs."""
        im = Image()
        im.plain_file()
        im.records += [drec(2, "fw", 30, 4)] + recs
        return im

    def test_directory_lists_itself(self):
        res = self.copied(self.tree([drec(30, "self", 30, 4)]), "/fw")
        self.assertEqual(res["end"], "ApfsError", res)
        self.assertIn("twice", res["message"])
        self.assertEqual(res["copied"], [])
        self.assertLess(res["reads"], 200)

    def test_directory_dag(self):
        # Each level names the next directory twice: 2^20 paths, 21 inodes.
        recs = []
        for i in range(20):
            recs += [drec(30 + i, "a", 31 + i, 4), drec(30 + i, "b", 31 + i, 4)]
        for op in ("walk", "copy"):
            with self.subTest(op):
                im = self.tree(recs)
                res = self.run_reader(im, op="walk", path="/fw") if op == "walk" else self.copied(im, "/fw")
                self.assertEqual(res["end"], "ApfsError", res)
                self.assertIn("twice", res["message"])
                self.assertLess(res["reads"], 1000)

    def test_directory_depth(self):
        recs = [drec(30 + i, "d", 31 + i, 4) for i in range(80)]
        for op in ("walk", "copy"):
            with self.subTest(op):
                im = self.tree(recs)
                res = self.run_reader(im, op="walk", path="/fw") if op == "walk" else self.copied(im, "/fw")
                self.assertEqual(res["end"], "ApfsError", res)
                self.assertIn("levels deep", res["message"])

    def test_walk_budgets(self):
        # 20 names for one file.
        recs = [drec(30, f"f{i:02d}", Image.FILE, 8) for i in range(20)]
        for kw, want in (({"max_entries": 10}, "entries"), ({"max_bytes": 5 * len(PLIST)}, "bytes")):
            with self.subTest(**kw):
                self.assertIn(want, self.refused(self.tree(recs), op="walk", path="/fw", **kw)["message"])
        with self.subTest("copy_tree max_bytes"):
            res = self.copied(self.tree(recs), "/fw", max_bytes=5 * len(PLIST))
            self.assertEqual(res["end"], "ApfsError", res)
            self.assertEqual(len(res["copied"]), 5)


class WellFormed(ReaderCase):
    """What the bounds must leave alone."""

    def test_plain_file(self):
        im = Image()
        im.plain_file()
        self.reads_back(im, PLIST)

    def test_newest_checkpoint(self):
        # The descriptor area holds a newer superblock: it is the one used.
        im = Image()
        im.plain_file()
        im.desc_base, im.desc_blocks = im.next, 3
        for _ in range(3):
            im.add(bytes(BS))
        im.xid = 11
        image = bytearray(im.build())
        newer = im.desc_base + 1
        image[newer * BS:(newer + 1) * BS] = image[:BS]
        # Block 0 is an older checkpoint's superblock; the object maps only
        # answer for the newer one's transaction.
        image[:BS] = im.superblock(9)
        self.reads_back(bytes(image), PLIST)

    def test_directory_over_several_leaves(self):
        im = Image()
        names = [f"file-{i:03d}" for i in range(120)]
        recs = [drec(2, n, 100 + i, 8) for i, n in enumerate(names)]
        leaves = [im.add(node(2, 0, recs[i:i + 40])) for i in range(0, 120, 40)]
        im.root_node = node(1, 1, [(jk(2, 9), struct.pack("<Q", p)) for p in leaves], info_flags=0x10)
        res = self.run_reader(im, op="ls", path="/")
        self.assertEqual((res["end"], res.get("names")), ("ok", names), res)

    def test_sealed_extent_tree(self):
        key = struct.pack("<QQ", Image.FILE, 0)
        im = Image()
        im.records.append(inode(im.FILE, size=len(PLIST)))
        data = im.add_data(PLIST)
        leaf = im.add(node(2, 0, [(key, struct.pack("<QQ", BS, data))], fixed=True))
        im.fext = im.add(node(1, 1, [(key, struct.pack("<Q", leaf))], fixed=True))
        self.reads_back(im, PLIST)

    def test_decmpfs_inline(self):
        for name, body in (("zlib", zlib.compress(PLIST)), ("stored", b"\xff" + PLIST)):
            with self.subTest(name):
                im = Image()
                im.compressed_file(decmpfs(3, len(PLIST), body))
                self.reads_back(im, PLIST)

    def test_decmpfs_zlib_chunks(self):
        data = pattern(150000)
        chunks = [zlib.compress(data[:0x10000]), b"\xff" + data[0x10000:0x20000], zlib.compress(data[0x20000:])]
        table, off = b"", 4 + 8 * len(chunks)
        for c in chunks:
            table += struct.pack("<II", off, len(c))
            off += len(c)
        im = Image()
        im.compressed_file(decmpfs(4, len(data)),
                           struct.pack(">I", 0) + struct.pack("<I", len(chunks)) + table + b"".join(chunks))
        self.reads_back(im, data)

    def test_decmpfs_lzvn_chunks(self):
        data = pattern(70000)
        chunks = [lzvn_literals(data[:0x10000]), b"\x06" + data[0x10000:]]
        offs, off = [], 4 * (len(chunks) + 1)
        for c in chunks:
            offs.append(off)
            off += len(c)
        im = Image()
        im.compressed_file(decmpfs(8, len(data)),
                           b"".join(struct.pack("<I", o) for o in offs + [off]) + b"".join(chunks))
        self.reads_back(im, data)

    def test_copy_and_walk_tree(self):
        # /fw: a file, a subdirectory with a second name for it, a link and
        # an empty directory.
        im = Image()
        im.plain_file()
        im.records += [drec(2, "fw", 30, 4), drec(30, "a.plist", Image.FILE, 8), drec(30, "sub", 31, 4),
                       drec(31, "b.plist", Image.FILE, 8), drec(30, "link", 32, 10), drec(30, "empty", 33, 4)]
        sha = hashlib.sha256(PLIST).hexdigest()
        res = self.run_reader(im, op="walk", path="/fw")
        self.assertEqual((res["end"], res.get("entries")),
                         ("ok", [["", 4, None], ["a.plist", 8, sha], ["empty", 4, None], ["link", 10, None],
                                 ["sub", 4, None], ["sub/b.plist", 8, sha]]), res)
        res = self.copied(im, "/fw")
        self.assertEqual((res["end"], res.get("count"), res["copied"]),
                         ("ok", 2, ["a.plist", "empty", "sub", "sub/b.plist"]), res)

    def test_lzvn_nop_padding(self):
        # A few no-ops between commands decode as before.
        data = pattern(300)
        stream = b"\x0e\x16" + lzvn_literals(data[:150])[:-1] + b"\x0e" * 3 + lzvn_literals(data[150:])
        im = Image()
        im.compressed_file(decmpfs(8, len(data)), struct.pack("<II", 8, 8 + len(stream)) + stream)
        self.reads_back(im, data)


if __name__ == "__main__":
    unittest.main()
