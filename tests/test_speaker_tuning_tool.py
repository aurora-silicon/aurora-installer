# SPDX-License-Identifier: MIT
"""tools/speaker-tuning on synthetic files only.

No Apple tuning file, firmware or kernelcache is used or stored by these
tests: the bundle, the raw firmware archive and the kernelcache are made up.
"""
import hashlib
import io
import logging
import os
import pathlib
import plistlib
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools" / "speaker-tuning"))

sys.path.insert(0, str(ROOT / "tests"))

import speaker_tuning as st  # noqa: E402
from asahi_firmware import audio_tuning, lsm2_metadata  # noqa: E402
from asahi_firmware.audio_tuning import AudioTuningFWCollection  # noqa: E402
from macho_fixtures import CPU_X86_64, fat, padded, synthetic_lattice, thin  # noqa: E402


def der(tag, body):
    n = len(body)
    if n < 0x80:
        length = bytes([n])
    else:
        raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
        length = bytes([0x80 | len(raw)]) + raw
    return bytes([tag]) + length + body


def synthetic_kernelcache():
    """An uncompressed IM4P whose payload carries the marker the ASMedia
    extractor looks for, followed by synthetic bytes."""
    payload = b"\0" * 64 + b"2214A_RCFG"
    payload += b"\0" * (0x2f - 10) + struct.pack("<I", 0x18000)
    payload += bytes(i & 0xff for i in range(0x18000)) + b"\0" * 64
    return der(0x30, der(0x16, b"IM4P") + der(0x16, b"krnl") + der(0x16, b"synthetic")
               + der(0x04, payload))


def fake_run(acoustic=35, spts=bytes(range(16)), target=b"J999AP\n", model=b"Mac99,1\n", root=None):
    node = {"acoustic-id": acoustic.to_bytes(4, "little")}
    if spts is not None:
        node["speaker-thiele-small"] = spts

    def run(args, capture_output=True):
        if args[0] == "ioreg" and "AppleEmbeddedAudioDevice" in args:
            return subprocess.CompletedProcess(args, 0, b"", b"")
        if args[0] == "ioreg" and "device-tree" in args:
            return subprocess.CompletedProcess(args, 0, b"" if root is None else plistlib.dumps([root]), b"")
        if args[0] == "ioreg":
            return subprocess.CompletedProcess(args, 0, plistlib.dumps([node]), b"")
        if args[:2] == ["sysctl", "-n"]:
            value = {"kern.osversion": b"00A000\n", "hw.target": target, "hw.model": model}
            return subprocess.CompletedProcess(args, 0, value[args[2]], b"")
        raise AssertionError(args)
    return run


def tunings(root, acoustic=35, salt=b""):
    aid = f"AID{acoustic}"
    folder = root / aid
    (folder / "DSP" / "Strips").mkdir(parents=True)
    (folder / "ADM").mkdir()
    (folder / "ADM" / "config.plist").write_bytes(b"synthetic config" + salt)
    (folder / "DSP" / "Strips" / "strip.plist").write_bytes(b"synthetic strip" + salt)
    (root / "Config").mkdir()
    (root / "Config" / f"{aid}.plist").write_bytes(b"synthetic volume config")
    db = {aid: {"Built-in Speaker": {"General": {"Graph": "synthetic.dspg"}}}}
    (root / "DeviceDSPDatabase.plist").write_bytes(plistlib.dumps(db))


def bundle_dir(base, acoustic=35, salt=b"", spts=bytes(range(16)), root=None):
    """A verified audio-tuning/ under base; returns base."""
    src = base / "tunings"
    tunings(src, acoustic, salt)
    col = AudioTuningFWCollection(tunings_root=str(src), run=fake_run(acoustic, spts, root=root))
    assert col.bundle
    out = base / "bundle"
    out.mkdir()
    assert col.write_fallback(str(out))
    return out


def add(tar, name, data):
    ti = tarfile.TarInfo(name)
    ti.size = len(data)
    tar.addfile(ti, io.BytesIO(data))


