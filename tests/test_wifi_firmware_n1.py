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


def identity(device, variant, paths, behavior="Erase", chip="0x6050", board="0x14"):
    return {"ApChipID": chip, "ApBoardID": board,
            "Info": {"DeviceClass": device, "Variant": variant, "RestoreBehavior": behavior},
            "Manifest": {f"Wireless1,Part{n}": {"Info": {"Path": p}} for n, p in enumerate(paths)}}


def restore_zip(build=BUILD, identities=None, members=None):
    if identities is None:
        identities = [identity("k114sap", "macOS Customer", [IMAGE_PATH, IMAGE_PATH]),
                      identity("k114sap", "Customer Erase Install (IPSW)", ["Firmware/other.bin"]),
                      identity("k114sap", "macOS Customer", ["Firmware/update.bin"], "Update"),
                      identity("k114cap", "macOS Customer", ["Firmware/k114c.bin"], board="0x04")]
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
    def run_update(self, esp, z, chip=0x6050, **kw):
        mac = awf.MacOS(f"UniversalMac_27.2_{BUILD}_Restore.ipsw", FakeVol({}), BUILD, "27.2",
                        MODEL, url="https://example.invalid/r.ipsw")
        kw.setdefault("probe", lambda name, text: False)
        with mock.patch.object(awf, "has_n1", lambda dt=None: True), \
                mock.patch.object(awf, "mac_board", lambda dt=None: MODEL), \
                mock.patch.object(awf, "mac_chip", lambda dt=None: chip), \
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
        # The N1 interface must come up at the next boot, though it was down.
        self.assertEqual(st["pending"]["probes"], [awf.CentauriN1.NET])
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

    def test_another_chips_identity_is_refused(self):
        esp = n1_esp(self.root)
        with self.assertRaisesRegex(awf.Refused, "chip 0x6050, not this Mac's \\(0x6040\\)"):
            self.run_update(esp, restore_zip(), chip=0x6040)
        with self.assertRaisesRegex(awf.Refused, "unknown"):
            self.run_update(esp, restore_zip(), chip=None)

    def test_only_an_update_identity_is_no_source(self):
        esp = n1_esp(self.root)
        z = restore_zip(identities=[identity("k114sap", "macOS Customer", [IMAGE_PATH], "Update")])
        with self.assertRaisesRegex(awf.Refused, "ships none"):
            self.run_update(esp, z)

    def test_two_matching_identities_are_refused(self):
        esp = n1_esp(self.root)
        z = restore_zip(identities=[identity("k114sap", "macOS Customer", [IMAGE_PATH]),
                                    identity("k114sap", "macOS Customer", [IMAGE_PATH])])
        with self.assertRaisesRegex(awf.Refused, "2 macOS Customer identities"):
            self.run_update(esp, z)

    def test_a_device_class_with_two_board_ids_is_refused(self):
        esp = n1_esp(self.root)
        z = restore_zip(identities=[
            identity("k114sap", "macOS Customer", [IMAGE_PATH]),
            identity("k114sap", "Customer Erase Install (IPSW)", [IMAGE_PATH], board="0x15")])
        with self.assertRaisesRegex(awf.Refused, "more than one board ID"):
            self.run_update(esp, z)

    def test_an_identity_without_a_valid_board_id_is_refused(self):
        for board in (None, "", "14", "0xzz"):
            esp = n1_esp(pathlib.Path(self.root) / str(board))
            before = awf.tree_hashes(esp)
            ident = identity("k114sap", "macOS Customer", [IMAGE_PATH])
            if board is None:
                del ident["ApBoardID"]
            else:
                ident["ApBoardID"] = board
            with self.assertRaisesRegex(awf.Refused, "without a valid board ID"):
                self.run_update(esp, restore_zip(identities=[ident]))
            self.assertEqual(awf.tree_hashes(esp), before, board)

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

    def changed(self):
        esp = n1_esp(self.root)
        self.old = awf.tree_hashes(esp)
        self.run_update(esp, restore_zip())
        st = awf.read_state(self.state)
        st["pending"]["boot_id"] = "an earlier boot"
        return esp, st

    def verify(self, esp, st, text="", probe=lambda n, t: True, wait=0, sleep=lambda s: None):
        return awf.verify(st, esp, out=self.out.append, log_text=text, wait=wait, sleep=sleep,
                          unpacked_sha=lambda n: st["pending"]["expect"][n], probe=probe,
                          state_dir=self.state, swap=lambda a, b: False)

    def test_the_n1_interface_up_is_verified(self):
        esp, st = self.changed()
        seen = []
        self.assertEqual(self.verify(esp, st, probe=lambda n, t: seen.append(n) or True), "ok")
        self.assertEqual(seen, [awf.CentauriN1.NET])
        self.assertEqual(awf.read_state(self.state)["result"], "verified")

    def test_no_n1_interface_reverts(self):
        esp, st = self.changed()
        self.assertEqual(self.verify(esp, st, probe=lambda n, t: False), "reverted")
        self.assertEqual(awf.tree_hashes(esp), self.old)
        self.assertIn(awf.CentauriN1.NET + " did not come up", self.out[-2])

    def test_a_late_n1_interface_is_waited_for(self):
        esp, st = self.changed()
        calls = []
        probe = lambda n, t: calls.append(n) or len(calls) >= 3  # noqa: E731
        self.assertEqual(self.verify(esp, st, probe=probe, wait=60), "ok")
        self.assertEqual(len(calls), 3)

    def test_a_firmware_load_failure_reverts(self):
        esp, st = self.changed()
        text = "apple_centauri_t6050 0000:01:00.0: Direct firmware load for apple/centauri/k114s-ftab.bin failed with error -2\n"
        self.assertEqual(self.verify(esp, st, text), "reverted")
        self.assertEqual(awf.tree_hashes(esp), self.old)

    def test_the_probe_takes_either_n1_driver(self):
        for driver in ("apple_centauri", "apple_centauri_t6050"):
            with tempfile.TemporaryDirectory() as tmp:
                sysfs = pathlib.Path(tmp)
                drv = sysfs / "bus" / "pci" / "drivers" / driver
                drv.mkdir(parents=True)
                dev = sysfs / "class" / "net" / "wlp1s0f0" / "device"
                dev.mkdir(parents=True)
                (dev / "driver").symlink_to(drv)
                self.assertTrue(awf.radio_probe(awf.CentauriN1.NET, "", sys_root=sysfs), driver)
                self.assertFalse(awf.radio_probe("net:brcmfmac_x", "", sys_root=sysfs))

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
