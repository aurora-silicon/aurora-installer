# SPDX-License-Identifier: MIT
# Copyright (c) 2026 The Aurora Silicon Contributors
"""Random access to Apple's published images without downloading them whole.

Layers, each a seekable read-only file object over the one below:

    HTTPFile   byte ranges of a URL (Apple's CDN serves ``Accept-Ranges: bytes``)
    Slice      a byte window of another file (a member of a xar package)
    UDIFDisk   the disk inside an uncompressed or zlib UDIF image (.dmg)
    HFSFile    one file of an HFS+ volume (Apple TN1150), found by path

``zipfile.ZipFile`` then reads an archive at the top of the stack, so a few
megabytes of requests locate a member of a 17 GB installer package.
"""

from __future__ import annotations

import io
import plistlib
import struct
import time
import urllib.error
import urllib.request
import zlib
from collections import OrderedDict

USER_AGENT = "aurora-restore/1"


class RemoteError(Exception):
    pass


class _Reader(io.RawIOBase):
    """Seekable, read-only base: subclasses implement ``size`` and ``pread``."""

    size = 0

    def __init__(self):
        super().__init__()
        self._pos = 0

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self._pos

    def seek(self, offset, whence=io.SEEK_SET):
        if whence == io.SEEK_SET:
            self._pos = offset
        elif whence == io.SEEK_CUR:
            self._pos += offset
        elif whence == io.SEEK_END:
            self._pos = self.size + offset
        if self._pos < 0:
            raise ValueError("negative seek")
        return self._pos

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self._pos
        n = max(0, min(n, self.size - self._pos))
        data = self.pread(self._pos, n) if n else b""
        self._pos += len(data)
        return data

    def readinto(self, b):
        data = self.read(len(b))
        b[: len(data)] = data
        return len(data)

    def pread(self, offset, n):  # pragma: no cover - abstract
        raise NotImplementedError


class HTTPFile(_Reader):
    """A URL read with HTTP range requests through an aligned block cache."""

    def __init__(self, url, block=1 << 20, cache_blocks=64, opener=None, retries=4):
        super().__init__()
        self.url = url
        self.block = block
        self.cache = OrderedDict()
        self.cache_blocks = cache_blocks
        self.retries = retries
        self.opener = opener or urllib.request.build_opener()
        self.requests = 0
        self.bytes_fetched = 0
        req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": USER_AGENT})
        with self._open(req) as r:
            if r.headers.get("Accept-Ranges", "").lower() != "bytes":
                raise RemoteError(f"{url}: server does not offer byte ranges")
            self.size = int(r.headers["Content-Length"])
            self.etag = r.headers.get("ETag")

    def _open(self, req):
        delay = 1.0
        for attempt in range(self.retries + 1):
            try:
                return self.opener.open(req, timeout=60)
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                if attempt == self.retries:
                    raise RemoteError(f"{self.url}: {e}") from e
                time.sleep(delay)
                delay *= 2

    def _fetch(self, start, end):
        req = urllib.request.Request(
            self.url, headers={"User-Agent": USER_AGENT, "Range": f"bytes={start}-{end - 1}"}
        )
        with self._open(req) as r:
            if r.status != 206:
                raise RemoteError(f"{self.url}: expected 206, got {r.status}")
            data = r.read()
        if len(data) != end - start:
            raise RemoteError(f"{self.url}: short range {len(data)} != {end - start}")
        self.requests += 1
        self.bytes_fetched += len(data)
        return data

    def _block(self, index):
        if index in self.cache:
            self.cache.move_to_end(index)
            return self.cache[index]
        start = index * self.block
        data = self._fetch(start, min(start + self.block, self.size))
        self.cache[index] = data
        if len(self.cache) > self.cache_blocks:
            self.cache.popitem(last=False)
        return data

    def pread(self, offset, n):
        # Large reads bypass the cache in one request.
        if n >= 4 * self.block:
            return self._fetch(offset, offset + n)
        out = bytearray()
        while n > 0:
            index, inner = divmod(offset, self.block)
            chunk = self._block(index)[inner : inner + n]
            if not chunk:
                break
            out += chunk
            offset += len(chunk)
            n -= len(chunk)
        return bytes(out)


