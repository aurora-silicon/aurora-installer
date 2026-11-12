# SPDX-License-Identifier: MIT
"""tools/wifi-firmware: the installed macOS's Wi-Fi firmware onto the ESP.

Synthetic trees only: a fake System volume with the apfs_ro reader's API, and
an ESP whose asahi/all_firmware.tar.gz and vendorfw/ come from this
repository's asahi_firmware, as an install writes them.
"""
import io
import json
import os
import pathlib
import sys
import tarfile
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools" / "wifi-firmware"))

import aurora_wifi_firmware as awf  # noqa: E402
from asahi_firmware.core import FWFile, FWPackage  # noqa: E402

BOARD = "hokkaido"


def wifi_tree(tag, boards=("hokkaido", "maldives")):
    """A raw /usr/share/firmware/wifi tree: {rel: bytes | ('link', target)}."""
    t = {}
    for b in boards:
        d = "C-4387__s-C2"
        t[f"{d}/{b}.trx"] = f"{tag} {b} firmware".encode()
        t[f"{d}/{b}.clmb"] = f"{tag} {b} clm".encode()
        t[f"{d}/{b}.txcb"] = f"{tag} {b} txcap".encode()
        t[f"{d}/P-{b}_M-YSBC_V-u__m-7.5.txt"] = f"boardrev=0x{len(tag):x}\nname={tag}\n".encode()
        t[f"{d}/{b}-X0.trx"] = ("link", f"{b}.trx")
    # Asahi's collection skips these directories.
    t["C-4387__s-C2/perf/hokkaido.trx"] = b"perf build"
    return t


class FakeVol:
    """The parts of apfs_ro.Volume the tool uses, over an in-memory tree."""

    def __init__(self, tree, name="Macintosh HD", group="11111111-2222-3333-4444-555555555555",
                 build="25C56", version="26.2"):
        self.name, self.group, self.role, self.encrypted = name, group, 1, False
        self.nodes = {2: ("dir", {})}
        self.next = 3
        plist = (b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
                 b"<key>ProductBuildVersion</key><string>" + build.encode() + b"</string>"
                 b"<key>ProductVersion</key><string>" + version.encode() + b"</string>"
                 b"</dict></plist>")
        self._add(awf.SYSTEM_VERSION, plist)
        self._dir(awf.WIFI)
        for rel, v in tree.items():
            self._add(f"{awf.WIFI}/{rel}", v)

    def _dir(self, path):
        ino = 2
        for part in path.split("/"):
            kids = self.nodes[ino][1]
            if part not in kids:
                kids[part] = self.next
                self.nodes[self.next] = ("dir", {})
                self.next += 1
            ino = kids[part]
        return ino

    def _add(self, path, v):
        parent, name = path.rsplit("/", 1)
        d = self._dir(parent)
        self.nodes[self.next] = ("link", v[1]) if isinstance(v, tuple) else ("file", v)
        self.nodes[d][1][name] = self.next
        self.next += 1

    def kind(self, ino):
        return {"dir": 4, "file": 8, "link": 10}[self.nodes[ino][0]]

    def resolve(self, path):
        ino = 2
        for part in [p for p in path.split("/") if p]:
            node = self.nodes[ino]
            if node[0] != "dir" or part not in node[1]:
                raise awf.apfs_ro.ApfsError(f"{path}: {part} not found")
            ino = node[1][part]
        return ino, self.kind(ino)

    def children(self, ino):
        return {n: (i, self.kind(i)) for n, i in self.nodes[ino][1].items()}

    def read_file(self, ino):
        return self.nodes[ino][1]

    def readlink(self, ino):
        return self.nodes[ino][1]


class FakeContainer:
    def __init__(self, vols):
        self.vols = vols

    def volumes(self):
        return self.vols


def raw_entries(tree):
    return awf.tar_entries(tree)


