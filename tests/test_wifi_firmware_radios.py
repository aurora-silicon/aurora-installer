# SPDX-License-Identifier: MIT
"""tools/wifi-firmware: Bluetooth and MediaTek MT7932 firmware of the installed macOS.

Synthetic files only: the MT7932 inputs are the native converter's test
vectors (macOS/Tests/NativeFirmwareFixtureSupport/Fixtures/
neo-conversion-vectors.json), so the Python conversion is checked against the
Swift one's expected outputs.
"""
import base64
import json
import os
import pathlib
import tarfile
import unittest

from test_wifi_firmware_refresh import BOARD, Case, FakeVol, make_esp, wifi_tree, awf
from asahi_firmware import mt7932
from asahi_firmware.core import FWFile, FWPackage

ROOT = pathlib.Path(__file__).resolve().parents[1]
VECTORS = json.loads((ROOT / "macOS/Tests/NativeFirmwareFixtureSupport/Fixtures/"
                      "neo-conversion-vectors.json").read_text())
RAW = {k: base64.b64decode(v) for k, v in VECTORS["rawFiles"].items()}
B0 = "MT7932B0_OS_TypeB_0.1.44.0_241001003711.bin"
B1 = "MT7932B1_OS_TypeB_0.1.133.0_260128190103.bin"
B1_NEW = "MT7932B1_OS_TypeB_2.0.177.0_260706180356.bin"
PTX = "MT7932_PTB_IzubaA_0.1.0.0_20251021141303.ptx"
BT_TRAILER = bytes([0x41, 0x4c, 0x50, 0x53, 0x8a, 0x10, 0x8a, 0x10])
PRIVATE = {"mediatek/mt7932/wcal.bin": b"BLOB wcal", "mediatek/mt7932/oca2.bin": b"BLOB oca2",
           "mediatek/j700-mt7932-btcal.bin": b"btcal", "mediatek/j700-mt7932-bdaddr.bin":
           b"\x01\x02\x03\x04\x05\x06"}


def bt_image(tag):
    return tag.encode().ljust(64, b"\1") + bytes(16) + BT_TRAILER + bytes(8)


def macos_mt7932(ram=None, b1=(B1, None), extra=None):
    """A System volume with the MT7932 Wi-Fi files (the dext) and Bluetooth files."""
    vol = FakeVol({}, build="25G83", version="26.6.2")
    for name in mt7932.WIFI_SOURCES:
        data = RAW["sunrise/" + name]
        if name == mt7932.RAM and ram is not None:
            data = ram
        vol._add(f"{mt7932.WIFI_DIR}/{name}", data)
    vol._add(f"{mt7932.WIFI_DIR}/IZUBA_TxPwrLimit_SAR.dat", b"not read")
    vol._add(f"{mt7932.BT_DIR}/{B0}", RAW["bluetooth/" + B0])
    vol._add(f"{mt7932.BT_DIR}/{b1[0]}", b1[1] or RAW["bluetooth/" + B1])
    vol._add(f"{mt7932.BT_DIR}/{PTX}", RAW["bluetooth/" + PTX])
    vol._add(f"{mt7932.BT_DIR}/BCM4387C2_PCIE_macOS_hokkaido_USI.bin", b"broadcom")
    for path, data in (extra or {}).items():
        vol._add(path, data)
    return awf.MacOS("/dev/fake", vol, "25G83", "26.6.2")


