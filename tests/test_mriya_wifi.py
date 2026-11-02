import tempfile
import unittest
from pathlib import Path

from asahi_firmware.wifi import WiFiFWCollection


class MriyaWiFiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.c2 = self.root / "C-4388__s-C2"
        self.c2.mkdir()

    def write_set(self):
        for ext in ("trx", "clmb", "txcb", "sig"):
            (self.c2 / f"mriya.{ext}").write_bytes(b"firmware")
        (self.c2 / "P-mriya-WLMT-a.txt").write_bytes(b"board=1\n")
        (self.c2 / "P-mriya-WLMT-u.txt").write_bytes(b"board=2\n")

    def converted(self):
        return dict(WiFiFWCollection(str(self.root)).files())

    def test_complete_set_produces_j614s_firmware_and_excludes_other_c2(self):
        self.write_set()
        (self.c2 / "other.trx").write_bytes(b"other")
        prefix = "brcm/brcmfmac4388c2-pcie.apple,mriya"
        self.assertEqual(set(self.converted()), {
            prefix + ".bin", prefix + ".clm_blob", prefix + ".txcap_blob",
            prefix + ".sig", prefix + "-WLMT-a.txt", prefix + "-WLMT-u.txt",
        })

    def test_incomplete_empty_and_generic_files_do_not_complete_set(self):
        self.write_set()
        (self.c2 / "mriya.sig").unlink()
        (self.c2 / "mriya_gen.sig").write_bytes(b"generic")
        self.assertEqual(self.converted(), {})
        (self.c2 / "mriya.sig").touch()
        self.assertEqual(self.converted(), {})
        (self.c2 / "mriya.sig").write_bytes(b"firmware")
        (self.c2 / "P-mriya-WLMT-a.txt").unlink()
        (self.c2 / "P-mriya-WLMT-u.txt").unlink()
        (self.c2 / "P-mriya-_gen.txt").write_bytes(b"board=1\n")
        self.assertEqual(self.converted(), {})

    def test_identical_nvram_variants_can_be_pruned(self):
        self.write_set()
        (self.c2 / "P-mriya-WLMT-u.txt").write_bytes(b"board=1\n")
        self.assertIn("brcm/brcmfmac4388c2-pcie.apple,mriya.txt", self.converted())


if __name__ == "__main__":
    unittest.main()