def make_esp(root, tree, extra_wifi=None):
    """An ESP as an install leaves it: all_firmware with firmware/wifi/ and
    bluetooth/, vendorfw built from it plus a non-Wi-Fi file and u-boot/."""
    esp = pathlib.Path(root) / "esp"
    (esp / "asahi").mkdir(parents=True)
    with tarfile.open(esp / "asahi" / "all_firmware.tar.gz", "w:gz") as tar:
        bt = tarfile.TarInfo("firmware/bluetooth/BCM4387C2_hokkaido.bin")
        bt.size = 9
        tar.addfile(bt, io.BytesIO(b"bluetooth"))
        for ti, fd in raw_entries(tree):
            tar.addfile(ti, fd)
        other = tarfile.TarInfo("fud_firmware/j413/mtfw.bin")
        other.size = 4
        tar.addfile(other, io.BytesIO(b"mtfw"))
    raw = pathlib.Path(root) / "raw"
    for rel, v in tree.items():
        p = raw / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(v, tuple):
            os.symlink(v[1], p)
        else:
            p.write_bytes(v)
    (esp / "vendorfw").mkdir()
    pkg = FWPackage(str(esp / "vendorfw"))
    pkg.add_files(sorted(awf.converted(raw).items()))
    pkg.add_files(sorted((extra_wifi or {}).items()))
    pkg.add_file("brcm/brcmbt4387c2-apple,hokkaido-u.bin", FWFile("bt", b"bluetooth"))
    pkg.add_file("asmedia/asm2214a-apple.bin", FWFile("asm", b"asmedia"))
    pkg.add_file("apple/same-as-bt.bin", FWFile("dup", b"bluetooth"))
    pkg.close()
    (esp / "asahi" / "stub_info.json").write_text(json.dumps({"vgid": "AAAAAAAA-0000-0000-0000-000000000000"}))
    return esp


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.state = self.root / "state"
        self.backups = self.root / "backups"
        self.out = []

    def tearDown(self):
        self.tmp.cleanup()

    def macos(self, tree, **kw):
        return awf.MacOS("/dev/fake", FakeVol(tree, **kw), kw.get("build", "25C56"),
                         kw.get("version", "26.2"))

    def update(self, esp, macos, **kw):
        return awf.update(esp, macos, BOARD, backup_root=self.backups, state_dir=self.state,
                          out=self.out.append, swap=lambda a, b: False, **kw)

    def manifest(self, esp):
        return awf.parse_manifest((esp / "vendorfw" / "manifest.txt").read_text("ascii"))


