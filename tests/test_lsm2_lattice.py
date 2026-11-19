# SPDX-License-Identifier: MIT
"""The lsm2 masker lattice locator, on synthetic Mach-O images only."""
import os
import pathlib
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from aurora_firmware import lsm2_lattice as L  # noqa: E402
from macho_fixtures import (CPU_X86_64, fat, other_lattice, padded,  # noqa: E402
                            synthetic_lattice, thin)

LAT = synthetic_lattice()


class RuleTest(unittest.TestCase):
    def test_synthetic_lattice_is_valid(self):
        self.assertTrue(L.valid(LAT))
        self.assertEqual(L.ends(LAT)[:64], list(range(1, 65)))
        self.assertEqual(L.ends(LAT)[-1], 321)

    def test_each_condition_is_required(self):
        ends = list(struct.unpack("<100Q", LAT))

        def bad(edit):
            e = list(ends)
            edit(e)
            return struct.pack(f"<{len(e)}Q", *e)

        self.assertFalse(L.valid(LAT[:-8]))                           # 99 entries
        self.assertFalse(L.valid(LAT + LAT[-8:]))                     # 101 entries
        self.assertFalse(L.valid(bad(lambda e: e.__setitem__(-1, 320))))   # final edge
        self.assertFalse(L.valid(bad(lambda e: e.__setitem__(-1, 322))))   # out of range
        self.assertFalse(L.valid(bad(lambda e: e.__setitem__(70, e[69]))))  # not strictly
        self.assertFalse(L.valid(bad(lambda e: e.__setitem__(10, 12))))    # singleton prefix
        self.assertFalse(L.valid(bad(lambda e: e.__setitem__(0, 0))))
        self.assertFalse(L.valid(None))
        with self.assertRaises(L.LatticeError):
            L.ends(b"\0" * 800)


class LocateTest(unittest.TestCase):
    def test_thin_image(self):
        self.assertEqual(L.extract(thin(padded(LAT))), LAT)

    def test_universal_image_with_identical_slices(self):
        image = fat(thin(padded(LAT), cpu=CPU_X86_64), thin(padded(LAT, before=8, after=0)))
        self.assertEqual(L.extract(image), LAT)
        three = fat(thin(padded(LAT), cpu=CPU_X86_64), thin(padded(LAT)), thin(padded(LAT)))
        self.assertEqual(L.extract(three), LAT)

    def test_missing_lattice_fails(self):
        with self.assertRaisesRegex(L.LatticeError, "found 0"):
            L.extract(thin(b"\x11" * 2048))

    def test_ambiguous_lattice_fails(self):
        with self.assertRaisesRegex(L.LatticeError, "found 2"):
            L.extract(thin(padded(LAT) + padded(LAT)))
        with self.assertRaisesRegex(L.LatticeError, "found 2"):
            L.extract(thin(padded(LAT) + padded(other_lattice())))

    def test_one_slice_short_fails(self):
        with self.assertRaisesRegex(L.LatticeError, "found 0"):
            L.extract(fat(thin(padded(LAT), cpu=CPU_X86_64), thin(b"\x11" * 2048)))

    def test_slices_that_disagree_fail(self):
        with self.assertRaisesRegex(L.LatticeError, "different"):
            L.extract(fat(thin(padded(LAT), cpu=CPU_X86_64), thin(padded(other_lattice()))))

    def test_damaged_candidate_is_not_a_match(self):
        damaged = bytearray(LAT)
        damaged[-8:] = struct.pack("<Q", 320)
        with self.assertRaisesRegex(L.LatticeError, "found 0"):
            L.extract(thin(padded(bytes(damaged))))

    def test_only_aligned_positions_count(self):
        with self.assertRaisesRegex(L.LatticeError, "found 0"):
            L.extract(thin(padded(LAT, before=20)))
        with self.assertRaisesRegex(L.LatticeError, "found 0"):
            L.extract(thin(padded(LAT), const_addr_skew=4))

    def test_only_text_const_counts(self):
        # The same table in __text is not a match.
        with self.assertRaisesRegex(L.LatticeError, "found 0"):
            L.extract(thin(b"\x11" * 64, text=padded(LAT)))
        # Truncated at the section's end is not a match either.
        with self.assertRaisesRegex(L.LatticeError, "found 0"):
            L.extract(thin(b"\x11" * 24 + LAT[:-8]))

    def test_section_shape_is_checked(self):
        with self.assertRaisesRegex(L.LatticeError, "one __TEXT,__const"):
            L.extract(thin(padded(LAT), const_sections=2))
        with self.assertRaisesRegex(L.LatticeError, "no file contents"):
            L.extract(thin(padded(LAT), const_flags=0x1))

    def test_malformed_images_fail(self):
        good = thin(padded(LAT))
        for image in (b"", b"\xcf\xfa\xed\xfe", good[:200], b"\x7fELF" + good[4:],
                      fat(good)[:16]):
            with self.assertRaises(L.LatticeError):
                L.extract(image)
        broken = bytearray(good)
        struct.pack_into("<I", broken, 20, 10_000)   # sizeofcmds past the file
        with self.assertRaises(L.LatticeError):
            L.extract(bytes(broken))
        overlapping = bytearray(fat(good, good))
        struct.pack_into(">I", overlapping, 8 + 20 + 8, struct.unpack_from(">I", overlapping, 16)[0])
        with self.assertRaises(L.LatticeError):
            L.extract(bytes(overlapping))

    def test_read_refuses_links_and_missing_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "AudioDSP"
            with self.assertRaisesRegex(L.LatticeError, "cannot open"):
                L.read(str(path))
            path.write_bytes(thin(padded(LAT)))
            self.assertEqual(L.read(str(path)), LAT)
            link = pathlib.Path(tmp) / "link"
            os.symlink(path, link)
            with self.assertRaises(L.LatticeError):
                L.read(str(link))

    def test_cli_never_prints_the_table(self):
        import contextlib
        import io
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "AudioDSP"
            path.write_bytes(fat(thin(padded(LAT), cpu=CPU_X86_64), thin(padded(LAT))))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(L.main([str(path)]), 0)
            text = out.getvalue()
            self.assertIn("PASS 2 slice(s)", text)
            self.assertNotIn(str(L.ends(LAT)[60:70])[1:-1], text)
            self.assertNotIn(LAT.hex()[:64], text)
            path.write_bytes(thin(b"\x11" * 64))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(L.main([str(path)]), 1)


if __name__ == "__main__":
    unittest.main()
