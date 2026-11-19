# SPDX-License-Identifier: MIT
"""BCM4388 rev C2 Wi-Fi collection from 26.6.2 (25G83)-shaped trees.

Recovery's C-4388__s-C2 holds only aruba NVRAM and regulatory data, and its
aruba.trx names a paradise.trx the image does not ship. The installed system
volume holds every board, with hostomel.trx and mriya.trx naming guam.trx.
"""
import os
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from aurora_firmware.wifi import WiFiFWCollection  # noqa: E402

SKUS = ("ID", "X0", "X2", "X3")
FIRMWARE = b"synthetic C2 firmware"


def recovery_25g83(root):
    c2 = root / "C-4388__s-C2"
    c2.mkdir(parents=True)
    for vendor in ("a", "u"):
        name = f"P-aruba_M-WLMT_V-{vendor}__m-4.9.txt"
        (c2 / name).write_bytes(b"boardrev=0x1\n")
        for sku in SKUS:
            os.symlink(name, c2 / f"P-aruba-{sku}_M-WLMT_V-{vendor}__m-4.9.txt")
    (c2 / "aruba.clmb").write_bytes(b"aruba clm")
    os.symlink("paradise.trx", c2 / "aruba.trx")
    for sku in SKUS:
        os.symlink("aruba.trx", c2 / f"aruba-{sku}.trx")
        os.symlink("aruba.clmb", c2 / f"aruba-{sku}.clmb")


def installed_system(root, boards=("hostomel", "mriya")):
    c2 = root / "C-4388__s-C2"
    c2.mkdir(parents=True)
    (c2 / "guam.trx").write_bytes(FIRMWARE)
    for board in boards:
        os.symlink("guam.trx", c2 / f"{board}.trx")
        (c2 / f"{board}.clmb").write_bytes(f"{board} clm".encode())
        for vendor in ("a", "u"):
            name = f"P-{board}_M-WLMT_V-{vendor}__m-4.9.txt"
            (c2 / name).write_bytes(f"vendor={vendor}\n".encode())
            for sku in SKUS:
                os.symlink(name, c2 / f"P-{board}-{sku}_M-WLMT_V-{vendor}__m-4.9.txt")
        for sku in SKUS:
            os.symlink(f"{board}.trx", c2 / f"{board}-{sku}.trx")
            os.symlink(f"{board}.clmb", c2 / f"{board}-{sku}.clmb")


def collect(root):
    return {name: fw.data for name, fw in WiFiFWCollection(str(root)).files()}


class C2WiFiCollection(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_recovery_dangling_alias_is_skipped_not_fatal(self):
        recovery_25g83(self.root)
        files = collect(self.root)
        self.assertFalse([n for n in files if n.endswith(".bin")], files.keys())
        self.assertIn("brcm/brcmfmac4388c2-pcie.apple,aruba.clm_blob", files)

    def test_installed_system_c2_directory_is_collected(self):
        installed_system(self.root)
        files = collect(self.root)
        for board in ("hostomel", "mriya"):
            prefix = f"brcm/brcmfmac4388c2-pcie.apple,{board}"
            self.assertEqual(files[prefix + ".bin"], FIRMWARE)
            self.assertIn(prefix + ".clm_blob", files)
            self.assertIn(prefix + "-WLMT-a.txt", files)
            self.assertIn(prefix + "-WLMT-u.txt", files)


if __name__ == "__main__":
    unittest.main()