class UpdateTest(Case):
    def test_identical_does_nothing(self):
        tree = wifi_tree("old")
        esp = make_esp(self.root, tree)
        before = awf.tree_hashes(esp)
        self.assertEqual(self.update(esp, self.macos(tree)), "identical")
        self.assertEqual(awf.tree_hashes(esp), before)
        self.assertFalse(self.backups.exists())

    def test_newer_macos_replaces_only_wifi(self):
        esp = make_esp(self.root, wifi_tree("old"))
        old = self.manifest(esp)
        old_extras = awf.package_extras(esp / "vendorfw")
        new_tree = wifi_tree("new")
        self.assertEqual(self.update(esp, self.macos(new_tree)), "updated")
        new = self.manifest(esp)
        for k, v in old.items():
            if not k.startswith(awf.PKG_PREFIX):
                self.assertEqual(new[k], v, k)
        self.assertEqual(awf.package_extras(esp / "vendorfw"), old_extras)
        name = "brcm/brcmfmac4387c2-pcie.apple,hokkaido.bin"
        self.assertEqual(new[name], awf.sha256(b"new hokkaido firmware"))
        self.assertNotEqual(new[name], old[name])
        # all_firmware now carries the macOS tree, so a later rebuild agrees.
        self.assertEqual(awf.raw_wifi(esp / "asahi" / "all_firmware.tar.gz"),
                         awf.tree_digest(new_tree))
        with tarfile.open(esp / "asahi" / "all_firmware.tar.gz") as tar:
            names = tar.getnames()
        self.assertIn("firmware/bluetooth/BCM4387C2_hokkaido.bin", names)
        self.assertIn("fud_firmware/j413/mtfw.bin", names)
        # The cpio the boot unpacks holds the new file too.
        cpio = (esp / "vendorfw" / "firmware.cpio").read_bytes()
        self.assertIn(b"new hokkaido firmware", cpio)
        self.assertNotIn(b"old hokkaido firmware", cpio)
        # Backed up, and the next boot has something to verify.
        backups = list(self.backups.iterdir())
        self.assertEqual(len(backups), 1)
        self.assertEqual(awf.parse_manifest((backups[0] / "vendorfw" / "manifest.txt")
                                            .read_text("ascii")), old)
        st = awf.read_state(self.state)
        self.assertEqual(st["build"], "25C56")
        self.assertEqual(st["pending"]["expect"], new[name])
        # Running again changes nothing.
        self.assertEqual(self.update(esp, self.macos(new_tree)), "identical")

    def test_esp_digest_follows_the_wifi_set_only(self):
        esp = make_esp(self.root, wifi_tree("old"))
        before = awf.esp_wifi_digest(esp)
        self.assertIsNotNone(before)
        self.update(esp, self.macos(wifi_tree("new")))
        after = awf.esp_wifi_digest(esp)
        self.assertNotEqual(before, after)
        self.assertEqual(self.update(esp, self.macos(wifi_tree("new"))), "identical")
        self.assertEqual(awf.esp_wifi_digest(esp), after)

    def test_package_matches_a_full_rebuild(self):
        """vendorfw after the update equals what asahi_firmware builds from
        the updated tree (Wi-Fi first, then the rest)."""
        esp = make_esp(self.root, wifi_tree("old"))
        new_tree = wifi_tree("new")
        self.update(esp, self.macos(new_tree))
        ref = make_esp(self.root / "ref", new_tree)
        self.assertEqual((esp / "vendorfw" / "manifest.txt").read_text(),
                         (ref / "vendorfw" / "manifest.txt").read_text())

    def test_dry_run_changes_nothing(self):
        esp = make_esp(self.root, wifi_tree("old"))
        before = awf.tree_hashes(esp)
        self.assertEqual(self.update(esp, self.macos(wifi_tree("new")), dry_run=True), "dry-run")
        self.assertEqual(awf.tree_hashes(esp), before)
        self.assertEqual(awf.read_state(self.state), {})

    def test_refuses_macos_without_this_board(self):
        esp = make_esp(self.root, wifi_tree("old"))
        before = awf.tree_hashes(esp)
        with self.assertRaisesRegex(awf.Refused, "lacks this Mac's board"):
            self.update(esp, self.macos(wifi_tree("new", boards=("maldives",))))
        self.assertEqual(awf.tree_hashes(esp), before)

    def test_refuses_esp_without_board(self):
        esp = make_esp(self.root, wifi_tree("old", boards=("maldives",)))
        with self.assertRaisesRegex(awf.Refused, "no Wi-Fi firmware for this Mac's board"):
            self.update(esp, self.macos(wifi_tree("new")))

    def test_failed_swap_leaves_esp(self):
        esp = make_esp(self.root, wifi_tree("old"))
        before = awf.tree_hashes(esp)
        calls = []

        def bad_swap(a, b):
            calls.append(b)
            if str(b).endswith("vendorfw"):
                raise OSError("simulated failure")
            return False
        with self.assertRaisesRegex(awf.Refused, "undone"):
            awf.update(esp, self.macos(wifi_tree("new")), BOARD, backup_root=self.backups,
                       state_dir=self.state, out=self.out.append, swap=bad_swap)
        self.assertEqual(awf.tree_hashes(esp), before)
        self.assertFalse((esp / "vendorfw.new").exists())


