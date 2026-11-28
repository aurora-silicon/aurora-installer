# SPDX-License-Identifier: MIT
"""tools/wifi-firmware: the Apple N1 (Centauri) firmware of an existing install.

An install from before the installer wrote the N1 firmware (alpha 25 and
older) has none on its ESP. The tool takes the board's image and ticket from
the stub's restore image, as the native installer does. Synthetic image,
ticket and manifest only, no Apple files.
"""
import io
import pathlib
import plistlib
import tarfile
import tempfile
import unittest
from unittest import mock

from test_wifi_firmware_refresh import Case, FakeVol, awf
from test_centauri import IMAGE, TICKET
from asahi_firmware import centauri
from asahi_firmware.core import FWFile, FWPackage

MODEL = "k114s"
BUILD = "26B8125"
IMAGE_PATH = "Firmware/t2026macG2/Release/ftab.bin"
TICKET_PATH = "Firmware/Manifests/restore/macOS Customer/centauri/centauri.k114sap.im4m"
NAME = "apple/centauri/k114s-ftab.bin"


class FakeMember:
    def __init__(self, data):
        self.data, self.usize = data, len(data)

    def read(self, limit=64 << 20):
        return self.data[:limit]


def identity(device, variant, paths):
    return {"Info": {"DeviceClass": device, "Variant": variant},
            "Manifest": {f"Wireless1,Part{n}": {"Info": {"Path": p}} for n, p in enumerate(paths)}}


def restore_zip(build=BUILD, identities=None, members=None):
    if identities is None:
        identities = [identity("k114sap", "macOS Customer", [IMAGE_PATH, IMAGE_PATH]),
                      identity("k114sap", "Customer Erase Install (IPSW)", ["Firmware/other.bin"])]
    files = {IMAGE_PATH: IMAGE, TICKET_PATH: TICKET} if members is None else members
    files["BuildManifest.plist"] = plistlib.dumps(
        {"ProductBuildVersion": build, "ProductVersion": "27.2", "BuildIdentities": identities})
    z = type("Zip", (), {})()
    z.members = {k: FakeMember(v) for k, v in files.items()}
    return z


def n1_esp(root, extra=None):
    """A K114s ESP as alpha 25 left it: no N1 firmware, other files kept."""
    esp = pathlib.Path(root) / "esp"
    (esp / "asahi").mkdir(parents=True)
    with tarfile.open(esp / "asahi" / "all_firmware.tar.gz", "w:gz") as tar:
        other = tarfile.TarInfo("fud_firmware/k114s/kiwi.im4p")
        other.size = 4
        tar.addfile(other, io.BytesIO(b"kiwi"))
    (esp / "vendorfw").mkdir()
    pkg = FWPackage(str(esp / "vendorfw"))
    pkg.add_file("apple/tpmtfw-k114s.bin", FWFile("t", b"touch"))
    for name, data in sorted((extra or {}).items()):
        pkg.add_file(name, FWFile(name, data))
    pkg.close()
    return esp


def members(path):
    with tarfile.open(path) as tar:
        return {m.name: tar.extractfile(m).read() for m in tar.getmembers() if m.isfile()}


