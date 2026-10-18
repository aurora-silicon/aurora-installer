"""Synthetic containers exercise validation; no original radio assets are shipped."""
from pathlib import Path
import io
import struct
import sys
import unittest
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
import omarchy_mt7932 as mt


def synthetic_policy(country='XZ'):
    alpha = country.encode('ascii')
    data = bytearray(b'J7RP\x01\x00' + alpha + b'\x02\x0d\x00\x00' + b'\x00' * 4)
    data.extend((b'\x00' * 4 + struct.pack('<I', 1) + b'\x00' * 320) * 2)
    for i in range(13):
        if 1 <= i <= 9:
            n = 5 if i in (2, 9) else 8
            if i == 2 and country == 'XZ': n = 6
            table = bytearray(44 + n * 122)
            table[:2] = b'\x03\x0a'
            table[4:8] = bytes([n, 1 if i <= 2 else 2, int(i in (2, 9)), 0])
            table[8:10] = alpha
            if country == 'XZ' and i <= 2:
                for j in range(n): table[44 + j * 122] = (i - 1) * 8 + j + 1
        else:
            k = i - 9 if i else 0
            table = bytearray((532, 144, 58, 265)[k])
            table[:2] = b'\x00\x02'
            table[7] = (5, 1, 4, 2)[k]
            if i == 10: table[8:10] = alpha
        struct.pack_into('<H', table, 2, len(table))
        data.extend(table)
    struct.pack_into('<I', data, 12, len(data))
    return bytes(data)


class PolicyTests(unittest.TestCase):
    def test_world_only_is_sufficient_without_relabeling_a_country(self):
        world = synthetic_policy()
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as archive:
            archive.writestr('installer-inputs/mt7932-policy/world-XZ.bin', world)
        with zipfile.ZipFile(stream) as archive:
            files = mt.collect_policy_inputs(archive, {'kind': 'original-j7rp-v1', 'files': {
                'world-XZ.bin': 'installer-inputs/mt7932-policy/world-XZ.bin'}})
        self.assertEqual(files, {'mediatek/mt7932/policy/world-XZ.bin': world})
        with self.assertRaises(mt.Mt7932Error): mt.validate_policy(world, 'US')

    def test_country_identity_and_bounded_lengths_are_validated(self):
        original = synthetic_policy('US')
        self.assertEqual(mt.validate_policy(original, 'US'), original)
        for offset, byte in [(4, 2), (6, ord('C')), (8, 4), (9, 12), (10, 1), (12, 0), (16, 1), (16 + 656 + 2, 0)]:
            data = bytearray(original); data[offset] = byte
            with self.subTest(offset=offset), self.assertRaises(mt.Mt7932Error): mt.validate_policy(bytes(data), 'US')
        for data in (original[:15], original[:-1], original + b'\x00'):
            with self.assertRaises(mt.Mt7932Error): mt.validate_policy(data, 'US')

    def test_policy_admission_rejects_missing_inputs_and_path_substitution(self):
        for contract in (None, {}, {'kind':'original-j7rp-v1','files':{}},
                         {'kind':'original-j7rp-v1','files':{'world-XZ.bin':'../US.bin'}}):
            with self.subTest(contract=contract), self.assertRaises(mt.Mt7932Error):
                mt.collect_policy_inputs(None, contract)

if __name__ == '__main__': unittest.main()