class VerifyRevertTest(Case):
    def changed(self):
        esp = make_esp(self.root, wifi_tree("old"))
        old = awf.tree_hashes(esp)
        self.update(esp, self.macos(wifi_tree("new")))
        st = awf.read_state(self.state)
        st["pending"]["boot_id"] = "an earlier boot"
        awf.write_state(st, self.state)
        return esp, old, st

    UP_LINE = ("brcmfmac: brcmf_c_preinit_dcmds: Firmware: BCM4387/7 wl0: Sep 22 2025 22:41:34 "
               "version 20.131.4.0.8.7.215 FWID 01-45655c04\n")

    def test_verified_boot_clears_pending(self):
        esp, _, st = self.changed()
        r = awf.verify(st, esp, out=self.out.append, log_text=self.UP_LINE, wait=0,
                       unpacked_sha=lambda n: st["pending"]["expect"], state_dir=self.state,
                       swap=lambda a, b: False)
        self.assertEqual(r, "ok")
        st = awf.read_state(self.state)
        self.assertNotIn("pending", st)
        self.assertEqual(st["firmware"], "20.131.4.0.8.7.215")

    def test_dead_firmware_reverts(self):
        esp, old, st = self.changed()
        text = "brcmfmac 0000:01:00.0: brcmf_pcie_setup: Dongle setup failed\n"
        r = awf.verify(st, esp, out=self.out.append, log_text=text, wait=0,
                       unpacked_sha=lambda n: st["pending"]["expect"], state_dir=self.state,
                       swap=lambda a, b: False)
        self.assertEqual(r, "reverted")
        self.assertEqual(awf.tree_hashes(esp), old)
        self.assertEqual(awf.read_state(self.state)["refused_build"], "25C56")

    def test_no_report_reverts(self):
        esp, old, st = self.changed()
        r = awf.verify(st, esp, out=self.out.append, log_text="", wait=0,
                       unpacked_sha=lambda n: st["pending"]["expect"], state_dir=self.state,
                       swap=lambda a, b: False)
        self.assertEqual(r, "reverted")
        self.assertEqual(awf.tree_hashes(esp), old)

    def test_same_boot_waits(self):
        esp, _, st = self.changed()
        st["pending"]["boot_id"] = awf.boot_id()
        if st["pending"]["boot_id"] is None:
            self.skipTest("no boot_id here")
        self.assertEqual(awf.verify(st, esp, log_text="", wait=0, state_dir=self.state), "waiting")

    def test_revert_by_hand(self):
        esp, old, _ = self.changed()
        awf.revert(esp, out=self.out.append, swap=lambda a, b: False, backup_root=self.backups)
        self.assertEqual(awf.tree_hashes(esp), old)


class SelectionTest(Case):
    def test_newest_macos_and_not_the_stub(self):
        esp = make_esp(self.root, wifi_tree("old"))
        stub = FakeVol(wifi_tree("stub"), group="aaaaaaaa-0000-0000-0000-000000000000",
                       build="22G74", version="13.5")
        older = FakeVol(wifi_tree("older"), build="24G90", version="15.7")
        newer = FakeVol(wifi_tree("newer"), name="Macintosh HD - Data?", build="25C56")
        data = FakeVol({}, name="Data")
        data.encrypted = True
        found = awf.installed_macos(esp, devices=["a", "b"], opener=lambda d: FakeContainer(
            [stub, older, data] if d == "a" else [newer]))
        self.assertEqual([m.build for m in found], ["25C56", "24G90"])

    def test_board_from_device_tree(self):
        dt = self.root / "dt" / "soc" / "pcie@690000000" / "pci@0,0" / "wifi@0,0"
        dt.mkdir(parents=True)
        (dt / "brcm,board-type").write_bytes(b"apple,hokkaido\0")
        self.assertEqual(awf.wifi_board(self.root / "dt"), "hokkaido")
        self.assertIsNone(awf.wifi_board(self.root / "nothing"))

    def test_build_order(self):
        self.assertLess(awf.build_key("24G90"), awf.build_key("25C56"))
        self.assertLess(awf.build_key("25C56"), awf.build_key("25G83"))
        self.assertLess(awf.build_key("25G83"), awf.build_key("26A428"))


if __name__ == "__main__":
    unittest.main()