def neo_esp(root, files=None):
    """A J700 ESP as the native installer leaves it: the converted radio
    files, this Mac's calibration (private), a policy and the camera."""
    esp = pathlib.Path(root) / "esp"
    (esp / "vendorfw").mkdir(parents=True)
    pkg = FWPackage(str(esp / "vendorfw"))
    if files is None:
        files = {
            mt7932.OUT_PATCH: RAW["sunrise/" + mt7932.PATCH],
            mt7932.OUT_RAM: RAW["sunrise/" + mt7932.RAM],
            mt7932.OUT_PPR: RAW["sunrise/" + mt7932.PPR],
            mt7932.OUT_CONFIG: mt7932.configuration(RAW["sunrise/" + mt7932.CONFIG]),
            "mediatek/" + B0: RAW["bluetooth/" + B0],
            "mediatek/" + B1: RAW["bluetooth/" + B1],
            "mediatek/" + PTX: RAW["bluetooth/" + PTX],
        }
    for name, data in sorted(files.items()):
        pkg.add_file(name, FWFile(name, data))
    for name, data in sorted(PRIVATE.items()):
        pkg.add_file(name, FWFile(name, data), mode=0o600)
    pkg.add_file("mediatek/mt7932/policy/world-XZ.bin", FWFile("p", b"J7RP world"))
    pkg.add_file("apple/isp_1921_01XX.dat", FWFile("c", b"camera"))
    pkg.close()
    return esp


def members(esp):
    with tarfile.open(esp / "vendorfw" / "firmware.tar") as tar:
        out = {}
        for m in tar.getmembers():
            src = m
            while src.islnk():
                src = tar.getmember(src.linkname)
            out[m.name] = (src.mode, tar.extractfile(src).read())
        return out


class ConversionTest(unittest.TestCase):
    def test_matches_the_native_converter(self):
        want = VECTORS["outputSHA256"]
        cfg = mt7932.configuration(RAW["sunrise/" + mt7932.CONFIG])
        self.assertEqual(awf.sha256(cfg), want[mt7932.OUT_CONFIG])

    def test_collection_names_and_aliases(self):
        vol = macos_mt7932()
        tmp = self.enterContext(__import__("tempfile").TemporaryDirectory())
        w, b = pathlib.Path(tmp, "w"), pathlib.Path(tmp, "b")
        awf.stage_tree(vol.volume, mt7932.WIFI_DIR, w, lambda r: r in mt7932.WIFI_SOURCES)
        awf.stage_tree(vol.volume, mt7932.BT_DIR, b, lambda r: r.startswith("MT7932"))
        self.assertFalse((w / "IZUBA_TxPwrLimit_SAR.dat").exists())
        files = dict(mt7932.MT7932FWCollection(w, b).files())
        want = VECTORS["outputSHA256"]
        for name in (mt7932.OUT_PATCH, mt7932.OUT_RAM, mt7932.OUT_PPR, mt7932.OUT_CONFIG,
                     "mediatek/" + B0, "mediatek/" + B1, "mediatek/" + PTX):
            self.assertEqual(files[name].sha, want[name], name)
        self.assertEqual(files[mt7932.ALIAS_B1].sha, want["mediatek/" + B1])
        self.assertEqual(files[mt7932.ALIAS_B0].sha, want["mediatek/" + B0])
        self.assertEqual(files[mt7932.ALIAS_PTX].sha, want["mediatek/" + PTX])
        self.assertTrue(all(mt7932.owned(n) for n in files))
        for n in PRIVATE:
            self.assertFalse(mt7932.owned(n), n)
        self.assertFalse(mt7932.owned("mediatek/mt7932/policy/world-XZ.bin"))

    def test_newest_bluetooth_image_is_the_alias(self):
        tmp = pathlib.Path(self.enterContext(__import__("tempfile").TemporaryDirectory()))
        for n in mt7932.WIFI_SOURCES:
            (tmp / n).write_bytes(RAW["sunrise/" + n])
        for n, d in ((B0, RAW["bluetooth/" + B0]), (B1, bt_image("old")),
                     (B1_NEW, bt_image("new")), (PTX, RAW["bluetooth/" + PTX])):
            (tmp / n).write_bytes(d)
        files = dict(mt7932.MT7932FWCollection(tmp, tmp).files())
        self.assertEqual(files[mt7932.ALIAS_B1].data, bt_image("new"))
        self.assertIn("mediatek/" + B1, files)

    def test_refuses_what_the_driver_refuses(self):
        cfg = RAW["sunrise/" + mt7932.CONFIG]
        with self.assertRaisesRegex(mt7932.Invalid, "settings are missing"):
            mt7932.configuration(b"\n".join(cfg.splitlines()[:-3]))
        with self.assertRaisesRegex(mt7932.Invalid, "PTX"):
            mt7932.validate_ptx(RAW["bluetooth/" + PTX][:-1])
        with self.assertRaisesRegex(mt7932.Invalid, "trailer"):
            mt7932.validate_bluetooth(b"x" * 64)
        with self.assertRaisesRegex(mt7932.Invalid, "PPR"):
            mt7932.validate_ppr(b"BLOB")