class Slice(_Reader):
    def __init__(self, base, offset, size):
        super().__init__()
        self.base, self.offset, self.size = base, offset, size

    def pread(self, offset, n):
        return self.base.pread(self.offset + offset, n)


# ---------------------------------------------------------------- xar (.pkg)


def xar_members(f):
    """Return {name: (offset, length, encoding)} for top-level files of a xar."""
    head = f.pread(0, 28)
    magic, hsize, _ver, toc_c, _toc_u, _ck = struct.unpack(">4sHHQQI", head)
    if magic != b"xar!":
        raise RemoteError("not a xar archive")
    toc = zlib.decompress(f.pread(hsize, toc_c)).decode()
    heap = hsize + toc_c
    import xml.etree.ElementTree as ET

    out = {}
    root = ET.fromstring(toc)
    for node in root.find("toc").findall("file"):
        data = node.find("data")
        if data is None:
            continue
        enc = data.find("encoding").get("style")
        out[node.findtext("name")] = (
            heap + int(data.findtext("offset")),
            int(data.findtext("length")),
            enc,
        )
    return out


def xar_open(f, name):
    off, length, enc = xar_members(f)[name]
    if enc != "application/octet-stream":
        data = f.pread(off, length)
        if enc == "application/x-gzip":
            data = zlib.decompress(data)
        return io.BytesIO(data), len(data)
    return Slice(f, off, length), length


# ---------------------------------------------------------------- UDIF (.dmg)

_RAW, _ZERO, _IGNORE, _ZLIB, _END = 0x1, 0x0, 0x2, 0x80000005, 0xFFFFFFFF


class UDIFDisk(_Reader):
    """The whole disk of a UDIF image whose chunks are raw, zero or zlib."""

    def __init__(self, f):
        super().__init__()
        self.f = f
        koly = f.pread(f.size - 512, 512)
        if koly[:4] != b"koly":
            raise RemoteError("no koly trailer: not a UDIF image")
        data_fork_off = struct.unpack(">Q", koly[0x18:0x20])[0]
        xml_off, xml_len = struct.unpack(">QQ", koly[0xD8:0xE8])
        plist = plistlib.loads(f.pread(xml_off, xml_len))
        self.partitions = []
        self.chunks = []  # (start_sector, sectors, type, file_off, file_len)
        for blk in plist["resource-fork"]["blkx"]:
            d = blk["Data"]
            if d[:4] != b"mish":
                raise RemoteError("bad blkx entry")
            first, count = struct.unpack(">QQ", d[8:24])
            base = struct.unpack(">Q", d[24:32])[0] + data_fork_off
            n = struct.unpack(">I", d[200:204])[0]
            self.partitions.append((blk.get("Name", ""), first, count))
            for i in range(n):
                e = d[204 + 40 * i : 244 + 40 * i]
                typ, _c, s, c, co, cl = struct.unpack(">IIQQQQ", e)
                if typ == _END:
                    continue
                if typ not in (_RAW, _ZERO, _IGNORE, _ZLIB):
                    raise RemoteError(f"unsupported UDIF chunk type {typ:#x}")
                self.chunks.append((first + s, c, typ, base + co, cl))
        self.chunks.sort()
        self.size = max(s + c for s, c, *_ in self.chunks) * 512
        self._zcache = OrderedDict()

    def _chunk_bytes(self, ch):
        s, c, typ, off, ln = ch
        if typ == _ZLIB:
            if ch not in self._zcache:
                self._zcache[ch] = zlib.decompress(self.f.pread(off, ln))
                if len(self._zcache) > 8:
                    self._zcache.popitem(last=False)
            return self._zcache[ch]
        return None

    def pread(self, offset, n):
        import bisect

        out = bytearray()
        keys = [ch[0] for ch in self.chunks]
        while n > 0:
            sector = offset // 512
            i = bisect.bisect_right(keys, sector) - 1
            if i < 0:
                raise RemoteError("read before first chunk")
            s, c, typ, off, ln = ch = self.chunks[i]
            cstart, cend = s * 512, (s + c) * 512
            if offset >= cend:
                raise RemoteError(f"read in a hole at {offset}")
            take = min(n, cend - offset)
            inner = offset - cstart
            if typ == _RAW:
                out += self.f.pread(off + inner, take)
            elif typ == _ZLIB:
                out += self._chunk_bytes(ch)[inner : inner + take]
            else:
                out += bytes(take)
            offset += take
            n -= take
        return bytes(out)