def make_esp(base, extra_raw=()):
    """A synthetic system ESP: asahi/ with a raw archive and a kernelcache,
    vendorfw/ built from them with the real rebuild."""
    esp = base / "esp"
    (esp / "asahi").mkdir(parents=True)
    with tarfile.open(esp / "asahi" / "all_firmware.tar.gz", "w:gz") as tar:
        for name in ("firmware/", "firmware/wifi/", "firmware/bluetooth/"):
            ti = tarfile.TarInfo(name)
            ti.type = tarfile.DIRTYPE
            ti.mode = 0o755
            tar.addfile(ti)
        add(tar, "apple/aop-als-cal.bin", b"synthetic calibration")
        for name, data in extra_raw:
            add(tar, name, data)
    (esp / "asahi" / "kernelcache.release.synthetic").write_bytes(synthetic_kernelcache())
    (esp / "vendorfw").mkdir()
    st.rebuild_default(esp / "asahi", esp / "vendorfw")
    return esp


def snapshot(path):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(path.rglob("*")) if p.is_file()}


_component = None


def setUpModule():
    """Collections read a synthetic AudioDSP component (macho_fixtures)."""
    global _component
    logging.disable(logging.WARNING)
    _component = tempfile.TemporaryDirectory()
    path = pathlib.Path(_component.name) / "AudioDSP"
    path.write_bytes(fat(thin(padded(synthetic_lattice()), cpu=CPU_X86_64),
                         thin(padded(synthetic_lattice()))))
    audio_tuning.AUDIODSP_PATH = str(path)
    lsm2_metadata.read = lambda: 1.75


def tearDownModule():
    logging.disable(logging.NOTSET)
    _component.cleanup()


class Quiet:
    def __init__(self):
        self.lines = []

    def __call__(self, line):
        self.lines.append(line)

    def text(self):
        return "\n".join(self.lines)


