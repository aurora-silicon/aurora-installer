# SPDX-License-Identifier: MIT
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import aura  # noqa: E402


class VersionDetectionTest(unittest.TestCase):
    def test_aura_marker(self):
        found = aura.find_version(b"code ##aura_ver##1.0b1\0 more")
        self.assertEqual(found, aura.LoaderVersion("aura", "1.0b1"))
        self.assertFalse(found.legacy)
        self.assertEqual(str(found), "aura 1.0b1")

    def test_legacy_m1n1_marker(self):
        found = aura.find_version(b"code ##m1n1_ver##v1.5.2\0 more")
        self.assertEqual(found, aura.LoaderVersion("m1n1", "v1.5.2"))
        self.assertTrue(found.legacy)
        self.assertEqual(str(found), "m1n1 v1.5.2")

    def test_aura_marker_wins_over_legacy(self):
        data = b"##m1n1_ver##v1.5.2\0 ... ##aura_ver##1.0b1\0"
        self.assertEqual(aura.find_version(data), aura.LoaderVersion("aura", "1.0b1"))

    def test_no_marker(self):
        self.assertIsNone(aura.find_version(b"some other kernelcache"))

    def test_get_version_reads_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "kernelcache")
            with open(path, "wb") as fd:
                fd.write(b"\0\0##aura_ver##1.0b1\0STACKBOT")
            self.assertEqual(aura.get_version(path), aura.LoaderVersion("aura", "1.0b1"))


class UpgradeTest(unittest.TestCase):
    bundled = aura.LoaderVersion("aura", "1.0b1")

    def test_legacy_install_is_upgradable(self):
        self.assertTrue(aura.needs_upgrade(aura.LoaderVersion("m1n1", "1.0b1"), self.bundled))
        self.assertTrue(aura.needs_upgrade(aura.LoaderVersion("m1n1", "v1.5.2"), self.bundled))

    def test_older_aura_is_upgradable(self):
        self.assertTrue(aura.needs_upgrade(aura.LoaderVersion("aura", "0.9"), self.bundled))

    def test_same_aura_is_not_upgradable(self):
        self.assertFalse(aura.needs_upgrade(aura.LoaderVersion("aura", "1.0b1"), self.bundled))

    def test_unknown_is_not_upgradable(self):
        self.assertFalse(aura.needs_upgrade(None, self.bundled))
        self.assertFalse(aura.needs_upgrade(self.bundled, None))


class ImageTest(unittest.TestCase):
    def test_build_and_extract_vars_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "aura.bin")
            dest = os.path.join(tmp, "boot.bin")
            with open(src, "wb") as fd:
                fd.write(b"##aura_ver##1.0b1\0code STACKBOT")
            vars = ["chosen.asahi,efi-system-partition=abcd", "chainload=abcd;m1n1/boot.bin"]
            aura.build(src, dest, vars)
            self.assertEqual(aura.extract_vars(dest), vars)
            self.assertEqual(aura.get_version(dest), aura.LoaderVersion("aura", "1.0b1"))

    def test_legacy_boot_object_resolves_to_aura(self):
        with tempfile.TemporaryDirectory() as tmp:
            open(os.path.join(tmp, "aura.bin"), "wb").close()
            self.assertEqual(aura.stage1_path(tmp, "m1n1.bin"), os.path.join(tmp, "aura.bin"))
            open(os.path.join(tmp, "m1n1.bin"), "wb").close()
            self.assertEqual(aura.stage1_path(tmp, "m1n1.bin"), os.path.join(tmp, "m1n1.bin"))
            self.assertEqual(aura.stage1_path(tmp, "aura.bin"), os.path.join(tmp, "aura.bin"))


