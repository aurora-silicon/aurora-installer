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


if __name__ == "__main__":
    unittest.main()