# ---------------------------------------------------------------- GPT

HFS_TYPE = "48465300-0000-11aa-aa11-00306543ecac"
APFS_TYPE = "7c3457ef-0000-11aa-aa11-00306543ecac"


def guid(b):
    import uuid

    return str(uuid.UUID(bytes_le=bytes(b)))


def gpt_partitions(disk, sector=512):
    hdr = disk.pread(sector, 92)
    if hdr[:8] != b"EFI PART":
        raise RemoteError("no GPT header")
    lba, num, esz = struct.unpack("<QII", hdr[72:88])
    table = disk.pread(lba * sector, num * esz)
    out = []
    for i in range(num):
        e = table[i * esz : (i + 1) * esz]
        if e[:16] == bytes(16):
            continue
        first, last = struct.unpack("<QQ", e[32:48])
        name = e[56:128].decode("utf-16-le").rstrip("\0")
        out.append(
            {"index": i + 1, "type": guid(e[:16]), "uuid": guid(e[16:32]),
             "start": first * sector, "size": (last - first + 1) * sector, "name": name}
        )
    return out


# ---------------------------------------------------------------- HFS+


class HFSVolume:
    """Read-only HFS+/HFSX: catalog lookup by path, data forks with overflow extents."""

    def __init__(self, f):
        self.f = f
        vh = f.pread(1024, 512)
        if vh[:2] not in (b"H+", b"HX"):
            raise RemoteError("not an HFS+ volume")
        self.block = struct.unpack(">I", vh[40:44])[0]
        self.extents_fork = self._fork(vh[192:272])
        self.catalog_fork = self._fork(vh[272:352])
        self.extents = None
        self.extents = self._btree(self.extents_fork, file_id=3)
        self.catalog = self._btree(self.catalog_fork, file_id=4)

    @staticmethod
    def _fork(b):
        size = struct.unpack(">Q", b[:8])[0]
        exts = [struct.unpack(">II", b[16 + 8 * i : 24 + 8 * i]) for i in range(8)]
        return size, [e for e in exts if e[1]]

    def _overflow(self, file_id, have_blocks):
        """Extents beyond the first eight, from the extents overflow B-tree."""
        out = []
        if self.extents is None:
            return out
        for key, rec in self.extents.leaf_records():
            fork_type = key[2]
            fid, start = struct.unpack(">II", key[4:12])
            if fid == file_id and fork_type == 0 and start >= have_blocks:
                group = [struct.unpack(">II", rec[8 * i : 8 * i + 8]) for i in range(8)]
                out.append((start, group))
        exts = []
        for _start, group in sorted(out):
            exts += [e for e in group if e[1]]
        return exts

    def open_fork(self, fork, file_id):
        size, exts = fork
        have = sum(c for _, c in exts)
        if have * self.block < size:
            exts = exts + self._overflow(file_id, have)
        return _ExtentFile(self.f, self.block, size, exts)

    def _btree(self, fork, file_id):
        return _BTree(self.open_fork(fork, file_id))

    def lookup(self, path):
        """Return (kind, record) for '/a/b/c'; kind is 'file' or 'folder'."""
        parent = 2  # root folder CNID
        rec = None
        for part in [p for p in path.split("/") if p]:
            rec = self.catalog.find_catalog(parent, part)
            if rec is None:
                raise FileNotFoundError(path)
            rtype = struct.unpack(">h", rec[:2])[0]
            parent = struct.unpack(">I", rec[8:12])[0]
            kind = {1: "folder", 2: "file"}.get(rtype)
        return kind, rec

    def listdir(self, path="/"):
        parent = 2
        if path.strip("/"):
            kind, rec = self.lookup(path)
            parent = struct.unpack(">I", rec[8:12])[0]
        out = []
        for key, rec in self.catalog.leaf_records():
            pid = struct.unpack(">I", key[2:6])[0]
            rtype = struct.unpack(">h", rec[:2])[0]
            if pid == parent and rtype in (1, 2):
                n = struct.unpack(">H", key[6:8])[0]
                name = key[8 : 8 + 2 * n].decode("utf-16-be")
                size = struct.unpack(">Q", rec[88:96])[0] if rtype == 2 else None
                out.append((name, "file" if rtype == 2 else "folder", size))
        return out

    def open(self, path):
        kind, rec = self.lookup(path)
        if kind != "file":
            raise IsADirectoryError(path)
        file_id = struct.unpack(">I", rec[8:12])[0]
        return self.open_fork(self._fork(rec[88:168]), file_id)