class MT7932UpdateTest(Case):
    def update(self, esp, macos, **kw):
        kw.setdefault("probe", lambda name, text: True)
        return awf.update(esp, macos, None, backup_root=self.backups, state_dir=self.state,
                          out=self.out.append, swap=lambda a, b: False, log_text="", **kw)

    def test_new_macos_replaces_the_set_and_keeps_this_macs_records(self):
        esp = neo_esp(self.root)
        before = members(esp)
        mac = macos_mt7932(ram=b"new RAM image", b1=(B1_NEW, bt_image("b1 2.0")))
        self.assertEqual(self.update(esp, mac), "updated")
        after = members(esp)
        self.assertEqual(after[mt7932.OUT_RAM][1], b"new RAM image")
        self.assertEqual(after["mediatek/" + B1_NEW][1], bt_image("b1 2.0"))
        self.assertEqual(after[mt7932.ALIAS_B1][1], bt_image("b1 2.0"))
        self.assertNotIn("mediatek/" + B1, after)
        for name in list(PRIVATE) + ["mediatek/mt7932/policy/world-XZ.bin",
                                     "apple/isp_1921_01XX.dat"]:
            self.assertEqual(after[name], before[name], name)
        for name in PRIVATE:
            self.assertEqual(after[name][0], 0o600, name)
        # Broadcom files on the same macOS volume are not this Mac's.
        self.assertFalse(any(n.startswith("brcm/") for n in after))
        st = awf.read_state(self.state)
        self.assertEqual(st["pending"]["parts"], ["mt7932"])
        self.assertEqual(st["pending"]["probes"], ["hci:mt7932_bt_pcie", "net:mt7932-fullmac"])
        self.assertEqual(set(st["pending"]["expect"]), {mt7932.OUT_RAM, mt7932.ALIAS_B1})
        self.assertEqual(self.update(esp, mac), "identical")

    def test_aliases_alone_are_a_change_once(self):
        esp = neo_esp(self.root)
        self.assertEqual(self.update(esp, macos_mt7932(), dry_run=True), "dry-run")
        self.assertEqual(self.update(esp, macos_mt7932()), "updated")
        self.assertIn(mt7932.ALIAS_B1, members(esp))
        self.assertEqual(self.update(esp, macos_mt7932()), "identical")

    def test_only_drivers_up_before_are_required(self):
        esp = neo_esp(self.root)
        self.update(esp, macos_mt7932(ram=b"new"),
                    probe=lambda name, text: name.startswith("net:"))
        self.assertEqual(awf.read_state(self.state)["pending"]["probes"], ["net:mt7932-fullmac"])

    def test_refuses_a_set_that_does_not_convert(self):
        esp = neo_esp(self.root)
        before = awf.tree_hashes(esp)
        mac = macos_mt7932(b1=(B1, b"no trailer"))
        with self.assertRaisesRegex(awf.Refused, "does not convert"):
            self.update(esp, mac)
        self.assertEqual(awf.tree_hashes(esp), before)

    def test_macos_without_the_driver_leaves_the_esp(self):
        esp = neo_esp(self.root)
        vol = FakeVol({}, build="27A1")
        with self.assertRaisesRegex(awf.Refused, "ships none"):
            self.update(esp, awf.MacOS("/dev/fake", vol, "27A1", "27.0"))


