# SPDX-License-Identifier: MIT
"""The ProRes initialization-row locator, on synthetic Mach-O images only.

The images are built from scratch: made-up rows, made-up addresses and a few
hand-assembled instructions. Nothing here comes from macOS.
"""
import pathlib
import struct
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from asahi_firmware import prores as P  # noqa: E402

BASE = 0xFFFFFE0007000000
TEXT = BASE + 0x4000
CONST = BASE + 0x8000


def rows(count, seed):
    return [(i * 4 + 0x100, 0xFF << (i % 4 * 8), ((seed + i) % 0xFF) << (i % 4 * 8))
            for i in range(count)]


def standard(seed=1):
    # (family, number, rows, leading underscore on the table symbol)
    return [["scodec_sys", 3, rows(82, seed), True],
            ["prores", 5, rows(80, seed + 7), False],
            ["af_scodecaxi2af", 9, rows(62, seed + 13), True]]


# (family, number, soc, table index)
SELECTORS = [("scodec_sys", 3, 0x6041, 0), ("prores", 5, 0x6041, 1),
             ("af_scodecaxi2af", 9, 0x6041, 2)]


def segment(name, section, address, data, offset):
    return (struct.pack("<II16sQQQQiiII", 0x19, 152, name, address, len(data), offset,
                        len(data), 5, 5, 1, 0)
            + struct.pack("<16s16sQQIIIIIIII", section, name, address, len(data), offset,
                          0, 0, 0, 0, 0, 0, 0))


def image(tables, selectors, origin=0, filetype=0xB):
    const = bytearray()
    addresses = []
    for table in tables:
        addresses.append(CONST + len(const))
        const += bytes((len(table[2]) + 1) * 8)
    symbols, slots, gaps = [], bytearray(), 1
    for table in tables:
        for row in table[2]:
            # Pseudo-random gaps, so no shifted window of fig entries decodes.
            gaps = (gaps * 6364136223846793005 + 1442695040888963407) & (2**64 - 1)
            const += bytes(8 * (gaps >> 61))
            address = CONST + len(const)
            const += bytes(8)
            symbols.append(("_fig_%x_32_%x_%x_null" % row, 2, address))
            slots += struct.pack("<Q", address - BASE)
        slots += struct.pack("<Q", 0)  # the end: no fig entry at the base
    const[:len(slots)] = slots
    for table, address in zip(tables, addresses):
        prefix = "_" if table[3] else ""
        symbols.append((f"{prefix}tunableh_{table[0]}_figs_{table[1]}.figs", 2, address))
    text = bytearray()
    for family, number, soc, index in selectors:
        pc = TEXT + len(text)
        symbols.append((f"_tunableh_{family}_figs_{number}_apply_to", 1, pc))
        target = addresses[index]
        pages = ((target & ~0xFFF) - ((pc + 4) & ~0xFFF)) >> 12
        text += struct.pack("<IIII", 0x52800000 | (soc & 0xFFFF) << 5,
                            0x90000008 | (pages & 3) << 29 | ((pages >> 2) & 0x7FFFF) << 5,
                            0x91000108 | (target & 0xFFF) << 10, 0xD65F03C0)
    if not text:
        text += struct.pack("<I", 0xD65F03C0)
    strings, nlist = bytearray(b"\0"), bytearray()
    for name, section, value in symbols:
        nlist += struct.pack("<IBBHQ", len(strings), 0x0E, section, 0, value)
        strings += name.encode() + b"\0"
    symoff = origin + 0x2000 + ((len(const) + 0xFFF) & ~0xFFF)
    commands = (segment(b"__TEXT_EXEC", b"__text", TEXT, text, origin + 0x1000)
                + segment(b"__DATA_CONST", b"__const", CONST, const, origin + 0x2000)
                + struct.pack("<IIIIII", 2, 24, symoff, len(symbols), symoff + len(nlist),
                              len(strings)))
    out = bytearray(struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, filetype, 3,
                                len(commands), 0, 0) + commands)
    out += bytes(0x1000 - len(out)) + text
    out += bytes(0x2000 - len(out)) + const
    out += bytes(symoff - origin - len(out)) + nlist + strings
    return bytes(out)


