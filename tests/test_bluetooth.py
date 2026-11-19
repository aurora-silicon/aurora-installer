# SPDX-License-Identifier: MIT
"""Bluetooth collector on synthetic file names shaped like macOS's."""
import pathlib, sys, tempfile, unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from aurora_firmware.bluetooth import BluetoothFWCollection  # noqa: E402

C2 = "BCM4388C2_24.1.240.1875_PCIE_macOS_Willamette_Hostomel_CLPC_3ANT_OS_{v}_20260618.bin"
C2_PTB = "BCM4388C2_EVTv3_PCIE_macOS_Willamette_Hostomel_CLPC_3ANT_OS_{v}_K_R_20240919.ptb"


class BluetoothVendorTest(unittest.TestCase):
    def collect(self, names):
        with tempfile.TemporaryDirectory() as tmp:
            for name in names:
                (pathlib.Path(tmp) / name).write_bytes(b"synthetic " + name.encode())
            return dict(BluetoothFWCollection(tmp).files())

    def test_amkor_and_usi_modules_both_get_their_files(self):
        files = self.collect([C2.format(v=v) for v in ("AMKOR", "USI")]
                             + [C2_PTB.format(v=v) for v in ("AMKOR", "USI")])
        self.assertEqual(sorted(files), [
            "brcm/brcmbt4388c2-apple,hostomel-a.bin", "brcm/brcmbt4388c2-apple,hostomel-a.ptb",
            "brcm/brcmbt4388c2-apple,hostomel-u.bin", "brcm/brcmbt4388c2-apple,hostomel-u.ptb"])
        self.assertIn(b"AMKOR", files["brcm/brcmbt4388c2-apple,hostomel-a.bin"].data)
        self.assertIn(b"USI", files["brcm/brcmbt4388c2-apple,hostomel-u.ptb"].data)

    def test_two_vendors_in_one_name_are_refused(self):
        self.assertEqual(self.collect([C2.format(v="AMKOR_USI")]), {})


if __name__ == "__main__":
    unittest.main()