class CollectTest(unittest.TestCase):
    def test_collect_writes_a_tarball_that_installs_back(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            tunings(tmp / "tunings")
            out, bundle, info = st.collect(tmp / "out.tar.gz", tunings_root=str(tmp / "tunings"),
                                           run=fake_run())
            self.assertEqual(oct(out.stat().st_mode & 0o777), "0o600")
            self.assertEqual(info["compatible"], "apple,j999")
            self.assertEqual(info["model"], "Mac99,1")
            with tarfile.open(out) as tar:
                names = tar.getnames()
                self.assertTrue(all(m.uid == 0 and m.isfile() or m.isdir() for m in tar))
            self.assertIn("aurora-speaker-tuning.json", names)
            self.assertIn("audio-tuning/manifest.json", names)
            with st.opened_bundle(out) as (again, got):
                self.assertEqual(again, bundle)
                self.assertEqual(got["aid"], "AID35")
            s = st.summary(bundle)
            self.assertEqual((s["aid"], s["files"], s["calibration"]), ("AID35", 2, True))
            self.assertTrue(s["lattice"])
            self.assertIn("audio-tuning/lsm2-mask-lattice.bin", names)
            self.assertIn("lsm2 masker lattice present", st.describe(bundle))

    def test_collect_without_a_lattice_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            tunings(tmp / "tunings")
            component = tmp / "AudioDSP"
            for image in (thin(b"\x11" * 2048), thin(padded(synthetic_lattice()) * 2)):
                component.write_bytes(image)
                with mock.patch.object(audio_tuning, "AUDIODSP_PATH", str(component)):
                    with self.assertRaises(st.Refused):
                        st.collect(tmp / "out.tar.gz", tunings_root=str(tmp / "tunings"),
                                   run=fake_run())
                self.assertFalse((tmp / "out.tar.gz").exists())

    def test_collect_macos27_layout(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            root = tmp / "tunings"
            tunings(root)
            os.unlink(root / "DeviceDSPDatabase.plist")
            entry = {"AID35": {"Built-in Speaker": {"General": {"Path": "Common/Strips/s.austrip"}}}}
            (root / "AID35" / "DSP" / "DSPDatabase.plist").write_bytes(plistlib.dumps(entry))
            (root / "Common" / "Strips").mkdir(parents=True)
            (root / "Common" / "Strips" / "s.austrip").write_bytes(b"synthetic shared strip")
            out, bundle, _ = st.collect(tmp / "out.tar.gz", tunings_root=str(root), run=fake_run())
            s = st.summary(bundle)
            self.assertEqual((s["database_source"], s["shared"]),
                             ("AID35/DSP/DSPDatabase.plist", 1))
            self.assertIn("1 shared files", st.describe(bundle))
            with st.opened_bundle(out) as (again, _):
                self.assertEqual(again, bundle)

    def test_collect_without_tuning_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            (tmp / "tunings").mkdir()
            with self.assertRaises(st.Refused):
                st.collect(tmp / "out.tar.gz", tunings_root=str(tmp / "tunings"), run=fake_run())
            self.assertFalse((tmp / "out.tar.gz").exists())

    def test_target_name(self):
        self.assertEqual(st.target_name("J413AP"), "apple,j413")
        self.assertEqual(st.target_name("J314sAP"), "apple,j314s")
        self.assertIsNone(st.target_name("../x"))


class BundleInputTest(unittest.TestCase):
    def tarball(self, tmp, members):
        path = tmp / "b.tar.gz"
        with tarfile.open(path, "w:gz") as tar:
            for m, data in members:
                tar.addfile(m, io.BytesIO(data) if data is not None else None)
        return path

    def test_tarball_with_links_or_escapes_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            link = tarfile.TarInfo("audio-tuning/AID35/x")
            link.type = tarfile.SYMTYPE
            link.linkname = "/etc/passwd"
            escape = tarfile.TarInfo("audio-tuning/../../x")
            escape.size = 1
            outside = tarfile.TarInfo("etc/x")
            outside.size = 1
            for m, data in ((link, None), (escape, b"x"), (outside, b"x")):
                path = self.tarball(tmp, [(m, data)])
                with self.assertRaises(st.Refused):
                    with st.opened_bundle(path):
                        pass

    def test_tarball_skips_finder_sidecars(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            src = bundle_dir(tmp)
            path = tmp / "b.tar.gz"
            with tarfile.open(path, "w:gz") as tar:
                tar.add(src / "audio-tuning", "audio-tuning")
                add(tar, "audio-tuning/._manifest.json", b"sidecar")
            with st.opened_bundle(path) as (bundle, info):
                self.assertIsNone(info)
                self.assertNotIn("._manifest.json", bundle)

    def test_changed_file_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            src = bundle_dir(tmp)
            (src / "audio-tuning" / "AID35" / "ADM" / "config.plist").write_bytes(b"changed!")
            with self.assertRaises(st.Refused):
                with st.opened_bundle(src):
                    pass

    def test_directory_forms(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            src = bundle_dir(tmp)
            with st.opened_bundle(src) as (a, _), st.opened_bundle(src / "audio-tuning") as (b, _):
                self.assertEqual(a, b)


class ManifestTest(unittest.TestCase):
    def test_links_resolve_to_their_target_hash(self):
        text = "FILE a SHA256 " + "1" * 64 + "\nLINK b a\n"
        self.assertEqual(st.parse_manifest(text), {"a": "1" * 64, "b": "1" * 64})

    def test_garbage_is_refused(self):
        with self.assertRaises(st.Refused):
            st.parse_manifest("FILE a\n")


class EspTest(unittest.TestCase):
    def run_with(self, findmnt, mount_rc=0):
        calls = []

        def run(args, capture_output=True):
            calls.append(args)
            if args[0] == "findmnt":
                return subprocess.CompletedProcess(args, 0, findmnt.encode(), b"")
            if args[0] == "mount":
                return subprocess.CompletedProcess(args, mount_rc, b"", b"busy")
            if args[0] == "blkid":
                return subprocess.CompletedProcess(args, 2, b"", b"")
            raise AssertionError(args)
        return run, calls

    def test_mounted_esp_by_partuuid(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "dev" / "disk" / "by-partuuid").mkdir(parents=True)
            (root / "dev" / "nvme0n1p4").write_bytes(b"")
            os.symlink("../../nvme0n1p4", root / "dev/disk/by-partuuid/aaaa-bb")
            dt = root / "esp-uuid"
            dt.write_bytes(b"AAAA-BB\0")
            run, calls = self.run_with("/boot/efi rw,relatime,fmask=0077\n")
            path, mounted = st.find_esp(run=run, dt_esp=str(dt), root=str(root))
            self.assertEqual((str(path), mounted), ("/boot/efi", None))
            self.assertEqual(calls[0][-1], os.path.realpath(root / "dev" / "nvme0n1p4"))

    def test_read_only_esp_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "dev" / "disk" / "by-partuuid").mkdir(parents=True)
            (root / "dev/disk/by-partuuid/aaaa").write_bytes(b"")
            dt = root / "esp-uuid"
            dt.write_bytes(b"aaaa\0")
            run, _ = self.run_with("/boot ro,relatime\n")
            with self.assertRaises(st.Refused):
                st.find_esp(run=run, dt_esp=str(dt), root=str(root))

    def test_missing_partition_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            dt = root / "esp-uuid"
            dt.write_bytes(b"aaaa\0")
            run, _ = self.run_with("")
            with self.assertRaises(st.Refused):
                st.find_esp(run=run, dt_esp=str(dt), root=str(root))

    def test_builder_marker_or_no_uuid_falls_back_to_m1n1(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "boot" / "m1n1").mkdir(parents=True)
            run, calls = self.run_with("")
            path, mounted = st.find_esp(run=run, dt_esp=str(root / "none"), root=str(root))
            self.assertEqual((path, mounted, calls), (root / "boot", None, []))
            (root / "boot" / "efi" / "m1n1").mkdir(parents=True)
            (root / "boot" / "efi" / ".builder").write_bytes(b"")
            dt = root / "esp-uuid"
            dt.write_bytes(b"aaaa\0")
            path, _ = st.find_esp(run=run, dt_esp=str(dt), root=str(root))
            self.assertEqual(path, root / "boot" / "efi")
            (root / "boot" / "efi" / "m1n1").rmdir()
            (root / "boot" / "m1n1").rmdir()
            with self.assertRaises(st.Refused):
                st.find_esp(run=run, dt_esp=str(dt), root=str(root))


class InstallTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self._tmp.name)
        self.esp = make_esp(self.tmp)
        self.backups = self.tmp / "rollback"

    def tearDown(self):
        self._tmp.cleanup()

    def install(self, source, **kw):
        out = Quiet()
        kw.setdefault("backup_root", self.backups)
        result = st.install(source, self.esp, out=out, **kw)
        return result, out.text()

    def test_install_then_identical(self):
        src = bundle_dir(self.tmp)
        before = snapshot(self.esp)
        result, text = self.install(src)
        self.assertEqual(result, "installed", text)
        after = snapshot(self.esp)
        self.assertNotEqual(before, after)
        self.assertEqual(sorted(after), sorted(before))   # no stray .new or .old
        manifest = st.parse_manifest((self.esp / "vendorfw" / "manifest.txt").read_text())
        self.assertIn("apple/audio-tuning/manifest.json", manifest)
        self.assertIn("apple/aop-als-cal.bin", manifest)
        self.assertTrue((self.esp / "vendorfw" / "u-boot").is_dir())
        raw, extra = st.raw_tuning(self.esp / "asahi" / "all_firmware.tar.gz")
        with st.opened_bundle(src) as (bundle, _):
            self.assertEqual(raw, bundle)
        self.assertEqual(extra, 0)
        (backup,) = self.backups.iterdir()
        self.assertEqual(snapshot(backup / "vendorfw"),
                         {k[len("vendorfw/"):]: v for k, v in before.items()
                          if k.startswith("vendorfw/")})
        result, text = self.install(src)
        self.assertEqual(result, "identical")
        self.assertIn("already present, identical", text)
        self.assertEqual(snapshot(self.esp), after)

    def test_dry_run_changes_nothing(self):
        src = bundle_dir(self.tmp)
        before = snapshot(self.esp)
        result, text = self.install(src, dry_run=True)
        self.assertEqual(result, "dry-run")
        self.assertIn("Check passed", text)
        self.assertEqual(snapshot(self.esp), before)
        self.assertFalse(self.backups.exists())

    def test_vendorfw_only_rebuild_keeps_all_firmware(self):
        src = bundle_dir(self.tmp)
        self.install(src)
        fw = self.esp / "asahi" / "all_firmware.tar.gz"
        kept = fw.read_bytes()
        # A rebuild by a firmware tool without speaker tuning support.
        os.rename(self.esp / "vendorfw", self.tmp / "with-tuning")
        (self.esp / "vendorfw").mkdir()
        with mock.patch.object(st.audio_tuning.AudioTuningFWCollection, "files", lambda self: []):
            st.rebuild_default(self.esp / "asahi", self.esp / "vendorfw")
        result, text = self.install(src)
        self.assertEqual(result, "installed", text)
        self.assertEqual(fw.read_bytes(), kept)
        self.assertEqual(snapshot(self.esp / "vendorfw"), snapshot(self.tmp / "with-tuning"))

    def test_file_only_in_old_vendorfw_refuses(self):
        src = bundle_dir(self.tmp)
        manifest = self.esp / "vendorfw" / "manifest.txt"
        manifest.write_text(manifest.read_text() + "FILE apple/only-here SHA256 " + "2" * 64 + "\n")
        before = snapshot(self.esp)
        with self.assertRaisesRegex(st.Refused, "superset"):
            self.install(src)
        self.assertEqual(snapshot(self.esp), before)
        self.assertFalse(self.backups.exists())

    def test_extra_package_file_lost_refuses(self):
        src = bundle_dir(self.tmp)
        (self.esp / "vendorfw" / "u-boot" / "keep.bin").write_bytes(b"synthetic")
        before = snapshot(self.esp)
        with self.assertRaisesRegex(st.Refused, "u-boot/keep.bin"):
            self.install(src)
        self.assertEqual(snapshot(self.esp), before)

    def test_failed_swap_is_undone(self):
        src = bundle_dir(self.tmp)
        before = snapshot(self.esp)
        calls = []

        def swap(a, b):
            calls.append((a, b))
            if len(calls) == 2:
                raise OSError(5, "synthetic I/O error")
            # Stand in for RENAME_EXCHANGE.
            tmp = pathlib.Path(str(b) + ".x")
            os.rename(b, tmp)
            os.rename(a, b)
            os.rename(tmp, a)
            return True
        with self.assertRaisesRegex(st.Refused, "undone"):
            self.install(src, swap=swap)
        self.assertEqual(snapshot(self.esp), before)

    def test_rename_fallback_without_exchange(self):
        src = bundle_dir(self.tmp)
        result, text = self.install(src, swap=lambda a, b: False)
        self.assertEqual(result, "installed", text)
        self.assertFalse(any(p.name.endswith((".old", ".new")) for p in self.esp.rglob("*")))

    def test_rebuild_failure_leaves_esp(self):
        src = bundle_dir(self.tmp)
        before = snapshot(self.esp)

        def broken(source, dest):
            raise RuntimeError("synthetic")
        with self.assertRaises(RuntimeError):
            self.install(src, rebuild=broken)
        self.assertEqual(snapshot(self.esp), before)

    def test_other_mac_or_aid_is_refused(self):
        src = bundle_dir(self.tmp)
        tarball = self.tmp / "b.tar.gz"
        with st.opened_bundle(src) as (bundle, _):
            st.write_collection(bundle, {"kind": st.INFO_KIND, "target": "J999AP",
                                         "compatible": "apple,j999"}, tarball)
        with self.assertRaisesRegex(st.Refused, "collected on"):
            self.install(tarball, compatible=["apple,j413", "apple,t8112"])
        result, _ = self.install(tarball, compatible=["apple,j999", "apple,t8112"], dry_run=True)
        self.assertEqual(result, "dry-run")
        self.install(src)
        other = self.tmp / "other"
        other.mkdir()
        with self.assertRaisesRegex(st.Refused, "AID35"):
            self.install(bundle_dir(other, acoustic=36))
        again = self.tmp / "again"
        again.mkdir()
        result, _ = self.install(bundle_dir(again, acoustic=36), any_mac=True, dry_run=True)
        self.assertEqual(result, "dry-run")

    def test_another_unit_is_refused(self):
        # Made-up serial numbers: the bundle's unit and two Linux sides.
        unit_a = audio_tuning.unit_id(b"SYNTHETIC0A")
        unit_b = audio_tuning.unit_id(b"SYNTHETIC0B")
        root = {"target-type": b"J413\0", "serial-number": b"SYNTHETIC0A".ljust(32, b"\0")}
        src = bundle_dir(self.tmp, root=root)
        here = ["apple,j413", "apple,t8112"]
        result, _ = self.install(src, compatible=here, unit=unit_a, dry_run=True)
        self.assertEqual(result, "dry-run")
        for any_mac in (False, True):
            with self.assertRaisesRegex(st.Refused, "collected on another Mac"):
                self.install(src, compatible=here, unit=unit_b, any_mac=any_mac, dry_run=True)
        # This Mac's serial-number unreadable: installed, speakerguardd runs open loop.
        result, _ = self.install(src, compatible=here, unit=None, dry_run=True)
        self.assertEqual(result, "dry-run")
        # The bundle's own board, when no collection info says otherwise.
        with self.assertRaisesRegex(st.Refused, "collected on a j413"):
            self.install(src, compatible=["apple,j616s", "apple,t6040"], unit=unit_a, dry_run=True)
        # The Linux side reads the unit from the device tree.
        dt = self.tmp / "serial-number"
        dt.write_bytes(b"SYNTHETIC0A\0")
        self.assertEqual(st.read_unit(dt), unit_a)
        self.assertIsNone(st.read_unit(self.tmp / "absent"))

    def test_a_bundle_without_a_unit_installs_with_a_warning(self):
        src = bundle_dir(self.tmp)
        logging.disable(logging.NOTSET)
        self.addCleanup(logging.disable, logging.WARNING)
        with self.assertLogs(st.log, "WARNING") as logs:
            result, _ = self.install(src, unit=audio_tuning.unit_id(b"SYNTHETIC0A"), dry_run=True)
        self.assertEqual(result, "dry-run")
        self.assertTrue(any("does not name the Mac" in m for m in logs.output))

    def test_newer_bundle_replaces_the_old_one(self):
        self.install(bundle_dir(self.tmp))
        newer = self.tmp / "newer"
        newer.mkdir()
        src = bundle_dir(newer, salt=b" v2", spts=None)
        result, text = self.install(src)
        self.assertEqual(result, "installed", text)
        manifest = st.parse_manifest((self.esp / "vendorfw" / "manifest.txt").read_text())
        self.assertNotIn("apple/audio-tuning/speaker-thiele-small.bin", manifest)
        raw, _ = st.raw_tuning(self.esp / "asahi" / "all_firmware.tar.gz")
        with st.opened_bundle(src) as (bundle, _):
            self.assertEqual(raw, bundle)

    def test_verify_running_bundle(self):
        src = bundle_dir(self.tmp)
        self.install(src)
        out = Quiet()
        self.assertEqual(st.verify(roots=[str(src)], esp=self.esp, out=out), 0)
        self.assertIn("matches the ESP", out.text())
        other = self.tmp / "o"
        other.mkdir()
        with self.assertRaises(st.Refused):
            st.verify(roots=[str(bundle_dir(other, salt=b"x"))], esp=self.esp, out=out)
        with self.assertRaises(st.Refused):
            st.verify(roots=[str(self.tmp / "none")], out=out)


class ScriptTest(unittest.TestCase):
    def test_scripts_parse(self):
        for name in ("collect-macos.sh", "install-linux.sh"):
            subprocess.run(["sh", "-n", str(ROOT / "tools" / "speaker-tuning" / name)], check=True)

    def test_install_help_needs_no_root(self):
        p = subprocess.run(["sh", str(ROOT / "tools" / "speaker-tuning" / "install-linux.sh"),
                            "--help"], capture_output=True, check=True)
        self.assertIn(b"--dry-run", p.stdout)


if __name__ == "__main__":
    unittest.main()
