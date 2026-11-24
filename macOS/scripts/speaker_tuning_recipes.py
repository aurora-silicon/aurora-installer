# SPDX-License-Identifier: MIT
# Copyright (c) 2026 The Aurora Silicon Contributors
"""Writes the sealed range recipes the native installer uses to read each
Mac's speaker tuning from Apple's pinned macOS restore images.

Maintenance tool only: it is not part of the app, which reads the recipes
compiled into it (macOS/Sources/AuroraFirmware/Resources/speaker-tuning).
A recipe holds byte offsets, sizes and SHA-256 digests, never Apple data.

For each pinned image, in order, it reads the BuildManifest's boards and
each board's device tree from the image itself (the `acoustic-id` of its
audio node), so the board-to-AID mapping is the image's own data. For each
AID a board of the image carries (and no earlier image already carries for
that board), it writes one recipe with, from the image's System volume:

- every regular file of System/Library/Audio/Tunings/AID<n>/ (sidecars
  skipped, an in-folder link written as a copy of the file it names);
- System/Library/Audio/Tunings/DeviceDSPDatabase.plist, when present;
- System/Library/Audio/Tunings/Config/AID<n>.plist;
- System/Library/Audio/Tunings/DRC/loudness-manager.plist, when present;
- the Common/ files the entry's Built-in Speaker modes reference;
- System/Library/Components/AudioDSP.component/Contents/MacOS/AudioDSP.

and an index (index.json) naming the release, each image's build, URL,
size and SHA-256, its board-to-AID map and each recipe's SHA-256.

The image must be a complete local copy (the whole-file, system image and
decoded image digests are part of the recipe identity); the URL is what
the installer fetches ranges from. The AEA key comes from Apple's key
service named in the image. The AEA and APFS readers are speakerguardd's
read-only ones (packaging/upgrade/aurora_speaker_upgrade):

    python3 -I macOS/scripts/speaker_tuning_recipes.py \\
        --speakerguardd ../speakerguardd/packaging/upgrade \\
        --release 27.2 --output macOS/Sources/AuroraFirmware/Resources/speaker-tuning \\
        26B123=URL=PATH 26B8125=URL=PATH
"""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import stat
import struct
import sys
import zipfile

REPO = pathlib.Path(__file__).resolve().parents[2]
TUNINGS = "System/Library/Audio/Tunings"
COMPONENT = "System/Library/Components/AudioDSP.component/Contents/MacOS/AudioDSP"
SPEAKER = "Built-in Speaker"
MAX_FILES = 128
MAX_RANGE_BYTES = 64 << 20
SEGMENT = 1 << 20
CLUSTER_WIDTH = 256
CLUSTER_HEADER = CLUSTER_WIDTH * 72 + 32


class RecipeError(Exception):
    pass


def sha(data):
    return hashlib.sha256(data).hexdigest()


class LocalSlice:
    """Bytes [base, base+size) of a local file, as aea_ro reads a range."""

    def __init__(self, fd, base, size):
        self.fd, self.base, self.size = fd, base, size

    def get(self, off, n):
        if off < 0 or off + n > self.size:
            raise RecipeError("read outside the system image")
        out = os.pread(self.fd, n, self.base + off)
        if len(out) != n:
            raise RecipeError("short read")
        return out


def file_sha256(fd, base, size):
    h = hashlib.sha256()
    off = 0
    while off < size:
        chunk = os.pread(fd, min(64 << 20, size - off), base + off)
        if not chunk:
            raise RecipeError("short read")
        h.update(chunk)
        off += len(chunk)
    return h.hexdigest()