def synthetic_stage1(segments, block_in="DATA", block_version=1, magics=1):
    """A minimal 64-bit Mach-O: one LC_SEGMENT_64 per (name, size), laid out back to back."""
    import struct
    cmds, fileoff, layout = b"", 0x1000, {}
    for name, size in segments:
        layout[name] = (fileoff, size)
        cmds += struct.pack("<II16sQQQQiiII", 0x19, 0x48, name.encode().ljust(16, b"\0"),
                            0xfffffe0007004000 + fileoff, size, fileoff, size, 5, 5, 0, 0)
        fileoff += size
    head = struct.pack("<IiiIIIII", 0xfeedfacf, 0x100000c, 0, 0xc, len(segments), len(cmds), 0, 0)
    image = bytearray((head + cmds).ljust(0x1000, b"\0") + bytes(fileoff - 0x1000))
    start = layout[block_in][0] + 0x100
    for i in range(magics):
        at = start + i * 0x400
        image[at:at + len(aura.STAGE1_CFG_MAGIC)] = aura.STAGE1_CFG_MAGIC
        struct.pack_into("<I", image, at + len(aura.STAGE1_CFG_MAGIC), block_version)
    return bytes(image), start


class Stage1MachoTest(unittest.TestCase):
    UUID = "d68c1e6b-195f-4d60-afb3-70e8b3fb2f4a"
    SEGS = [("__TEXT_EXEC", 0x4000), ("__PRELINK_INFO", 0x4000), ("DATA", 0x4000), ("__LINKEDIT", 0x4000)]

    def fill(self, image, uuid=None, path="aurora/stage2.macho", window=8000):
        with tempfile.TemporaryDirectory() as tmp:
            src, dst = os.path.join(tmp, "s1.macho"), os.path.join(tmp, "boot.macho")
            with open(src, "wb") as fd:
                fd.write(image)
            aura.fill_stage1_macho(src, dst, uuid or self.UUID, path, window)
            with open(dst, "rb") as fd:
                return fd.read()

    def test_fill(self):
        import struct, zlib
        image, at = synthetic_stage1(self.SEGS)
        out = self.fill(image)
        self.assertEqual(len(out), len(image))
        self.assertEqual(out[:at], image[:at])
        end = at + aura.STAGE1_CFG_SIZE
        self.assertEqual(out[end:], image[end:])
        fields = out[at + 16:end - 4]
        version, window, uuid, path = aura.STAGE1_CFG_FIELDS.unpack(fields)
        self.assertEqual((version, window), (1, 8000))
        self.assertEqual(uuid.rstrip(b"\0"), self.UUID.encode())
        self.assertEqual(path.rstrip(b"\0"), b";aurora/stage2.macho")
        self.assertEqual(struct.unpack("<I", out[end - 4:end])[0], zlib.crc32(fields))

    def test_refuses_sptm_boot_object(self):
        image, _ = synthetic_stage1(self.SEGS + [("__TEXT_BOOT_EXEC", 0x4000)])
        with self.assertRaises(ValueError):
            self.fill(image)

    def test_refuses_bad_inputs(self):
        image, _ = synthetic_stage1(self.SEGS)
        for kwargs in (dict(uuid="D68C1E6B-195F-4D60-AFB3-70E8B3FB2F4A"), dict(uuid="not-a-uuid"),
                       dict(path="../stage2.macho"), dict(path="a;b"), dict(path="x" * 200),
                       dict(path="aurora//s2"), dict(window=100000)):
            with self.assertRaises(ValueError, msg=kwargs):
                self.fill(image, **kwargs)

    def test_refuses_bad_blocks(self):
        for kwargs in (dict(magics=0), dict(magics=2), dict(block_version=2), dict(block_in="__LINKEDIT")):
            image, _ = synthetic_stage1(self.SEGS, **kwargs)
            with self.assertRaises(ValueError, msg=kwargs):
                self.fill(image)

    def test_refuses_raw_image(self):
        with self.assertRaises(ValueError):
            self.fill(b"\0" * 0x1000 + aura.STAGE1_CFG_MAGIC + b"\1\0\0\0" + bytes(300) + b"STACKBOT")


if __name__ == "__main__":
    unittest.main()