class N1UpdateTest(Case):
    def run_update(self, esp, z, **kw):
        mac = awf.MacOS(f"UniversalMac_27.2_{BUILD}_Restore.ipsw", FakeVol({}), BUILD, "27.2",
                        MODEL, url="https://example.invalid/r.ipsw")
        kw.setdefault("probe", lambda name, text: False)
        with mock.patch.object(awf, "has_n1", lambda dt=None: True), \
                mock.patch.object(awf, "mac_board", lambda dt=None: MODEL), \
                mock.patch.object(awf.remotezip, "RemoteZip", lambda url: z):
            return awf.update(esp, mac, None, backup_root=self.backups, state_dir=self.state,
                              out=self.out.append, swap=lambda a, b: False, log_text="", **kw)

    def test_an_install_without_n1_firmware_gets_it_from_the_restore_image(self):
        esp = n1_esp(self.root)
        self.assertEqual(self.run_update(esp, restore_zip(), dry_run=True), "dry-run")
        self.assertNotIn(NAME, members(esp / "vendorfw" / "firmware.tar"))
        self.assertEqual(self.run_update(esp, restore_zip()), "updated")
        vendor = members(esp / "vendorfw" / "firmware.tar")
        self.assertEqual(vendor[NAME], centauri.personalize(IMAGE, TICKET))
        self.assertEqual(vendor["apple/tpmtfw-k114s.bin"], b"touch")
        raw = members(esp / "asahi" / "all_firmware.tar.gz")
        self.assertEqual(raw["centauri/k114s/ftab.bin"], IMAGE)
        self.assertEqual(raw["centauri/k114s/centauri.k114sap.im4m"], TICKET)
        self.assertEqual(raw["fud_firmware/k114s/kiwi.im4p"], b"kiwi")
        st = awf.read_state(self.state)
        self.assertEqual(st["pending"]["parts"], ["centauri"])
        self.assertEqual(set(st["pending"]["expect"]), {NAME})
        self.assertEqual(self.run_update(esp, restore_zip()), "identical")

    def test_a_rebuild_from_all_firmware_gives_the_same_file(self):
        esp = n1_esp(self.root)
        self.run_update(esp, restore_zip())
        with tempfile.TemporaryDirectory() as tmp:
            with tarfile.open(esp / "asahi" / "all_firmware.tar.gz") as tar:
                tar.extractall(tmp, filter="data")
            got = dict(centauri.CentauriFWCollection(str(pathlib.Path(tmp, "centauri"))).files())
        self.assertEqual(got[NAME].data, members(esp / "vendorfw" / "firmware.tar")[NAME])

    def test_an_image_that_is_another_build_is_refused(self):
        esp = n1_esp(self.root)
        before = awf.tree_hashes(esp)
        with self.assertRaisesRegex(awf.Refused, "not 26B8125"):
            self.run_update(esp, restore_zip(build="26B8132"))
        self.assertEqual(awf.tree_hashes(esp), before)

    def test_a_restore_image_without_this_boards_n1_leaves_the_esp(self):
        esp = n1_esp(self.root)
        z = restore_zip(identities=[identity("j714sap", "macOS Customer", [IMAGE_PATH])])
        with self.assertRaisesRegex(awf.Refused, "ships none"):
            self.run_update(esp, z)
        self.assertIn("no N1 image for this board", "\n".join(self.out))

    def test_two_n1_images_are_refused(self):
        esp = n1_esp(self.root)
        z = restore_zip(identities=[identity("k114sap", "macOS Customer",
                                             [IMAGE_PATH, "Firmware/x/ftab.bin"])])
        with self.assertRaisesRegex(awf.Refused, "2 different N1 images"):
            self.run_update(esp, z)

    def test_a_missing_ticket_is_refused(self):
        esp = n1_esp(self.root)
        with self.assertRaisesRegex(awf.Refused, "has no Firmware/Manifests"):
            self.run_update(esp, restore_zip(members={IMAGE_PATH: IMAGE}))

    def test_an_image_the_driver_would_refuse_is_refused(self):
        esp = n1_esp(self.root)
        before = awf.tree_hashes(esp)
        with self.assertRaisesRegex(awf.Refused, "do not convert"):
            self.run_update(esp, restore_zip(members={IMAGE_PATH: b"not ftab" * 8,
                                                      TICKET_PATH: TICKET}))
        self.assertEqual(awf.tree_hashes(esp), before)

    def test_a_firmware_load_failure_is_a_failure(self):
        text = "centauri 0000:01:00.0: Direct firmware load for apple/centauri/k114s-ftab.bin failed"
        self.assertTrue(awf.failure(text, ["centauri"]))
        self.assertIsNone(awf.failure("centauri: link up", ["centauri"]))


class N1DeviceTreeTest(unittest.TestCase):
    def dt(self, files):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = pathlib.Path(tmp.name)
        for rel, data in files.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_bytes(data)
        return root

    def test_the_n1_is_found_without_a_board_table(self):
        self.assertTrue(awf.has_n1(self.dt({"soc/wlan/apple,centauri-platform-id": b"\0\x0a\x60\x50"})))
        self.assertTrue(awf.has_n1(self.dt({
            "soc/pcie/n1/compatible": b"apple,t8142-centauri-control\0pci106b,1900\0"})))
        self.assertTrue(awf.has_n1(self.dt({
            "soc/pcie/wifi/firmware-name": b"apple/centauri/j714s-ftab.bin\0"})))
        self.assertFalse(awf.has_n1(self.dt({"soc/wlan/compatible": b"pci14e4,4434\0"})))

    def test_radio_parts_adds_the_n1(self):
        parts = awf.radio_parts({}, None, model=MODEL, n1=True)
        self.assertEqual([p.key for p in parts], ["centauri"])
        self.assertEqual(awf.radio_parts({}, None, model=MODEL, n1=False), [])


if __name__ == "__main__":
    unittest.main()
