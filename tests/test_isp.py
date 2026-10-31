# SPDX-License-Identifier: MIT
import struct
import tarfile
import tempfile
import unittest
from pathlib import Path

from asahi_firmware.isp import ISPFWCollection, ISP_SETFILE_MAP
from asahi_firmware.core import FWPackage


def tuning(magic):
    entry = ISP_SETFILE_MAP[magic]
    data = bytearray(entry.file_size or entry.size)
    data[:32] = struct.pack('>8L', magic, 0x21000000, 0, 0,
                            0x01000000, 0x01000000, 0, 0x03c00000)
    data[-1] = 0x55
    return bytes(data)


class CameraExtractionTests(unittest.TestCase):
    def test_h17_extraction_fallback_and_package_round_trip(self):
        # Only synthetic inputs; no device calibration or vendor bytes.
        for magic in (0x19250306, 0x22240106):
            with self.subTest(magic=hex(magic)), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                daemon = root / 'usr/libexec/appleh16camerad'
                daemon.parent.mkdir(parents=True)
                source = tuning(magic)
                daemon.write_bytes(source + b'\xa5' * 64)
                collection = ISPFWCollection(root)
                self.assertEqual(collection.sources['appleh16camerad'], daemon.read_bytes())
                entry = ISP_SETFILE_MAP[magic]
                name = f'apple/isp_{entry.name}.dat'
                files = dict(collection.files())
                self.assertEqual(set(files), {name})
                result = files[name].data
                self.assertEqual(result[:len(source)], source)
                self.assertEqual(len(result) % 64, 0)
                self.assertEqual(result[len(source):], bytes(len(result) - len(source)))
                package = FWPackage(tmp)
                package.add_files(collection.files())
                package.close()
                with tarfile.open(root / 'firmware.tar') as archive:
                    self.assertEqual(archive.extractfile(name).read(), result)
                # The updater reads the flattened device-local fallback inputs.
                (root / 'appleh16camerad').write_bytes(daemon.read_bytes())
                self.assertEqual(dict(ISPFWCollection(root).files())[name].data, result)

    def test_truncated_setfile_is_not_packaged(self):
        for magic in (0x19250306, 0x22240106):
            with self.subTest(magic=hex(magic)), tempfile.TemporaryDirectory() as tmp:
                source = Path(tmp) / 'appleh16camerad'
                source.write_bytes(tuning(magic)[:-1])
                self.assertEqual(ISPFWCollection(source).files(), [])

    def test_conflicting_sources_and_setfiles_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = tuning(0x22240106)
            (root / 'appleh13camerad').write_bytes(source)
            other = bytearray(source)
            other[-1] ^= 1
            (root / 'appleh16camerad').write_bytes(other)
            with self.assertRaisesRegex(ValueError, 'Conflicting camera sensor tuning'):
                ISPFWCollection(root)
            (root / 'appleh16camerad').unlink()
            duplicate = root / 'usr/libexec/appleh13camerad'
            duplicate.parent.mkdir(parents=True)
            duplicate.write_bytes(other)
            with self.assertRaisesRegex(ValueError, 'Conflicting camera daemon inputs'):
                ISPFWCollection(root)


if __name__ == '__main__':
    unittest.main()