class MT7932VerifyTest(Case):
    def changed(self):
        esp = neo_esp(self.root)
        self.old = awf.tree_hashes(esp)
        awf.update(esp, macos_mt7932(ram=b"new RAM image"), None, backup_root=self.backups,
                   state_dir=self.state, out=self.out.append, swap=lambda a, b: False,
                   probe=lambda n, t: True, log_text="")
        st = awf.read_state(self.state)
        st["pending"]["boot_id"] = "an earlier boot"
        return esp, st

    def verify(self, esp, st, text="", probe=lambda n, t: True):
        return awf.verify(st, esp, out=self.out.append, log_text=text, wait=0,
                          unpacked_sha=lambda n: st["pending"]["expect"][n], probe=probe,
                          state_dir=self.state, swap=lambda a, b: False)

    def test_up_is_verified(self):
        esp, st = self.changed()
        self.assertEqual(self.verify(esp, st), "ok")
        st = awf.read_state(self.state)
        self.assertEqual(st["result"], "verified")
        self.assertEqual(st["esp_wifi"], awf.esp_wifi_digest(esp))

    def test_bluetooth_down_reverts(self):
        esp, st = self.changed()
        r = self.verify(esp, st, probe=lambda n, t: not n.startswith("hci:"))
        self.assertEqual(r, "reverted")
        self.assertEqual(awf.tree_hashes(esp), self.old)
        self.assertIn("hci:mt7932_bt_pcie did not come up", self.out[-2])

    def test_firmware_gate_failure_reverts(self):
        esp, st = self.changed()
        text = "mt7932-fullmac 0000:01:00.0: FIRMWARE_GATE_FAILED: phase=x error=-22\n"
        self.assertEqual(self.verify(esp, st, text), "reverted")
        self.assertEqual(awf.tree_hashes(esp), self.old)

    def test_other_drivers_words_do_not_count(self):
        esp, st = self.changed()
        text = "some-driver 0000:02:00.0: Direct firmware load for mediatek/x failed\n"
        self.assertEqual(self.verify(esp, st, text), "ok")


class BroadcomBluetoothTest(Case):
    BT = {"BCM4387C2_19.3.395.4044_PCIE_macOS_hokkaido_CLPC_OS_USI_20250101.bin": b"bt new",
          "BCM4387C2_19.3.395.4044_PCIE_macOS_hokkaido_CLPC_OS_USI_20250101.ptb": b"ptb new",
          "BCM4387C2_19.3.395.4044_PCIE_macOS_maldives_CLPC_OS_USI_20250101.bin": b"bt mal",
          "MT7932B0_OS_TypeB_0.1.44.0_241001003711.bin": b"mediatek"}

    def macos(self, tree, bt=None, **kw):
        mac = super().macos(tree, **kw)
        for name, data in (self.BT if bt is None else bt).items():
            mac.volume._add(f"{awf.BLUETOOTH}/{name}", data)
        return mac

    def update(self, esp, macos, **kw):
        kw.setdefault("probe", lambda name, text: True)
        return super().update(esp, macos, log_text="", **kw)

    def test_bluetooth_follows_with_wifi(self):
        tree = wifi_tree("old")
        esp = make_esp(self.root, tree)
        self.assertEqual(self.update(esp, self.macos(tree)), "updated")
        m = self.manifest(esp)
        self.assertEqual(m["brcm/brcmbt4387c2-apple,hokkaido-u.bin"], awf.sha256(b"bt new"))
        self.assertEqual(m["brcm/brcmbt4387c2-apple,hokkaido-u.ptb"], awf.sha256(b"ptb new"))
        self.assertEqual(m["brcm/brcmbt4387c2-apple,maldives-u.bin"], awf.sha256(b"bt mal"))
        self.assertEqual(m["apple/same-as-bt.bin"], awf.sha256(b"bluetooth"))
        raw = awf.raw_tree(esp / "asahi" / "all_firmware.tar.gz", awf.RAW_BT_PREFIX)
        self.assertEqual(set(raw), set(self.BT))
        self.assertEqual(awf.raw_wifi(esp / "asahi" / "all_firmware.tar.gz"),
                         awf.tree_digest(tree))
        st = awf.read_state(self.state)
        self.assertEqual(st["pending"]["parts"], ["wifi", "bluetooth"])
        self.assertEqual(st["pending"]["probes"], ["brcmfmac", "hci:hci_bcm4377"])
        self.assertEqual(st["pending"]["expect"]["brcm/brcmbt4387c2-apple,hokkaido-u.bin"],
                         awf.sha256(b"bt new"))
        self.assertEqual(self.update(esp, self.macos(tree)), "identical")

    def test_refuses_macos_without_this_boards_bluetooth(self):
        tree = wifi_tree("old")
        esp = make_esp(self.root, tree)
        before = awf.tree_hashes(esp)
        bt = {k: v for k, v in self.BT.items() if "hokkaido" not in k}
        with self.assertRaisesRegex(awf.Refused, "Bluetooth firmware lacks"):
            self.update(esp, self.macos(wifi_tree("new"), bt=bt))
        self.assertEqual(awf.tree_hashes(esp), before)

    def test_bluetooth_down_before_is_not_required(self):
        esp = make_esp(self.root, wifi_tree("old"))
        self.update(esp, self.macos(wifi_tree("new")), probe=lambda n, t: False)
        self.assertEqual(awf.read_state(self.state)["pending"]["probes"], ["brcmfmac"])


