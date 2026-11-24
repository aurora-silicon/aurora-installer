# SPDX-License-Identifier: MIT
"""asahi_firmware.ipsw and udif_ro: the restore image source. Synthetic
data only, no network."""
import json
import pathlib
import plistlib
import re
import struct
import sys
import types
import unittest
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from asahi_firmware import ipsw, udif_ro  # noqa: E402


def manifest(build, version, boards, ext=".dmg.aea"):
    return plistlib.dumps({"ProductBuildVersion": build, "ProductVersion": version, "BuildIdentities": [
        {"Info": {"DeviceClass": f"{b}ap"}, "Manifest": {"OS": {"Info": {"Path": f"{build}-{b}{ext}"}}}}
        for b in boards]})


def zips(table):
    def open_zip(url):
        if table[url] is None:
            raise OSError("offline")
        data = table[url]
        return types.SimpleNamespace(members={"BuildManifest.plist": types.SimpleNamespace(
            usize=len(data), read=lambda n: data)})
    return open_zip


class Catalog(unittest.TestCase):
    def test_every_stub_image_the_installer_admits_is_listed(self):
        src = (ROOT / "macOS/Sources/AuroraAppleInstaller/NativeInspectionPolicySource.swift").read_text()
        policy = json.loads(src[src.index('#"""') + 4:src.index('"""#')])
        want = set()
        for f in policy["firmware"]:
            m = re.search(r"UniversalMac_([0-9.]+)_([0-9A-Z]+)_Restore\.ipsw$", f["sourceURL"])
            if m:
                want.add((f["version"], m[2], f["sourceURL"]))
        self.assertTrue(want)
        self.assertEqual(set(ipsw.catalog()), want)

    def test_versions(self):
        e = [("27.2", "26B7124", "https://a"), ("27.2", "26B123", "https://b"), ("13.5", "22G74", "https://c"),
             ("27.2", "26B123", "https://dup")]
        self.assertEqual(ipsw.images_for_version("27.2", e), [("26B7124", "https://a"), ("26B123", "https://b")])
        self.assertEqual(ipsw.images_for_version("14.0", e), [])

    def test_the_feed_is_asked_only_for_a_version_the_catalog_lacks(self):
        from unittest import mock
        with mock.patch.object(ipsw, "catalog", return_value=[("27.2", "26B123", "https://b")]), \
                mock.patch.object(ipsw, "feed", return_value=[("27.3", "26C1", "https://f")]) as f:
            self.assertEqual(ipsw.images_for_version("27.2"), [("26B123", "https://b")])
            f.assert_not_called()
            self.assertEqual(ipsw.images_for_version("27.3"), [("26C1", "https://f")])
            f.assert_called_once()


class Find(unittest.TestCase):
    IMAGES = [("26B7124", "https://a"), ("26B123", "https://b")]

    def test_first_image_carrying_the_board(self):
        oz = zips({"https://a": manifest("26B7124", "27.2", ["j999"]),
                   "https://b": manifest("26B123", "27.2", ["j473", "j713"])})
        self.assertEqual(ipsw.find("j713", self.IMAGES, "27.2", oz), ("26B123", "https://b", "26B123-j713.dmg.aea"))
        with self.assertRaisesRegex(ipsw.IpswError, "carries board j000"):
            ipsw.find("j000", self.IMAGES, "27.2", oz)

    def test_an_image_that_is_not_what_it_is_listed_as(self):
        oz = zips({"https://a": manifest("26B131", "27.2.1", ["j713"]), "https://b": b""})
        with self.assertRaises(ipsw.IpswError):
            ipsw.find("j713", self.IMAGES, "27.2", oz)
        oz = zips({"https://a": manifest("26B7124", "27.1", ["j713"]), "https://b": b""})
        with self.assertRaises(ipsw.IpswError):
            ipsw.find("j713", self.IMAGES, "27.2", oz)

    def test_unknown_version_and_offline(self):
        with self.assertRaisesRegex(ipsw.IpswError, "no restore image of macOS 99.0"):
            ipsw.find("j713", [], "99.0")
        with self.assertRaises(ipsw.IpswUnavailable):
            ipsw.find("j713", self.IMAGES, "27.2", zips({"https://a": None}))


class Src:
    def __init__(self, data):
        self.data = data

    def pread(self, n, off):
        return self.data[off:off + n]


def udif(chunks, name="Apple_APFS", total=None):
    """A UDIF image: chunks = [(kind, data or sector count)]."""
    fork, entries, sec = b"", [], 0
    for kind, v in chunks:
        if kind in (udif_ro.ZERO, udif_ro.IGNORE):
            cnt, blob = v, b""
        else:
            cnt = len(v) // 512
            blob = zlib.compress(v) if kind == udif_ro.ZLIB else v
        entries.append(struct.pack(">IIQQQQ", kind, 0, sec, cnt, len(fork), len(blob)))
        fork += blob
        sec += cnt
    entries.append(struct.pack(">IIQQQQ", udif_ro.END, 0, sec, 0, len(fork), 0))
    mish = b"mish" + struct.pack(">IQQQ", 1, 0, total if total is not None else sec, 0) + bytes(200 - 32) \
        + struct.pack(">I", len(entries)) + b"".join(entries)
    xml = plistlib.dumps({"resource-fork": {"blkx": [{"Name": f"disk image ({name} : 2)", "Data": mish}]}})
    koly = bytearray(512)
    koly[:4] = b"koly"
    struct.pack_into(">QQ", koly, 24, 0, len(fork))
    struct.pack_into(">QQ", koly, 216, len(fork), len(xml))
    img = fork + xml + bytes(koly)
    return Src(img), len(img)


class Udif(unittest.TestCase):
    def test_reads_across_chunk_kinds(self):
        a, c = bytes(range(256)) * 4, b"\x07" * 1024
        src, size = udif([(udif_ro.RAW, a), (udif_ro.ZERO, 2), (udif_ro.ZLIB, c), (udif_ro.IGNORE, 1)])
        p = udif_ro.Partition(src, size)
        self.assertEqual(p.size, 512 * 7)
        self.assertEqual(p.pread(p.size, 0), a + bytes(1024) + c + bytes(512))
        self.assertEqual(p.pread(10, 1020), a[1020:] + bytes(6))

    def test_malformed_images_are_errors(self):
        with self.assertRaises(udif_ro.UdifError):
            udif_ro.Partition(Src(bytes(1024)), 1024)
        src, size = udif([(udif_ro.RAW, bytes(512))], name="Apple_HFS")
        with self.assertRaises(udif_ro.UdifError):
            udif_ro.Partition(src, size)
        src, size = udif([(udif_ro.RAW, bytes(512))], total=5)
        with self.assertRaises(udif_ro.UdifError):
            udif_ro.Partition(src, size)
        src, size = udif([(0x80000006, bytes(512))])
        with self.assertRaisesRegex(udif_ro.UdifError, "not supported"):
            udif_ro.Partition(src, size)
        src, size = udif([(udif_ro.RAW, bytes(512))])
        with self.assertRaises(udif_ro.UdifError):
            udif_ro.Partition(src, size).pread(1, 512)


if __name__ == "__main__":
    unittest.main()