def collection(entry, name="com.apple.driver.AppleProResHW"):
    identifier = name.encode() + b"\0"
    size = (32 + len(identifier) + 7) & ~7
    command = struct.pack("<IIQQII", 0x80000035, size, BASE, 0x4000, 32, 0) + identifier
    command += bytes(size - len(command))
    out = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 0xC, 1, len(command), 0, 0)
    out += command
    return out + bytes(0x4000 - len(out)) + entry


def expected(tables):
    out = bytearray(struct.pack("<4sIII", b"APRI", 1, 0x6041, 3))
    for index, table in enumerate(tables):
        out += struct.pack("<II", index + 1, len(table[2]))
        for row in table[2]:
            out += struct.pack("<III", *row)
    return bytes(out)


class ProResTest(unittest.TestCase):
    def test_thin_image(self):
        tables = standard()
        blob = P.extract(image(tables, SELECTORS))
        self.assertEqual(blob, expected(tables))
        self.assertEqual(len(blob), 2728)

    def test_kernel_collection_entry(self):
        tables = standard(40)
        self.assertEqual(P.extract(collection(image(tables, SELECTORS, origin=0x4000))),
                         expected(tables))

    def test_collection_without_the_kext(self):
        entry = image(standard(), SELECTORS, origin=0x4000)
        self.assertIsNone(P.extract(collection(entry, "com.apple.driver.Other")))

    def test_no_t6041_selector(self):
        selectors = [(f, n, 0x8140, i) for f, n, _s, i in SELECTORS]
        self.assertIsNone(P.extract(image(standard(), selectors)))

    def test_other_selectors_are_ignored(self):
        others = standard(90)
        for table in others:
            table[1] += 20
        selectors = SELECTORS + [(t[0], 30, 0x8112, i + 3) for i, t in enumerate(others)]
        tables = standard() + others
        self.assertEqual(P.extract(image(tables, selectors)), expected(tables[:3]))

    def test_damaged_table(self):
        tables = standard()
        offset, mask, _value = tables[1][2][10]
        tables[1][2][10] = (offset, mask, ~mask & 0xFFFFFFFF)
        with self.assertRaisesRegex(P.ProResError, "ProRes core: .* found 0"):
            P.extract(image(tables, SELECTORS))

    def test_wrong_count(self):
        tables = standard()
        tables[2][2].pop()
        with self.assertRaisesRegex(P.ProResError, "SCODEC wrapper: .* found 0"):
            P.extract(image(tables, SELECTORS))

    def test_duplicate_offset(self):
        tables = standard()
        tables[0][2][5] = (tables[0][2][4][0],) + tables[0][2][5][1:]
        with self.assertRaises(P.ProResError):
            P.extract(image(tables, SELECTORS))

    def test_two_t6041_tables(self):
        tables = standard() + [["prores", 6, rows(80, 77), True]]
        with self.assertRaisesRegex(P.ProResError, "ProRes core: .* found 2"):
            P.extract(image(tables, SELECTORS + [("prores", 6, 0x6041, 3)]))

    def test_missing_family(self):
        with self.assertRaises(P.ProResError):
            P.extract(image(standard(), SELECTORS[:2]))

    def test_truncated_input(self):
        with self.assertRaises(P.ProResError):
            P.extract(image(standard(), SELECTORS)[:0x1800])
        with self.assertRaises(P.ProResError):
            P.extract(b"\1\2\3")

    def test_failures_carry_no_row_data(self):
        tables = standard()
        tables[0][2][0] = (0x100, 0xFF, 0x12345678)
        with self.assertRaises(P.ProResError) as caught:
            P.extract(image(tables, SELECTORS))
        self.assertNotIn("12345678", str(caught.exception))

    def test_machines(self):
        self.assertIn("j616s", P.MACHINES)
        self.assertNotIn("j413", P.MACHINES)


if __name__ == "__main__":
    unittest.main()