class OlderStateTest(Case):
    def test_a_change_from_the_wifi_only_tool_still_verifies(self):
        esp = make_esp(self.root, wifi_tree("old"))
        self.update(esp, self.macos(wifi_tree("new")))
        st = awf.read_state(self.state)
        name, sha = next(iter(st["pending"]["expect"].items()))
        st["pending"] = {"backup": st["pending"]["backup"], "expect": sha, "name": name,
                         "boot_id": "an earlier boot"}
        line = ("brcmfmac: brcmf_c_preinit_dcmds: Firmware: BCM4387/7 wl0: Sep 22 2025 "
                "version 20.131.4.0.8.7.215 FWID 01-45655c04\n")
        r = awf.verify(st, esp, out=self.out.append, log_text=line, wait=0,
                       unpacked_sha=lambda n: sha if n == name else None,
                       state_dir=self.state, swap=lambda a, b: False)
        self.assertEqual(r, "ok")


class ProbeTest(Case):
    def sysfs(self, cls, dev, driver):
        d = self.root / "sys" / "class" / cls / dev
        (self.root / "sys" / "bus" / driver).mkdir(parents=True, exist_ok=True)
        d.mkdir(parents=True)
        (d / "device").mkdir()
        os.symlink(self.root / "sys" / "bus" / driver, d / "device" / "driver")

    def test_probe_reads_sysfs(self):
        self.sysfs("net", "neo-wifi0", "mt7932-fullmac")
        self.sysfs("bluetooth", "hci0", "mt7932_bt_pcie")
        sys_root = self.root / "sys"
        self.assertTrue(awf.radio_probe("net:mt7932-fullmac", "", sys_root))
        self.assertFalse(awf.radio_probe("net:brcmfmac", "", sys_root))
        self.assertTrue(awf.radio_probe("hci:mt7932_bt_pcie", "", sys_root, up=lambda i: True))
        self.assertFalse(awf.radio_probe("hci:mt7932_bt_pcie", "", sys_root, up=lambda i: False))
        self.assertTrue(awf.radio_probe("hci:mt7932_bt_pcie", "", sys_root, up=lambda i: None))
        self.assertFalse(awf.radio_probe("hci:hci_bcm4377", "", sys_root, up=lambda i: True))


if __name__ == "__main__":
    unittest.main()
