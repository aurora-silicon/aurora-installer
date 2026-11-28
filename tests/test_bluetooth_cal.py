# SPDX-License-Identifier: MIT
"""Bluetooth calibration from a synthetic factory record shaped like macOS's BWCl."""
import pathlib, sys, tempfile, unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from asahi_firmware.bluetooth_cal import (  # noqa: E402
    FILENAME, BluetoothCalFWCollection, FactoryError, bluetooth_calibration)


def der(tag, body):
    tag = bytes([tag]) if isinstance(tag, int) else tag
    n = len(body)
    if n < 0x80:
        return tag + bytes([n]) + body
    size = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return tag + bytes([0x80 | len(size)]) + size + body


def field(name, value):
    return der(0x30, der(0x02, name[::-1].encode()) + der(0x16, b".") + der(0x04, value))


def record(kind, fields):
    # The fields sit in a SET inside a private high-tag container, as in macOS's records.
    body = der(0x30, der(0x02, b"lCWB") + der(0x02, b"\x03\x00\x03\x00")
               + der(b"\xff\x85\x9a\xc1\x82\x59", der(0x31, b"".join(fields))))
    im4p = der(0x30, der(0x16, b"IM4P") + der(0x16, kind) + der(0x16, b"1.0") + der(0x04, body))
    return der(0x30, der(0x16, b"IMG4") + im4p)


CAL = b"BLOB" + bytes(range(256)) * 60


class BluetoothCalibrationTest(unittest.TestCase):
    def test_btbf_is_taken_from_a_bwcl_record(self):
        data = record(b"BWCl", [field("BTBF", CAL), field("WCAL", b"BLOB" + b"\0" * 64)])
        self.assertEqual(bluetooth_calibration(data), CAL)

    def test_another_record_type_is_refused(self):
        with self.assertRaises(FactoryError):
            bluetooth_calibration(record(b"BWC2", [field("BTBF", CAL)]))

    def test_a_value_that_is_not_a_blob_is_refused(self):
        with self.assertRaises(FactoryError):
            bluetooth_calibration(record(b"BWCl", [field("BTBF", b"\0" * 64)]))

    def test_collection_names_the_kernel_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            (pathlib.Path(tmp) / "BWCl-sakhalin-4388-C2-a-0-0").write_bytes(
                record(b"BWCl", [field("BTBF", CAL)]))
            files = dict(BluetoothCalFWCollection(tmp).files())
        self.assertEqual(list(files), [FILENAME])
        self.assertEqual(files[FILENAME].data, CAL)


if __name__ == "__main__":
    unittest.main()
