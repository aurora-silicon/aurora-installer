# SPDX-License-Identifier: MIT
"""Bluetooth collector on synthetic file names shaped like macOS's."""
import pathlib, sys, tempfile, unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from asahi_firmware.bluetooth import BluetoothFWCollection  # noqa: E402

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


class BluetoothNamesTest(unittest.TestCase):
    """A file whose name does not parse is left out; the others are kept."""

    GOOD = "BCM4387C2_19.3.395.4044_PCIE_macOS_MAUI_CLPC_3ANT_OS_USI_20211013.bin"
    GOOD_NAMES = ["brcm/brcmbt4387c2-apple,maui-u.bin"]

    def collect(self, names, links=()):
        with tempfile.TemporaryDirectory() as tmp:
            for name in [self.GOOD] + list(names):
                (pathlib.Path(tmp) / name).write_bytes(b"synthetic " + name.encode())
            for name in links:
                (pathlib.Path(tmp) / name).symlink_to("absent.bin")
            with self.assertLogs("asahi_firmware.bluetooth", "WARNING") as logs:
                files = dict(BluetoothFWCollection(tmp).files())
        return sorted(files), logs.output

    def test_name_that_ends_at_the_bus(self):
        for name in ("BCM4387C2_PCIE.bin", "BCM4387C2_1.2_PCIE_macOS.bin",
                     "BCM4388C2_1.2_PCIE_macOS_Willamette.bin", "BCM4387C2_1.2_PCIE_.bin"):
            files, logs = self.collect([name])
            self.assertEqual(files, self.GOOD_NAMES, name)
            self.assertTrue(any("board type" in line for line in logs), (name, logs))

    def test_name_without_a_bus_or_chip(self):
        files, logs = self.collect(["BCM4387C2_1.2_USB_MAUI_USI.bin", "notes.bin"])
        self.assertEqual(files, self.GOOD_NAMES)

    def test_alias_without_a_file(self):
        files, logs = self.collect([], links=[
            "BCM4387C2_19.3.395.4044_PCIE_macOS_FIJI_CLPC_3ANT_OS_USI_20211013.bin"])
        self.assertEqual(files, self.GOOD_NAMES)
        self.assertTrue(any("FIJI" in line for line in logs), logs)


if __name__ == "__main__":
    unittest.main()
