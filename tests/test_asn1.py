# SPDX-License-Identifier: MIT
"""DER decoder: malformed input is reported as asn1.Error."""
import pathlib, sys, unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from asahi_firmware import asn1  # noqa: E402


def read(data):
    decoder = asn1.Decoder()
    decoder.start(data)
    return decoder.read()


class Integer(unittest.TestCase):
    def test_values(self):
        for data, value in ((b"\x02\x01\x00", 0), (b"\x02\x01\x7f", 127),
                            (b"\x02\x02\x00\x80", 128), (b"\x02\x01\xff", -1),
                            (b"\x02\x02\xff\x7f", -129), (b"\x02\x03\x01\x00\x00", 65536)):
            tag, got = read(data)
            self.assertEqual(tag.nr, asn1.Numbers.Integer)
            self.assertEqual(got, value, data)

    def test_zero_length(self):
        with self.assertRaises(asn1.Error):
            read(b"\x02\x00")
        with self.assertRaises(asn1.Error):
            read(b"\x0a\x00")  # ENUMERATED shares the decoder

    def test_not_minimal(self):
        for data in (b"\x02\x02\x00\x7f", b"\x02\x02\xff\x80"):
            with self.assertRaises(asn1.Error):
                read(data)


class Malformed(unittest.TestCase):
    def test_tag_without_length(self):
        for data in (b"\x02", b"\x16", b"\x04"):
            decoder = asn1.Decoder()
            decoder.start(data)
            self.assertIsNotNone(decoder.peek())
            with self.assertRaises(asn1.Error):
                decoder.read()
            with self.assertRaises(asn1.Error):
                read(data)

    def test_enter_at_end_of_input(self):
        decoder = asn1.Decoder()
        decoder.start(b"")
        self.assertIsNone(decoder.peek())
        self.assertIsNone(decoder.read())
        with self.assertRaises(asn1.Error):
            decoder.enter()
        decoder = asn1.Decoder()
        decoder.start(b"\x30")
        with self.assertRaises(asn1.Error):
            decoder.enter()

    def test_truncated_value(self):
        for data in (b"\x02\x02\x01", b"\x04\x05abc", b"\x30\x82\x01"):
            with self.assertRaises(asn1.Error):
                read(data)

    def test_string_that_is_not_text(self):
        self.assertEqual(read(b"\x16\x04IM4P")[1], "IM4P")
        with self.assertRaises(asn1.Error):
            read(b"\x16\x02\xff\xfe")

    def test_end_of_input_inside_a_sequence(self):
        decoder = asn1.Decoder()
        decoder.start(b"\x30\x03\x02\x01\x05")
        decoder.enter()
        self.assertEqual(decoder.read()[1], 5)
        self.assertIsNone(decoder.peek())
        self.assertIsNone(decoder.read())


if __name__ == "__main__":
    unittest.main()
