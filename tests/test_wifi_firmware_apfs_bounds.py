# SPDX-License-Identifier: MIT
"""tools/wifi-firmware/apfs_ro.py: what a malformed container can make it do.

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
TOOL = ROOT / "tools" / "wifi-firmware"

BS = 4096
MIB = 1 << 20
AS_LIMIT = 512 * MIB
TIME_LIMIT = 30
DECMPFS = 0x636D7066
SYSTEM_VERSION = "/System/Library/CoreServices/SystemVersion.plist"
PLIST = plistlib.dumps({"ProductBuildVersion": "99Z999", "ProductVersion": "99.0"})

# The child: open the container, take its System volume, then read one file
# or list one directory. One JSON line: how it ended, block reads, peak RSS.
CHILD = r"""
import hashlib, json, resource, sys
sys.path.insert(0, sys.argv[1])
import apfs_ro
reads = [0]
plain_read = apfs_ro.Device.read
def read(self, paddr, n=1):
    reads[0] += 1
    return plain_read(self, paddr, n)
apfs_ro.Device.read = read
res = {}
try:
    vol = apfs_ro.Container(sys.argv[2]).volume(role=apfs_ro.ROLE_SYSTEM)
    ino, kind = vol.resolve(sys.argv[4])
    if sys.argv[3] == "read":
        data = vol.read_file(ino)
        res.update(end="ok", size=len(data), sha256=hashlib.sha256(data).hexdigest())
    else:
        res.update(end="ok", names=sorted(vol.children(ino)))
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
        self.blocks[5] = omap_tree([(self.ROOT_OID, self.xid, 6)])
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

    def run_reader(self, image, op="read", path=SYSTEM_VERSION):
        if isinstance(image, Image):
            image = image.build()
        img = pathlib.Path(self.tmp.name) / f"{self.id().rsplit('.', 1)[-1]}.img"
        img.write_bytes(image)
        try:
            p = subprocess.run([sys.executable, "-I", "-c", CHILD, str(TOOL), str(img), op, path],
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


if __name__ == "__main__":
    unittest.main()
