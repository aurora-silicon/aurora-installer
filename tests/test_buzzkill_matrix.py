# SPDX-License-Identifier: MIT
"""The BuzzKill quadrature matrix locator, on synthetic Mach-O images only."""
import pathlib
import struct
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from asahi_firmware import buzzkill_matrix as M  # noqa: E402
from macho_fixtures import CPU_X86_64, fat, thin  # noqa: E402

# Made-up sections that only satisfy the structural rule. Not macOS's values.
SECTIONS = [
    (0.25, -0.5, 1.0, 0.125, 0.25),     # b2 = 1, b0 = a2, b1 != a1
    (0.375, -0.25, 1.0, -0.25, 0.375),  # exact allpass
    (0.75, 0.5, 1.0, 0.5, -0.125),      # b2 = 1, b1 = a1, b0 != a2
    (1.125, -1.875, 0.875, -1.75, 0.8125),  # none of the three
]
GUARD = [(0.5, -0.75, 1.0, -0.75, 0.5)] * 4   # four exact allpasses


def pack(sections):
    return struct.pack(f"<{5 * len(sections)}f", *[v for s in sections for v in s])


MATRIX = pack(SECTIONS)


def const(before=b"\x11" * 24, guard=GUARD, after=b"\x22" * 40):
    return before + MATRIX + pack(guard) + after


class RuleTest(unittest.TestCase):
    def test_synthetic_matrix_is_valid(self):
        self.assertTrue(M.valid(MATRIX, pack(GUARD)))
        self.assertEqual(M.sections(MATRIX)[3], SECTIONS[3])

    def test_each_condition_is_required(self):
        def bad(index, word, value):
            s = [list(x) for x in SECTIONS]
            s[index][word] = value
            return pack(s)
        self.assertFalse(M.valid(MATRIX[:-4]))
        self.assertFalse(M.valid(bad(0, 1, 0.125)))      # section 1 b1 == a1
        self.assertFalse(M.valid(bad(1, 1, -0.5)))       # section 2 not an allpass
        self.assertFalse(M.valid(bad(2, 0, -0.125)))     # section 3 b0 == a2
        self.assertFalse(M.valid(bad(3, 2, 1.0)))        # section 4 unit b2
        self.assertFalse(M.valid(bad(3, 4, 1.25)))       # unstable
        self.assertFalse(M.valid(bad(0, 2, float("nan"))))
        self.assertFalse(M.valid(MATRIX, pack([(0.5, -0.75, 1.0, -0.5, 0.5)] * 4)))  # guard not allpass
        with self.assertRaises(M.MatrixError):
            M.sections(b"\0" * 80)


class LocateTest(unittest.TestCase):
    def test_thin_and_universal_images(self):
        self.assertEqual(M.extract(thin(const())), MATRIX)
        image = fat(thin(const(), cpu=CPU_X86_64), thin(const(before=b"\x33" * 8)))
        self.assertEqual(M.extract(image), MATRIX)

    def test_missing_or_unguarded_matrix_fails(self):
        with self.assertRaisesRegex(M.MatrixError, "found 0"):
            M.extract(thin(b"\x11" * 2048))
        with self.assertRaisesRegex(M.MatrixError, "found 0"):
            M.extract(thin(b"\x11" * 24 + MATRIX + b"\x22" * 120))

    def test_ambiguous_matrix_fails(self):
        with self.assertRaisesRegex(M.MatrixError, "found 2"):
            M.extract(thin(const() + const()))

    def test_unaligned_matrix_is_not_found(self):
        with self.assertRaisesRegex(M.MatrixError, "found 0"):
            M.extract(thin(const(), const_addr_skew=2))

    def test_slices_that_disagree_fail(self):
        other = [list(x) for x in SECTIONS]
        other[3][0] = 1.25
        image = fat(thin(const(), cpu=CPU_X86_64),
                    thin(b"\x11" * 24 + pack(other) + pack(GUARD) + b"\x22" * 40))
        with self.assertRaisesRegex(M.MatrixError, "different"):
            M.extract(image)


if __name__ == "__main__":
    unittest.main()
