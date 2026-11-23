# SPDX-License-Identifier: MIT
"""IM4P reader on synthetic containers: malformed headers and sizes are
refused with IM4PError before anything is allocated or decompressed."""
import ctypes, pathlib, subprocess, sys, unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from asahi_firmware import img4  # noqa: E402


def der_len(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def tlv(tag, body):
    return bytes([tag]) + der_len(len(body)) + body


def der_int(n):
    return tlv(0x02, n.to_bytes(n.bit_length() // 8 + 1, "big", signed=True))


def im4p(magic=b"IM4P", payload=b"x" * 16, raw_size=None, ctype=1, fields=None):
    if fields is None:
        fields = [tlv(0x16, magic), tlv(0x16, b"krnl"), tlv(0x16, b"v"), tlv(0x04, payload)]
    body = b"".join(fields)
    if raw_size is not None:
        body += tlv(0x30, der_int(ctype) + der_int(raw_size))
    return tlv(0x30, body)


# IM4PError is a ValueError; the limit is spelled out so that a change of
# the constant is a change of this file too.
MAX_RAW_SIZE = 512 << 20


class Header(unittest.TestCase):
    def refused(self, data):
        decode = mock.Mock(return_value=b"")
        with mock.patch.object(img4, "decode_lzfse", decode):
            with self.assertRaises(ValueError):
                img4.img4p_extract(data)
        decode.assert_not_called()

    def test_limit(self):
        self.assertEqual(img4.MAX_RAW_SIZE, MAX_RAW_SIZE)
        self.assertTrue(issubclass(img4.IM4PError, ValueError))

    def test_uncompressed_payload(self):
        self.assertEqual(img4.img4p_extract(im4p(payload=b"data")), ("krnl", b"data"))

    def test_compressed_payload_is_decoded_at_its_size(self):
        decode = mock.Mock(return_value=b"raw")
        with mock.patch.object(img4, "decode_lzfse", decode):
            self.assertEqual(img4.img4p_extract(im4p(payload=b"c", raw_size=3)), ("krnl", b"raw"))
        decode.assert_called_once_with(b"c", 3)

    def test_size_at_the_cap_is_accepted(self):
        decode = mock.Mock(return_value=b"")
        with mock.patch.object(img4, "decode_lzfse", decode):
            img4.img4p_extract(im4p(raw_size=MAX_RAW_SIZE))
        decode.assert_called_once_with(b"x" * 16, MAX_RAW_SIZE)

    def test_size_over_the_cap(self):
        self.refused(im4p(raw_size=MAX_RAW_SIZE + 1))
        self.refused(im4p(raw_size=1 << 46))
        self.refused(im4p(raw_size=1 << 70))

    def test_negative_size(self):
        self.refused(im4p(raw_size=-5))

    def test_other_compression_type(self):
        self.refused(im4p(raw_size=16, ctype=2))

    def test_wrong_magic(self):
        self.refused(im4p(magic=b"IM4X"))

    def test_wrong_field_types(self):
        good = [tlv(0x16, b"IM4P"), tlv(0x16, b"krnl"), tlv(0x16, b"v"), tlv(0x04, b"data")]
        for i in range(len(good)):
            fields = list(good)
            fields[i] = der_int(7)
            self.refused(im4p(fields=fields))
            self.refused(im4p(fields=good[:i]))

    def test_not_a_container(self):
        for data in (b"", b"\x30", b"\x04\x02ab", b"\x02\x00", b"\x30\x80", b"\xff" * 8,
                     im4p()[:-3], tlv(0x30, tlv(0x16, b"IM\xff\xfe"))):
            self.refused(data)

    def test_compression_info_is_not_a_sequence(self):
        self.refused(tlv(0x30, im4p()[2:] + der_int(1)))
        self.refused(tlv(0x30, im4p()[2:] + tlv(0x30, der_int(1))))
        self.refused(tlv(0x30, im4p()[2:] + tlv(0x30, tlv(0x04, b"x") + der_int(4))))

    def test_header_checks_do_not_depend_on_assert(self):
        code = ("import sys; sys.path.insert(0, sys.argv[1])\n"
                "from asahi_firmware import img4\n"
                "try:\n"
                "    img4.img4p_extract(bytes.fromhex(sys.argv[2]))\n"
                "except ValueError:\n"
                "    sys.exit(7)\n")
        run = subprocess.run([sys.executable, "-O", "-c", code, str(ROOT), im4p(magic=b"IM4X").hex()],
                             capture_output=True, text=True)
        self.assertEqual(run.returncode, 7, run.stderr)


class FakeLibrary:
    """Stands in for liblzfse / libcompression: records how it is called."""

    def __init__(self, result=None):
        self.calls = []
        function = mock.Mock(side_effect=self.call)
        function.argtypes = None
        function.restype = ctypes.c_int
        self.function = function
        self.lzfse_decode_buffer = function
        self.compression_decode_buffer = function
        self.result = result

    def call(self, dest, size, *rest):
        self.calls.append((dest, size) + rest)
        return size if self.result is None else self.result


class Decode(unittest.TestCase):
    DECODERS = ("decode_lzfse_liblzfse", "decode_lzfse_darwin")

    def run_decoder(self, name, raw_size, result=None):
        library = FakeLibrary(result)
        with mock.patch.object(img4, "CDLL", return_value=library), \
                mock.patch.object(img4, "create_string_buffer",
                                  side_effect=ctypes.create_string_buffer) as alloc:
            try:
                return getattr(img4, name)(b"compressed", raw_size), library, alloc
            except Exception as e:
                return e, library, alloc

    def test_sizes_are_passed_as_size_t(self):
        for name in self.DECODERS:
            out, library, _ = self.run_decoder(name, 32)
            self.assertEqual(out, bytes(32))
            self.assertEqual(library.function.restype, ctypes.c_size_t, name)
            argtypes = library.function.argtypes
            self.assertIsNotNone(argtypes, name)
            self.assertEqual(argtypes[1], ctypes.c_size_t, name)
            self.assertEqual(argtypes[3], ctypes.c_size_t, name)
            self.assertEqual(library.calls[0][1], 32)
            self.assertEqual(library.calls[0][3], len(b"compressed"))

    def test_bad_sizes_allocate_nothing(self):
        for name in self.DECODERS:
            for size in (-1, -5, MAX_RAW_SIZE + 1, 1 << 46):
                out, library, alloc = self.run_decoder(name, size)
                self.assertIsInstance(out, ValueError, (name, size))
                alloc.assert_not_called()
                self.assertEqual(library.calls, [])

    def test_short_output_is_an_error(self):
        for name in self.DECODERS:
            out, _, _ = self.run_decoder(name, 32, result=31)
            self.assertIsInstance(out, ValueError, name)
            out, _, _ = self.run_decoder(name, 32, result=0)
            self.assertIsInstance(out, ValueError, name)


if __name__ == "__main__":
    unittest.main()
