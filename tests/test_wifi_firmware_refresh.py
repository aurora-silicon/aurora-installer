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
import shutil
import tempfile
import types
import unittest
from unittest import mock

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


class Disk:
    """os.statvfs for an ESP of `size` bytes whose used space is what its
    files hold now, so files written or removed during a run count."""

    def __init__(self, esp, size):
        self.esp, self.size = pathlib.Path(esp), size

    def free(self):
        return max(0, self.size - awf.tree_size(self.esp))

    def statvfs(self, path):
        return types.SimpleNamespace(f_bavail=self.free(), f_frsize=1)

    def patch(self):
        return mock.patch.object(awf.os, "statvfs", side_effect=self.statvfs)


def needs(fn):
    """Runs fn() and returns what each require_space asked for, in order."""
    asked, real = [], awf.require_space

    def record(esp, need):
        asked.append(need)
        return real(esp, need)
    with mock.patch.object(awf, "require_space", side_effect=record):
        fn()
    return asked


def leave_new_copies(esp, pad=2 << 20):
    """What an interrupted commit leaves: vendorfw.new and
    all_firmware.tar.gz.new beside the current files."""
    shutil.copytree(esp / "vendorfw", esp / "vendorfw.new")
    (esp / "vendorfw.new" / "firmware.tar").write_bytes(os.urandom(pad))
    shutil.copyfile(esp / "asahi" / "all_firmware.tar.gz",
                    esp / "asahi" / "all_firmware.tar.gz.new")


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
        kw.setdefault("probe", lambda name, text: False)
        kw.setdefault("log_text", "")
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
        self.assertEqual(st["pending"]["expect"], {name: new[name]})
        self.assertEqual(st["pending"]["probes"], ["brcmfmac"])
        # Running again changes nothing.
        self.assertEqual(self.update(esp, self.macos(new_tree)), "identical")

    def test_files_no_converter_reads_are_not_a_change(self):
        # The installer takes its raw trees from the Recovery image, which
        # lacks files the System volume has and no converter reads.
        tree = wifi_tree("old")
        esp = make_esp(self.root, tree)
        before = awf.tree_hashes(esp)
        system = dict(tree, **{"BCM4350-Updater.hex": b"uart updater",
                               "C-4387__s-C2/hokkaido.msf": b"unused"})
        self.assertEqual(self.update(esp, self.macos(system)), "identical")
        self.assertEqual(awf.tree_hashes(esp), before)
        self.assertFalse(self.backups.exists())

    def test_raw_tree_that_converts_differently_is_rebuilt(self):
        # vendorfw already holds the new set, but all_firmware's raw tree
        # would rebuild the old one on Linux: that is a change.
        new_tree = wifi_tree("new")
        esp = make_esp(self.root / "esp-new", new_tree)
        old = make_esp(self.root / "esp-old", wifi_tree("old"))
        shutil.copyfile(old / "asahi" / "all_firmware.tar.gz",
                        esp / "asahi" / "all_firmware.tar.gz")
        self.assertEqual(self.update(esp, self.macos(new_tree)), "updated")
        self.assertEqual(awf.raw_wifi(esp / "asahi" / "all_firmware.tar.gz"),
                         awf.tree_digest(new_tree))
        self.assertEqual(self.update(esp, self.macos(new_tree)), "identical")

    def test_too_little_space_refuses_before_building_anything(self):
        esp = make_esp(self.root, wifi_tree("old"))
        before = awf.tree_hashes(esp)
        full = types.SimpleNamespace(f_bavail=0, f_frsize=4096)
        built = AssertionError("staged a package the ESP cannot hold")
        with mock.patch.object(awf.os, "statvfs", return_value=full), \
                mock.patch.object(awf, "rebuild_vendorfw", side_effect=built), \
                mock.patch.object(awf, "rebuild_all_firmware", side_effect=built):
            with self.assertRaises(awf.NoSpace) as refused:
                self.update(esp, self.macos(wifi_tree("new")))
        # The estimate is the size of the current package at least.
        self.assertGreaterEqual(refused.exception.need, awf.tree_size(esp / "vendorfw"))
        self.assertEqual(awf.tree_hashes(esp), before)
        self.assertFalse(self.backups.exists())

    def test_early_floor_does_not_count_an_all_firmware_that_shrinks(self):
        # A newer macOS that ships fewer raw files gives a smaller
        # all_firmware. Free space that fits the exact need must do.
        big = dict(wifi_tree("old"), **{"C-4387__s-C2/hokkaido.msf": os.urandom(6 << 20)})
        ref = make_esp(self.root / "ref", big)
        asked = needs(lambda: awf.update(ref, self.macos(wifi_tree("new")), BOARD,
                                         backup_root=self.root / "ref-backups",
                                         state_dir=self.root / "ref-state", out=self.out.append,
                                         swap=lambda a, b: False, probe=lambda n, t: False,
                                         log_text=""))
        self.assertEqual(len(asked), 2)
        floor, exact = asked
        self.assertLessEqual(floor, exact)
        esp = make_esp(self.root / "esp", big)
        all_fw = (esp / "asahi" / "all_firmware.tar.gz").stat().st_size
        # The floor this PR first had: the current all_firmware on top.
        self.assertGreater(awf.tree_size(esp / "vendorfw") + all_fw, exact)
        disk = Disk(esp, awf.tree_size(esp) + exact)
        with disk.patch():
            self.assertEqual(self.update(esp, self.macos(wifi_tree("new"))), "updated")
        self.assertLess((esp / "asahi" / "all_firmware.tar.gz").stat().st_size, all_fw)

    def test_new_copies_left_by_an_earlier_run_are_removed_first(self):
        esp = make_esp(self.root, wifi_tree("old"))
        ref = make_esp(self.root / "ref", wifi_tree("old"))
        exact = max(needs(lambda: awf.update(
            ref, self.macos(wifi_tree("new")), BOARD, backup_root=self.root / "ref-backups",
            state_dir=self.root / "ref-state", out=self.out.append, swap=lambda a, b: False,
            probe=lambda n, t: False, log_text="")))
        disk = Disk(esp, awf.tree_size(esp) + exact)
        leave_new_copies(esp)
        # The copies take the space the change needs.
        self.assertLess(disk.free(), exact)
        with disk.patch():
            # A dry run counts them as free and leaves them.
            self.assertEqual(self.update(esp, self.macos(wifi_tree("new")), dry_run=True),
                             "dry-run")
            self.assertTrue((esp / "vendorfw.new").exists())
            self.assertEqual(self.update(esp, self.macos(wifi_tree("new"))), "updated")
        self.assertEqual(awf.leftovers(esp), [])
        self.assertEqual(self.manifest(esp), self.manifest(ref) | self.manifest(esp))
        self.assertEqual(awf.raw_wifi(esp / "asahi" / "all_firmware.tar.gz"),
                         awf.tree_digest(wifi_tree("new")))

    def test_raw_tree_with_a_member_twice_reads_as_tar_extracts_it(self):
        tree = wifi_tree("old")
        esp = make_esp(self.root, tree)
        all_fw = esp / "asahi" / "all_firmware.tar.gz"
        with tarfile.open(all_fw, "r:gz") as src:
            members = [(m, src.extractfile(m).read() if m.isfile() else None) for m in src]
        dup = tarfile.TarInfo("firmware/wifi/C-4387__s-C2/hokkaido.trx")
        dup.size = 5
        with tarfile.open(all_fw, "w:gz") as dst:
            for m, data in members:
                if m.name == dup.name:
                    stale = tarfile.TarInfo(m.name)
                    stale.size = 5
                    dst.addfile(stale, io.BytesIO(b"stale"))
                dst.addfile(m, io.BytesIO(data) if data is not None else None)
        before = awf.tree_hashes(esp)
        self.assertEqual(self.update(esp, self.macos(tree)), "identical")
        self.assertEqual(awf.tree_hashes(esp), before)

    def hard_link_esp(self, member, linkname):
        """An ESP whose all_firmware stores member as a hard link to
        linkname, as the installer stores the copies of a file; the macOS
        tree has hokkaido-X1.trx, a second copy of hokkaido.trx."""
        tree = wifi_tree("old")
        tree["C-4387__s-C2/hokkaido-X1.trx"] = tree["C-4387__s-C2/hokkaido.trx"]
        esp = make_esp(self.root, tree)
        all_fw = esp / "asahi" / "all_firmware.tar.gz"
        with tarfile.open(all_fw, "r:gz") as src:
            members = [(m, src.extractfile(m).read() if m.isfile() else None) for m in src]
        with tarfile.open(all_fw, "w:gz") as dst:
            for m, data in members:
                if m.name == "firmware/wifi/C-4387__s-C2/" + member:
                    m.type, m.linkname, m.size, data = tarfile.LNKTYPE, linkname, 0, None
                dst.addfile(m, io.BytesIO(data) if data is not None else None)
        return esp, tree

    def test_raw_tree_with_a_hard_link_reads_as_tar_extracts_it(self):
        esp, tree = self.hard_link_esp("hokkaido.trx",
                                       "firmware/wifi/C-4387__s-C2/hokkaido-X1.trx")
        all_fw = esp / "asahi" / "all_firmware.tar.gz"
        self.assertEqual(awf.raw_wifi(all_fw), awf.tree_digest(tree))
        before = awf.tree_hashes(esp)
        self.assertEqual(self.update(esp, self.macos(tree)), "identical")
        self.assertEqual(awf.tree_hashes(esp), before)

    def test_raw_tree_with_a_hard_link_to_nothing_is_rebuilt_not_a_crash(self):
        esp, tree = self.hard_link_esp("maldives.clmb", "firmware/wifi/C-4387__s-C2/gone.clmb")
        self.assertNotIn("C-4387__s-C2/maldives.clmb",
                         awf.raw_wifi(esp / "asahi" / "all_firmware.tar.gz"))
        self.assertEqual(self.update(esp, self.macos(tree)), "updated")
        self.assertEqual(awf.raw_wifi(esp / "asahi" / "all_firmware.tar.gz"),
                         awf.tree_digest(tree))

    def test_aliases_are_read_once(self):
        tree = wifi_tree("old")
        raw = self.root / "raw"
        for rel, v in tree.items():
            path = raw / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(v, tuple):
                os.symlink(v[1], path)
            else:
                path.write_bytes(v)
        real_open, opened = open, []

        def counting_open(path, *a, **kw):
            opened.append(os.path.realpath(path))
            return real_open(path, *a, **kw)
        with mock.patch("builtins.open", side_effect=counting_open):
            files = awf.converted(raw)
        self.assertEqual(len(opened), len(set(opened)))
        # A file and its aliases share one data object.
        by_file = {}
        for f in files.values():
            by_file.setdefault(os.path.realpath(raw / f.name), set()).add(id(f.data))
        self.assertEqual([len(ids) for ids in by_file.values()], [1] * len(by_file))
        self.assertEqual({k: f.sha for k, f in files.items()},
                         {k: f.sha for k, f in awf.converted(raw).items()})

    def test_raw_tree_that_does_not_convert_is_rebuilt_not_a_crash(self):
        tree = wifi_tree("old")
        esp = make_esp(self.root, tree)
        real = awf.BroadcomWiFi.convert

        def convert(part, staged):
            if any("raw-" in pathlib.Path(p).name for p in staged.values()):
                raise ValueError("a converter bug the raw tree trips")
            return real(part, staged)
        with mock.patch.object(awf.BroadcomWiFi, "convert", convert):
            self.assertEqual(self.update(esp, self.macos(tree)), "updated")
        self.assertEqual(awf.raw_wifi(esp / "asahi" / "all_firmware.tar.gz"),
                         awf.tree_digest(tree))

    def test_raw_tree_that_does_not_read_is_not_a_crash(self):
        esp = make_esp(self.root, wifi_tree("old"))
        part = awf.radio_parts(self.manifest(esp), BOARD)[0]
        self.assertEqual(part.key, "wifi")
        all_fw = esp / "asahi" / "all_firmware.tar.gz"
        data = all_fw.read_bytes()
        for bad in (data[:len(data) // 2], data[:10] + bytes(len(data) - 10), b"not gzip"):
            all_fw.write_bytes(bad)
            out = self.root / f"x{len(bad)}"
            out.mkdir()
            self.assertFalse(awf.raw_converts_to(all_fw, part, {}, out), len(bad))
        # The update refuses (a rebuild could not carry the archive's other
        # members over) instead of failing with an internal error.
        with self.assertRaisesRegex(awf.Refused, "does not read"):
            self.update(esp, self.macos(wifi_tree("new")))
        self.assertFalse(self.backups.exists())

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
        with self.assertRaisesRegex(awf.Refused, "lacks what this Mac loads"):
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
                       unpacked_sha=lambda n: st["pending"]["expect"][n], state_dir=self.state,
                       swap=lambda a, b: False)
        self.assertEqual(r, "ok")
        st = awf.read_state(self.state)
        self.assertNotIn("pending", st)
        self.assertEqual(st["firmware"], "20.131.4.0.8.7.215")

    def test_dead_firmware_reverts(self):
        esp, old, st = self.changed()
        text = "brcmfmac 0000:01:00.0: brcmf_pcie_setup: Dongle setup failed\n"
        r = awf.verify(st, esp, out=self.out.append, log_text=text, wait=0,
                       unpacked_sha=lambda n: st["pending"]["expect"][n], state_dir=self.state,
                       swap=lambda a, b: False)
        self.assertEqual(r, "reverted")
        self.assertEqual(awf.tree_hashes(esp), old)
        self.assertEqual(awf.read_state(self.state)["refused_build"], "25C56")

    def test_no_report_reverts(self):
        esp, old, st = self.changed()
        r = awf.verify(st, esp, out=self.out.append, log_text="", wait=0,
                       unpacked_sha=lambda n: st["pending"]["expect"][n], state_dir=self.state,
                       swap=lambda a, b: False)
        self.assertEqual(r, "reverted")
        self.assertEqual(awf.tree_hashes(esp), old)

    def test_same_boot_waits(self):
        esp, _, st = self.changed()
        st["pending"]["boot_id"] = "boot-that-changed-it"
        with mock.patch.object(awf, "boot_id", return_value="boot-that-changed-it"):
            self.assertEqual(awf.verify(st, esp, log_text="", wait=0, state_dir=self.state),
                             "waiting")

    def test_revert_by_hand(self):
        esp, old, _ = self.changed()
        awf.revert(esp, out=self.out.append, swap=lambda a, b: False, backup_root=self.backups)
        self.assertEqual(awf.tree_hashes(esp), old)


class MainTest(Case):
    """The commands as the boot unit and a person run them."""

    def setUp(self):
        super().setUp()
        self.esp = make_esp(self.root, wifi_tree("old"))
        self.mac = self.macos(wifi_tree("new"))
        self.saved = {k: getattr(awf, k) for k in ("STATE_DIR", "BACKUP_ROOT", "wifi_board",
                                                   "installed_macos", "exchange", "verify")}
        awf.STATE_DIR, awf.BACKUP_ROOT = self.state, self.backups
        awf.wifi_board = lambda dt=None: BOARD
        awf.installed_macos = lambda esp, **kw: [self.mac]
        awf.exchange = lambda a, b: False
        self.geteuid = awf.os.geteuid
        awf.os.geteuid = lambda: 0

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(awf, k, v)
        awf.os.geteuid = self.geteuid
        super().tearDown()

    def run_main(self, *argv):
        with open(os.devnull, "w") as null:
            old = sys.stdout, sys.stderr
            sys.stdout = sys.stderr = null
            try:
                return awf.main(["--esp", str(self.esp), *argv])
            finally:
                sys.stdout, sys.stderr = old

    def test_boot_updates_then_skips_a_checked_build(self):
        self.assertEqual(self.run_main("boot"), 0)
        st = awf.read_state()
        self.assertEqual(st["result"], "updated")
        # The next boot: brcmfmac came up with the new file.
        awf.verify = lambda state, esp, **kw: self.saved["verify"](
            dict(state, pending=dict(state["pending"], boot_id="earlier")), esp,
            log_text=VerifyRevertTest.UP_LINE, wait=0,
            unpacked_sha=lambda n: state["pending"]["expect"][n], swap=lambda a, b: False)
        self.assertEqual(self.run_main("boot"), 0)
        awf.verify = self.saved["verify"]
        st = awf.read_state()
        self.assertEqual(st["result"], "verified")
        self.assertEqual(st["esp_wifi"], awf.esp_wifi_digest(self.esp))
        # Later boots do not read the macOS tree again.
        stage = awf.stage_wifi
        awf.stage_wifi = lambda *a, **k: self.fail("the macOS tree was read again")
        try:
            self.assertEqual(self.run_main("boot"), 0)
        finally:
            awf.stage_wifi = stage
        self.assertEqual(awf.read_state()["result"], "verified")

    def test_a_refusal_is_remembered_until_its_inputs_change(self):
        full = types.SimpleNamespace(f_bavail=0, f_frsize=4096)
        with mock.patch.object(awf.os, "statvfs", return_value=full):
            self.assertEqual(self.run_main("boot"), 1)
            refused = awf.read_state()["refused"]
            self.assertEqual(refused["build"], "25C56")
            self.assertEqual(refused["esp_wifi"], awf.esp_wifi_digest(self.esp))
            self.assertGreater(refused["need"], 0)
            # Nothing changed: the next boot does not read or stage again.
            with mock.patch.object(awf, "update", side_effect=AssertionError("ran again")):
                self.assertEqual(self.run_main("boot"), 1)
            # A person asking for it still gets a full try.
            self.assertEqual(self.run_main("update"), 1)
        # Space freed on the ESP: the boot tries again and the change goes in.
        self.assertEqual(self.run_main("boot"), 0)
        st = awf.read_state()
        self.assertEqual(st["result"], "updated")
        self.assertIsNone(st.get("refused"))

    def test_a_failed_swap_is_not_remembered(self):
        before = awf.tree_hashes(self.esp)
        with mock.patch.object(awf, "swap_in", side_effect=OSError(5, "Input/output error")):
            self.assertEqual(self.run_main("boot"), 1)
        self.assertEqual(awf.tree_hashes(self.esp), before)
        self.assertIsNone(awf.read_state().get("refused"))
        # The next boot tries again and the change goes in.
        self.assertEqual(self.run_main("boot"), 0)
        self.assertEqual(awf.read_state()["result"], "updated")

    def test_a_copy_that_reads_back_wrong_is_not_remembered(self):
        real = awf.copy_verified
        calls = []

        def flaky(src, dst):
            calls.append(dst)
            real(src, dst)
            if len(calls) == 1:
                raise awf.Transient(f"the copy at {dst} does not match {src}")
        with mock.patch.object(awf, "copy_verified", side_effect=flaky):
            self.assertEqual(self.run_main("boot"), 1)
        self.assertIsNone(awf.read_state().get("refused"))
        self.assertEqual(self.run_main("boot"), 0)
        self.assertEqual(awf.read_state()["result"], "updated")

    def test_a_stale_copy_does_not_latch_a_lack_of_space(self):
        ref = make_esp(self.root / "ref", wifi_tree("old"))
        exact = max(needs(lambda: awf.update(
            ref, self.macos(wifi_tree("new")), BOARD, backup_root=self.root / "ref-backups",
            state_dir=self.root / "ref-state", out=self.out.append, swap=lambda a, b: False,
            probe=lambda n, t: False, log_text="")))
        disk = Disk(self.esp, awf.tree_size(self.esp) + exact)
        leave_new_copies(self.esp)
        # A refusal an earlier version of the tool remembered for this space.
        awf.write_state({"refused": dict(awf.refusal(awf.NoSpace(exact), self.mac, self.esp))})
        with disk.patch():
            self.assertFalse(awf.refusal_stands(awf.read_state()["refused"], self.mac, self.esp))
            self.assertEqual(self.run_main("boot"), 0)
        self.assertEqual(awf.read_state()["result"], "updated")
        self.assertEqual(awf.leftovers(self.esp), [])

    def test_a_refusal_for_another_tool_is_tried_again(self):
        old = awf.refusal(awf.Refused("an old converter's bug"), self.mac, self.esp)
        self.assertEqual(old["tool"], awf.tool_digest())
        self.assertTrue(awf.refusal_stands(old, self.mac, self.esp))
        awf.write_state({"refused": dict(old, tool="0" * 64)})
        self.assertEqual(self.run_main("boot"), 0)
        self.assertEqual(awf.read_state()["result"], "updated")
        awf.write_state({"refused": {k: v for k, v in old.items() if k != "tool"}})
        self.assertFalse(awf.refusal_stands(awf.read_state()["refused"], self.mac, self.esp))

    def test_tool_digest_covers_the_converters(self):
        mods = {n for n in sys.modules if n.startswith("asahi_firmware.")}
        self.assertTrue({"asahi_firmware.wifi", "asahi_firmware.bluetooth",
                         "asahi_firmware.mt7932", "asahi_firmware.core"} <= mods)
        digest = awf.tool_digest()
        real = awf.file_sha256
        with mock.patch.object(awf, "_TOOL", None), \
                mock.patch.object(awf, "file_sha256", side_effect=lambda p: real(p) if
                                  not str(p).endswith("mt7932.py") else "changed"):
            self.assertNotEqual(awf.tool_digest(), digest)

    def test_update_from_a_macos_dir_leaves_the_boot_refusal_alone(self):
        before = {"refused": awf.refusal(awf.NoSpace(1 << 62), self.mac, self.esp)}
        awf.write_state(before)
        other = self.macos(wifi_tree("new", boards=("maldives",)), build="25D10")
        with mock.patch.object(awf, "macos_at", return_value=other):
            self.assertEqual(self.run_main("update", "--macos", str(self.root)), 1)
        self.assertEqual(awf.read_state(), before)

    def test_a_refusal_stands_only_for_the_same_build_esp_and_space(self):
        refused = awf.refusal(awf.Refused("no"), self.mac, self.esp)
        self.assertTrue(awf.refusal_stands(refused, self.mac, self.esp))
        newer = awf.MacOS(self.mac.device, self.mac.volume, "25D10", "26.3")
        self.assertFalse(awf.refusal_stands(refused, newer, self.esp))
        self.assertFalse(awf.refusal_stands(dict(refused, esp_wifi="other"), self.mac, self.esp))
        self.assertFalse(awf.refusal_stands(dict(refused, esp_wifi=None), self.mac, self.esp))
        space = awf.refusal(awf.NoSpace(1 << 20), self.mac, self.esp)
        self.assertFalse(awf.refusal_stands(space, self.mac, self.esp), "1 MiB is free here")
        self.assertTrue(awf.refusal_stands(dict(space, need=1 << 62), self.mac, self.esp))
        self.assertFalse(awf.refusal_stands(None, self.mac, self.esp))

    def test_a_hand_revert_is_not_undone_at_boot(self):
        self.assertEqual(self.run_main("update"), 0)
        changed = awf.tree_hashes(self.esp)
        self.assertEqual(self.run_main("revert"), 0)
        reverted = awf.tree_hashes(self.esp)
        self.assertNotEqual(reverted, changed)
        self.assertEqual(self.run_main("boot"), 0)
        self.assertEqual(awf.tree_hashes(self.esp), reverted)
        # update brings it back, and the boot unit follows again.
        self.assertEqual(self.run_main("update"), 0)
        manifest = awf.radio_in(awf.parse_manifest(
            (self.esp / "vendorfw" / "manifest.txt").read_text("ascii")))
        self.assertEqual(awf.wifi_in(manifest), {
            k: v.sha for k, v in awf.converted(self.staged_new()).items()})
        self.assertEqual(awf.esp_wifi_digest(self.esp), awf.sha256("".join(
            f"{k} {v}\n" for k, v in sorted(manifest.items())).encode()))
        self.assertIsNone(awf.read_state().get("refused_build"))

    def staged_new(self):
        raw = self.root / "raw-new"
        if not raw.exists():
            for rel, v in wifi_tree("new").items():
                p = raw / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                if isinstance(v, tuple):
                    os.symlink(v[1], p)
                else:
                    p.write_bytes(v)
        return raw


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