class _ExtentFile(_Reader):
    def __init__(self, f, block, size, extents):
        super().__init__()
        self.f, self.block, self.size = f, block, size
        self.map = []  # (file_off, disk_off, length)
        pos = 0
        for start, count in extents:
            self.map.append((pos, start * block, count * block))
            pos += count * block
        if pos < size:
            raise RemoteError("HFS+ fork extents shorter than the file")

    def pread(self, offset, n):
        out = bytearray()
        for fo, do, ln in self.map:
            if n <= 0:
                break
            if offset >= fo + ln:
                continue
            inner = offset - fo
            take = min(n, ln - inner)
            out += self.f.pread(do + inner, take)
            offset += take
            n -= take
        return bytes(out)


class _BTree:
    def __init__(self, f):
        self.f = f
        hdr = f.pread(0, 512)
        rec = hdr[14:]
        (self.depth, self.root, self.leaf_count, self.first_leaf, self.last_leaf,
         self.node_size) = struct.unpack(">HIIIIH", rec[:20])

    def node(self, n):
        b = self.f.pread(n * self.node_size, self.node_size)
        flink, _blink, kind, _height, nrec = struct.unpack(">IIbBH", b[:12])
        offs = [struct.unpack(">H", b[self.node_size - 2 * (i + 1) : self.node_size - 2 * i])[0]
                for i in range(nrec + 1)]
        recs = [b[offs[i] : offs[i + 1]] for i in range(nrec)]
        return flink, kind, recs

    def leaf_records(self):
        n = self.first_leaf
        while n:
            flink, kind, recs = self.node(n)
            for r in recs:
                klen = struct.unpack(">H", r[:2])[0]
                key = r[: 2 + klen]
                yield key, r[2 + klen :]
            n = flink

    def find_catalog(self, parent, name):
        for key, rec in self.leaf_records_for(parent):
            n = struct.unpack(">H", key[6:8])[0]
            if key[8 : 8 + 2 * n].decode("utf-16-be") == name:
                return rec
        return None

    def leaf_records_for(self, parent):
        # Descend index nodes to the first leaf that can hold ``parent``.
        n = self.root
        while True:
            flink, kind, recs = self.node(n)
            if kind == -1:  # leaf
                break
            child = None
            for r in recs:
                klen = struct.unpack(">H", r[:2])[0]
                pid = struct.unpack(">I", r[2:6])[0]
                if pid < parent or child is None:
                    child = struct.unpack(">I", r[2 + klen : 6 + klen])[0]
                if pid >= parent:
                    break
            n = child
        while n:
            flink, kind, recs = self.node(n)
            past = False
            for r in recs:
                klen = struct.unpack(">H", r[:2])[0]
                pid = struct.unpack(">I", r[2:6])[0]
                if pid == parent:
                    yield r[: 2 + klen], r[2 + klen :]
                elif pid > parent:
                    past = True
                    break
            if past:
                return
            n = flink