def node_values(apfs, block, bs):
    """(key bytes, value offset in block, value length) per record of a
    b-tree node, as apfs_ro.Node reads them."""
    flags, level, nkeys = struct.unpack_from("<HHI", block, 32)
    toff, tlen = struct.unpack_from("<HH", block, 40)
    kstart = 56 + toff + tlen
    vend = bs - (40 if flags & apfs.BTNODE_ROOT else 0)
    out = []
    for i in range(nkeys):
        if flags & apfs.BTNODE_FIXED:
            k, v = struct.unpack_from("<HH", block, 56 + toff + 4 * i)
            kl, vl = 16, 16 if level == 0 else 8
        else:
            k, kl, v, vl = struct.unpack_from("<HHHH", block, 56 + toff + 8 * i)
        if v == 0xFFFF:
            continue
        out.append((block[kstart + k:kstart + k + kl], vend - v, vl))
    return level, out


class Image:
    def __init__(self, apfs, aea, path, url, build):
        self.apfs, self.url, self.build = apfs, url, build
        self.path = path
        self.fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
        self.size = os.fstat(self.fd).st_size
        self.zip = zipfile.ZipFile(path)
        manifest = plistlib.loads(self.zip.read("BuildManifest.plist"))
        if manifest.get("ProductBuildVersion") != build:
            raise RecipeError(f"{path} is {manifest.get('ProductBuildVersion')}, not {build}")
        self.manifest = manifest
        members = {bi["Manifest"]["OS"]["Info"]["Path"] for bi in manifest["BuildIdentities"]
                   if "OS" in bi.get("Manifest", {})}
        if len(members) != 1:
            raise RecipeError(f"{build}: {len(members)} root file systems")
        self.member = members.pop()
        info = self.zip.getinfo(self.member)
        if info.compress_type != 0:
            raise RecipeError(f"{self.member} is not a stored member")
        local = os.pread(self.fd, 30, info.header_offset)
        if local[:4] != b"PK\3\4":
            raise RecipeError("bad ZIP local header")
        nl, xl = struct.unpack_from("<HH", local, 26)
        self.zip_header_offset = info.header_offset
        self.zip_header_size = 30 + nl + xl
        self.member_offset = info.header_offset + 30 + nl + xl
        self.member_size = info.file_size
        self.src = LocalSlice(self.fd, self.member_offset, self.member_size)
        self.archive = aea.Archive(self.src)
        vols = [v for v in apfs.Container(self.archive).volumes() if v.role == apfs.ROLE_SYSTEM]
        if len(vols) != 1:
            raise RecipeError(f"{build}: no single System volume")
        self.vol = vols[0]

    # ---------------------------------------------------------------- boards

    def boards(self, adt, img4):
        """{DeviceClass: acoustic-id} for every board of the manifest whose
        device tree has exactly one node carrying an acoustic-id."""
        out = {}
        classes = sorted({bi["Info"]["DeviceClass"] for bi in self.manifest["BuildIdentities"]
                          if "OS" in bi.get("Manifest", {})})
        for board in classes:
            paths = {bi["Manifest"]["DeviceTree"]["Info"]["Path"]
                     for bi in self.manifest["BuildIdentities"]
                     if bi["Info"]["DeviceClass"] == board and "DeviceTree" in bi.get("Manifest", {})}
            if len(paths) != 1:
                raise RecipeError(f"{board}: {len(paths)} device trees")
            payload = img4.img4p_extract(self.zip.read(paths.pop()))
            if isinstance(payload, tuple):
                payload = payload[-1]
            found = []

            def walk(node):
                if "acoustic-id" in node.properties:
                    found.append(node.properties["acoustic-id"])
                for child in node.children:
                    walk(child)
            walk(adt.parse(payload))
            if not found:
                continue
            if len(found) != 1 or len(found[0]) != 4:
                raise RecipeError(f"{board}: ambiguous acoustic-id")
            out[board] = struct.unpack("<I", found[0])[0]
        return out

    # ---------------------------------------------------------------- APFS

    def _node(self, oid, physical):
        a, v = self.apfs, self.vol
        if physical:
            paddr = oid
            block = v._read_phys(oid)
        else:
            paddr, flags = v.omap().lookup(oid, v.xid)
            if flags & a.OMAP_VAL_ENCRYPTED:
                raise RecipeError("encrypted volume")
            block = v.dev.obj(paddr, noheader=bool(flags & a.OMAP_VAL_NOHEADER))
        return paddr, block

    def records(self, oid, typ):
        """[(key, value, absolute value offset in the decoded image)] of
        one object's fs-tree records: apfs_ro.Volume.records, with where
        each value lies."""
        a, v = self.apfs, self.vol
        bs = v.dev.bs
        root = v.node(v.root_oid, False)
        physical = bool(struct.unpack_from("<I", root.info, 0)[0] & a.BTREE_PHYSICAL) \
            if root.info else False
        relative = bool(root.flags & a.BTNODE_NOHEADER) and not physical
        want = (oid, typ)
        out = []

        def walk(child, depth):
            if depth > 16:
                raise RecipeError("fs tree too deep")
            paddr, block = self._node(child, physical)
            level, values = node_values(a, block, bs)
            keys = [a.jkey(k) for k, _, _ in values]
            for i, (k, voff, vl) in enumerate(values):
                val = block[voff:voff + vl]
                if level == 0:
                    if keys[i] == want:
                        out.append((k, val, paddr * bs + voff))
                    continue
                nxt = keys[i + 1] if i + 1 < len(keys) else None
                if keys[i] <= want and (nxt is None or nxt >= want):
                    c = struct.unpack_from("<Q", val)[0]
                    walk(c + v.root_oid if relative else c, depth + 1)
        walk(v.root_oid, 0)
        return out

    def stream_spans(self, private_id, size):
        bs = self.vol.dev.bs
        spans, covered = [], 0
        for la, ln, pb in self.vol.extents(private_id):
            if la >= size:
                continue
            if la != covered or pb == 0:
                raise RecipeError("sparse or discontiguous data stream")
            n = min(ln, size - la)
            off = pb * bs
            if spans and spans[-1][0] + spans[-1][1] == off:
                spans[-1][1] += n
            else:
                spans.append([off, n])
            covered += n
        if covered != size:
            raise RecipeError("data stream shorter than its size")
        return [{"offset": o, "size": n} for o, n in spans]

    def xattr_storage(self, ino, name):
        a = self.apfs
        for k, v, voff in self.records(ino, a.T_XATTR):
            nl = struct.unpack_from("<H", k, 8)[0]
            if k[10:10 + nl].rstrip(b"\0").decode("utf-8", "replace") != name:
                continue
            flags, dl = struct.unpack_from("<HH", v)
            if flags & a.XATTR_DATA_EMBEDDED:
                spans = [{"offset": voff + 4, "size": dl}]
                return dl, spans
            oid, size = struct.unpack_from("<QQ", v, 4)
            return size, self.stream_spans(oid, size)
        return None

    def read_spans(self, spans):
        return b"".join(self.archive.pread(s["size"], s["offset"]) for s in spans)

    def file_record(self, source, name, ino):
        a, vol = self.apfs, self.vol
        info = vol.inode(ino)
        if not stat.S_ISREG(info["mode"]):
            raise RecipeError(f"{source}: not a regular file")
        content = vol.read_file(ino)
        storage = []
        compressed = False
        xattrs = vol.xattrs(ino) if info["compressed"] else {}
        if "com.apple.decmpfs" in xattrs:
            compressed = True
            size, spans = self.xattr_storage(ino, "com.apple.decmpfs")
            header = self.read_spans(spans)
            kind = struct.unpack_from("<I", header, 4)[0]
            if kind not in (3, 4, 7, 8, 9, 11, 12):
                raise RecipeError(f"{source}: decmpfs type {kind} has no recipe form")
            if kind == 9:
                # Uncompressed in the attribute: a 0xcc marker byte, then
                # the file (apfs_ro reads this type without the marker).
                usize = struct.unpack_from("<Q", header, 8)[0]
                if len(header) != 17 + usize or header[16] != 0xCC or usize > 65536:
                    raise RecipeError(f"{source}: unexpected decmpfs type 9 layout")
                content = header[17:]
            storage.append({"size": size, "sha256": sha(header), "spans": spans})
            if kind % 2 == 0:
                fork = self.xattr_storage(ino, "com.apple.ResourceFork")
                if fork is None or size != 16:
                    raise RecipeError(f"{source}: resource fork layout")
                fsize, fspans = fork
                storage.append({"size": fsize, "sha256": sha(self.read_spans(fspans)),
                                "spans": fspans})
        else:
            spans = self.stream_spans(info["private_id"], info["size"])
            data = self.read_spans(spans)
            if data != content:
                raise RecipeError(f"{source}: data stream spans do not read back")
            storage.append({"size": len(data), "sha256": sha(data), "spans": spans})
        digest = sha(content)
        return {"source": source, "name": name, "transform": "identity",
                "compressed": compressed, "raw_sha256": digest, "sha256": digest,
                "size": len(content), "storage": storage}, content

    def lookup(self, path):
        try:
            return self.vol.resolve(path)
        except self.apfs.ApfsError:
            return None

    def folder_files(self, folder):
        """[(relative path, inode)] of a tuning folder: regular files, and
        each in-folder link as the regular file it names in its own
        directory (at most 8 links), as the installer admits them."""
        top = self.lookup(folder)
        if top is None or top[1] != 4:
            raise RecipeError(f"{folder}: no such folder")
        out = []

        def rec(ino, rel):
            kids = self.vol.children(ino)
            for name in sorted(kids):
                cino, kind = kids[name]
                path = rel + name
                if name.startswith("._") or name == ".DS_Store":
                    continue
                if kind == 4:
                    rec(cino, path + "/")
                elif kind == 8:
                    out.append((path, cino))
                elif kind == 10:
                    target, here = cino, kids
                    for _ in range(8):
                        dest = self.vol.readlink(target)
                        if "/" in dest or dest not in here:
                            raise RecipeError(f"{folder}/{path}: link outside its directory")
                        target, tkind = here[dest]
                        if tkind == 8:
                            break
                        if tkind != 10:
                            raise RecipeError(f"{folder}/{path}: link to a non-file")
                    else:
                        raise RecipeError(f"{folder}/{path}: link chain too long")
                    out.append((path, target))
                else:
                    raise RecipeError(f"{folder}/{path}: unsupported entry")
        rec(top[0], "")
        return out

    # ---------------------------------------------------------------- recipe

    def recipe_files(self, aid):
        folder = f"{TUNINGS}/AID{aid}"
        files, contents = [], {}

        def add(path, ino):
            record, data = self.file_record(path, path, ino)
            files.append(record)
            contents[path] = data
        for rel, ino in self.folder_files(folder):
            add(f"{folder}/{rel}", ino)
        for path in (f"{TUNINGS}/DeviceDSPDatabase.plist", f"{TUNINGS}/Config/AID{aid}.plist",
                     f"{TUNINGS}/DRC/loudness-manager.plist"):
            hit = self.lookup(path)
            if hit is not None:
                if hit[1] != 8:
                    raise RecipeError(f"{path}: not a regular file")
                add(path, hit[0])
        if f"{TUNINGS}/Config/AID{aid}.plist" not in contents:
            raise RecipeError(f"AID{aid}: no volume configuration")
        database = contents.get(f"{folder}/DSP/DSPDatabase.plist") \
            or contents.get(f"{TUNINGS}/DeviceDSPDatabase.plist")
        if database is None:
            raise RecipeError(f"AID{aid}: no DSP database")
        entry = plistlib.loads(database).get(f"AID{aid}", {})
        refs = []

        def paths(node):
            if isinstance(node, dict):
                for k, val in node.items():
                    if k == "Path" and isinstance(val, str):
                        refs.append(val)
                    else:
                        paths(val)
            elif isinstance(node, list):
                for val in node:
                    paths(val)
        paths(entry.get(SPEAKER, {}))
        for ref in sorted(set(refs)):
            if ref.startswith("Common/"):
                hit = self.lookup(f"{TUNINGS}/{ref}")
                if hit is None or hit[1] != 8:
                    raise RecipeError(f"AID{aid}: speaker reference {ref} is not a file")
                if f"{TUNINGS}/{ref}" not in contents:
                    add(f"{TUNINGS}/{ref}", hit[0])
        hit = self.lookup(COMPONENT)
        if hit is None or hit[1] != 8:
            raise RecipeError("no AudioDSP component")
        add(COMPONENT, hit[0])
        if len(files) > MAX_FILES:
            raise RecipeError(f"AID{aid}: {len(files)} files")
        return files

    def recipe(self, aid, identity):
        files = self.recipe_files(aid)
        segments = set()
        for f in files:
            for s in f["storage"]:
                for span in s["spans"]:
                    segments.update(range(span["offset"] // SEGMENT,
                                          (span["offset"] + span["size"] - 1) // SEGMENT + 1))
        clusters = sorted({s // CLUSTER_WIDTH for s in segments})
        a = self.archive
        a._cluster(clusters[-1])
        headers = []
        for c in clusters:
            off = a.clusters[c][0]
            data = self.src.get(off, CLUSTER_HEADER)
            if c == 0:
                prefix = self.src.get(0, a.prefix_size)
                mac = prefix[a.prefix_size - 32:]
            else:
                prev = self.src.get(a.clusters[c - 1][0], CLUSTER_HEADER)
                mac = prev[CLUSTER_WIDTH * 40:CLUSTER_WIDTH * 40 + 32]
            headers.append({"offset": off, "size": CLUSTER_HEADER, "sha256": sha(data),
                            "cluster": c, "expected_mac": mac.hex()})
        seg = {}
        total = sum(h["size"] for h in headers)
        for s in sorted(segments):
            pos, size = a.clusters[s // CLUSTER_WIDTH][1][s % CLUSTER_WIDTH][:2]
            seg[str(s)] = {"offset": pos, "size": size, "sha256": sha(self.src.get(pos, size))}
            total += size
        if total > MAX_RANGE_BYTES:
            raise RecipeError(f"AID{aid}: {total} range bytes")
        zip_header = os.pread(self.fd, self.zip_header_size, self.zip_header_offset)
        prefix = self.src.get(0, a.prefix_size)
        return {
            "schema": 1,
            "source": {"url": self.url, "size_bytes": self.size, "sha256": identity["sha256"]},
            "system_image": {"member": self.member, "size_bytes": self.member_size,
                             "sha256": identity["member_sha256"],
                             "decoded": {"size_bytes": a.size,
                                         "sha256": identity["decoded_sha256"]}},
            "member_offset": self.member_offset,
            "zip_header": {"offset": self.zip_header_offset, "size": self.zip_header_size,
                           "sha256": sha(zip_header)},
            "prefix": {"offset": 0, "size": a.prefix_size, "sha256": sha(prefix)},
            "headers": headers,
            "segments": seg,
            "files": files,
        }

    def identity(self, cache, jobs):
        """Whole-file, system member and decoded image SHA-256s (slow: a
        full pass), kept in `cache` keyed by build."""
        if cache.get(self.build, {}).get("size_bytes") == self.size:
            return cache[self.build]
        print(f"{self.build}: hashing the restore image", file=sys.stderr)
        whole = None
        try:  # a sha256sum record written beside the download
            with open(self.path + ".sha256") as f:
                recorded = f.read().split()[0]
            if len(recorded) == 64:
                whole = recorded
        except OSError:
            pass
        whole = whole or file_sha256(self.fd, 0, self.size)
        member = file_sha256(self.fd, self.member_offset, self.member_size)
        print(f"{self.build}: decoding the system image", file=sys.stderr)
        a = self.archive
        a._cluster((a.nsegments - 1) // CLUSTER_WIDTH)
        work = []
        for sid in range(a.nsegments):
            pos, size, psize, digest, mac, ck = a.clusters[sid // CLUSTER_WIDTH][1][sid % CLUSTER_WIDTH]
            work.append((self.path, self.member_offset + pos, size, psize, digest, mac, ck,
                         sid % CLUSTER_WIDTH))
        h = hashlib.sha256()
        import multiprocessing
        with multiprocessing.get_context("fork").Pool(jobs) as pool:
            for plain in pool.imap(_decode_segment, work, chunksize=4):
                h.update(plain)
        cache[self.build] = {"size_bytes": self.size, "sha256": whole,
                             "member_sha256": member, "decoded_sha256": h.hexdigest()}
        return cache[self.build]


_AEA = None


def _decode_segment(item):
    """One authenticated AEA segment's plaintext (aea_ro.Archive.segment)."""
    path, off, size, psize, digest, mac, ck, index = item
    aea = _AEA
    with open(path, "rb") as f:
        f.seek(off)
        data = f.read(size)
    material = aea.derive(ck, b"", aea.indexed(b"AEA_SK", index), 80)
    aea.check_mac(material, data, b"", mac)
    plain = aea.ctr(material, data)
    if size != psize:
        plain = aea.bounded_lzfse(plain, psize)
    if len(plain) != psize or hashlib.sha256(plain).digest() != digest:
        raise RecipeError("AEA plaintext segment SHA-256 mismatch")
    return plain


def encode(doc, pretty=False):
    if pretty:
        return (json.dumps(doc, indent=1, sort_keys=True) + "\n").encode()
    return (json.dumps(doc, sort_keys=True, separators=(",", ":")) + "\n").encode()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--speakerguardd", required=True,
                    help="speakerguardd packaging/upgrade (holds aurora_speaker_upgrade)")
    ap.add_argument("--release", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--identity-cache", help="JSON file caching the slow whole-image digests")
    ap.add_argument("--jobs", type=int, default=8, help="decoder processes (default 8)")
    ap.add_argument("images", nargs="+", help="BUILD=URL=LOCAL-PATH, in pin order")
    args = ap.parse_args(argv)
    sys.path.insert(0, os.path.abspath(args.speakerguardd))
    sys.path.insert(1, str(REPO))
    from aurora_speaker_upgrade import aea_ro, apfs_ro
    from asahi_firmware import adt, img4
    global _AEA
    _AEA = aea_ro
    cache = {}
    if args.identity_cache and os.path.exists(args.identity_cache):
        with open(args.identity_cache) as f:
            cache = json.load(f)
    out = pathlib.Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    index = {"schema": 1, "kind": "aurora-speaker-tuning-restore-images",
             "release": args.release, "images": []}
    claimed = set()
    for spec in args.images:
        build, rest = spec.split("=", 1)
        url, path = rest.rsplit("=", 1)
        image = Image(apfs_ro, aea_ro, path, url, build)
        identity = image.identity(cache, args.jobs)
        if args.identity_cache:
            with open(args.identity_cache, "w") as f:
                json.dump(cache, f, indent=1, sort_keys=True)
        boards = {b: aid for b, aid in image.boards(adt, img4).items() if b not in claimed}
        claimed.update(boards)
        recipes = {}
        for aid in sorted(set(boards.values())):
            doc = encode(image.recipe(aid, identity))
            name = f"{build}-AID{aid}.json"
            (out / name).write_bytes(doc)
            recipes[str(aid)] = sha(doc)
            print(f"{name}: {len(doc)} bytes", file=sys.stderr)
        index["images"].append({"build": build, "url": url, "size_bytes": image.size,
                                "sha256": identity["sha256"], "boards": boards,
                                "recipes": recipes})
    (out / "index.json").write_bytes(encode(index, pretty=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
