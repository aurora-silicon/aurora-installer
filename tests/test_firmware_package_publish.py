# SPDX-License-Identifier: MIT
"""The vendor firmware package is replaced only by a complete new one: a
run that fails leaves the files the destination already held."""
import gc, io, os, pathlib, stat, subprocess, sys, tarfile, tempfile, unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from asahi_firmware import update  # noqa: E402
from asahi_firmware import core  # noqa: E402
from asahi_firmware.core import FWFile, FWPackage  # noqa: E402

BT = "BCM4387C2_19.3.395.4044_PCIE_macOS_MaldivesES2_CLPC_3ANT_OS_USI_20211013.bin"
PREVIOUS = {
    "firmware.tar": b"previous tar " * 100,
    "firmware.cpio": b"previous cpio " * 100,
    "manifest.txt": b"FILE previous SHA256 00\n",
    "u-boot/asmedia/asm2214a-apple.bin": b"previous controller firmware",
}


class Workdir(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = pathlib.Path(tmp.name)
        self.source = self.tmp / "source"
        self.source.mkdir()
        self.dest = self.tmp / "vendorfw"
        self.dest.mkdir()
        for name, data in PREVIOUS.items():
            path = self.dest / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)

    def state(self):
        gc.collect()
        return {str(p.relative_to(self.dest)): p.read_bytes()
                for p in self.dest.rglob("*") if p.is_file()}

    def write_archive(self):
        with tarfile.open(self.source / "all_firmware.tar.gz", "w:gz") as tar:
            ti = tarfile.TarInfo("firmware/bluetooth/" + BT)
            ti.size = 3
            tar.addfile(ti, io.BytesIO(b"new"))


class UpdateFirmware(Workdir):
    def kernel(self, **kwargs):
        collection = mock.Mock(**kwargs)
        if "side_effect" not in kwargs:
            collection.return_value.files.return_value = [
                ("asmedia/asm2214a-apple.bin", FWFile("asmedia/asm2214a-apple.bin", b"new controller"))]
        return mock.patch.object(update, "KernelFWCollection", collection)

    def test_missing_archive_is_an_error_and_keeps_the_package(self):
        with self.kernel():
            with self.assertRaises(FileNotFoundError):
                update.update_firmware(self.source, self.dest)
        self.assertEqual(self.state(), PREVIOUS)

    def test_unreadable_archive_keeps_the_package(self):
        (self.source / "all_firmware.tar.gz").write_bytes(b"not an archive")
        with self.kernel():
            with self.assertRaises(Exception):
                update.update_firmware(self.source, self.dest)
        self.assertEqual(self.state(), PREVIOUS)

    def test_failure_after_some_firmware_was_added_keeps_the_package(self):
        self.write_archive()
        with self.kernel(side_effect=Exception("Could not find kernelcache")):
            with self.assertRaisesRegex(Exception, "kernelcache"):
                update.update_firmware(self.source, self.dest)
        self.assertEqual(self.state(), PREVIOUS)

    def test_success_replaces_the_package(self):
        self.write_archive()
        with self.kernel():
            update.update_firmware(self.source, self.dest)
        state = self.state()
        self.assertEqual(sorted(state), sorted(PREVIOUS))
        self.assertEqual(state["u-boot/asmedia/asm2214a-apple.bin"], b"new controller")
        manifest = state["manifest.txt"].decode().splitlines()
        self.assertEqual([line.split()[1] for line in manifest],
                         ["brcm/brcmbt4387c2-apple,maldives-u.bin", "asmedia/asm2214a-apple.bin"])
        with tarfile.open(self.dest / "firmware.tar") as tar:
            self.assertEqual(tar.extractfile("brcm/brcmbt4387c2-apple,maldives-u.bin").read(), b"new")
        self.assertTrue(state["firmware.cpio"].startswith(b"070701"))
        self.assertIn(b"TRAILER!!!", state["firmware.cpio"])


class Package(Workdir):
    def fill(self, pkg):
        pkg.add_file("a.bin", FWFile("a.bin", b"data"))
        pkg.add_file("asmedia/asm2214a-apple.bin", FWFile("x", b"new controller"))

    def test_nothing_is_replaced_before_close(self):
        pkg = FWPackage(str(self.dest))
        self.fill(pkg)
        visible = {str(p.relative_to(self.dest)): p.read_bytes() for p in self.dest.rglob("*")
                   if p.is_file() and not p.name.endswith(".tmp")}
        self.assertEqual(visible, PREVIOUS)
        pkg.close()
        state = self.state()
        self.assertEqual(sorted(state), sorted(PREVIOUS))
        self.assertEqual(state["manifest.txt"].decode().splitlines()[0].split()[:2], ["FILE", "a.bin"])
        self.assertEqual(state["u-boot/asmedia/asm2214a-apple.bin"], b"new controller")
        pkg.close()
        self.assertEqual(self.state(), state)

    def test_package_dropped_without_close_is_discarded(self):
        pkg = FWPackage(str(self.dest))
        self.fill(pkg)
        del pkg
        self.assertEqual(self.state(), PREVIOUS)

    def test_abort_discards(self):
        pkg = FWPackage(str(self.dest))
        self.fill(pkg)
        pkg.abort()
        pkg.close()
        self.assertEqual(self.state(), PREVIOUS)

    def test_context_manager(self):
        with self.assertRaises(RuntimeError):
            with FWPackage(str(self.dest)) as pkg:
                self.fill(pkg)
                raise RuntimeError("collector failed")
        self.assertEqual(self.state(), PREVIOUS)
        with FWPackage(str(self.dest)) as pkg:
            self.fill(pkg)
        self.assertNotEqual(self.state()["firmware.tar"], PREVIOUS["firmware.tar"])
        self.assertEqual(sorted(self.state()), sorted(PREVIOUS))

    def test_temporary_files_of_a_killed_run_are_removed(self):
        stale = [self.dest / ".firmware.tar.abcd1234.tmp", self.dest / ".firmware.cpio.abcd1234.tmp",
                 self.dest / ".manifest.txt.abcd1234.tmp"]
        for path in stale:
            path.write_bytes(b"left over")
        other = self.dest / ".firmware.tar.keep"
        other.write_bytes(b"not ours")
        with FWPackage(str(self.dest)) as pkg:
            self.fill(pkg)
        self.assertEqual(sorted(self.state()), sorted(list(PREVIOUS) + [".firmware.tar.keep"]))

    def test_new_package_in_an_empty_directory(self):
        dest = self.tmp / "new"
        dest.mkdir()
        pkg = FWPackage(str(dest))
        pkg.add_file("a.bin", FWFile("a.bin", b"data"))
        pkg.close()
        self.assertEqual(sorted(p.name for p in dest.iterdir()),
                         ["firmware.cpio", "firmware.tar", "manifest.txt"])
        mode = (dest / "firmware.tar").stat().st_mode & 0o777
        probe = dest / "probe"
        probe.write_bytes(b"")
        self.assertEqual(mode, probe.stat().st_mode & 0o777)


class Commit(Workdir):
    """close() replaces the whole set or nothing, manifest.txt last, and
    syncs the directory; a second run on the same directory is refused."""

    def fill(self, pkg):
        pkg.add_file("a.bin", FWFile("a.bin", b"data"))
        pkg.add_file("asmedia/asm2214a-apple.bin", FWFile("x", b"new controller"))

    def leftovers(self):
        return sorted(str(p.relative_to(self.dest)) for p in self.dest.rglob(".*"))

    def close_failing_on(self, failing):
        """close() with the rename of a staged file onto failing refused."""
        real = os.replace
        renamed = []
        def replace(src, dst, *args, **kwargs):
            if str(src).endswith(".tmp"):
                if os.path.basename(dst) == failing:
                    raise OSError(5, "Input/output error")
                renamed.append(os.path.relpath(dst, self.dest))
            return real(src, dst, *args, **kwargs)
        pkg = FWPackage(str(self.dest))
        self.fill(pkg)
        with mock.patch.object(core.os, "replace", replace):
            if failing is None:
                pkg.close()
            else:
                with self.assertRaises(OSError):
                    pkg.close()
        return renamed

    def test_failed_rename_restores_the_previous_set(self):
        for failing in ("firmware.cpio", "asm2214a-apple.bin", "manifest.txt"):
            with self.subTest(failing=failing):
                self.close_failing_on(failing)
                self.assertEqual(self.state(), PREVIOUS)
                self.assertEqual(self.leftovers(), [])

    def test_failed_rename_into_an_empty_directory_leaves_it_empty(self):
        for name in PREVIOUS:
            (self.dest / name).unlink()
        self.close_failing_on("manifest.txt")
        self.assertEqual(self.state(), {})
        self.assertEqual(self.leftovers(), [])

    def test_manifest_is_replaced_last(self):
        renamed = self.close_failing_on(None)
        self.assertEqual(len(renamed), 4, renamed)
        self.assertEqual(renamed[-1], "manifest.txt")
        self.assertEqual(self.leftovers(), [])

    def test_previous_files_are_not_left_behind(self):
        with FWPackage(str(self.dest)) as pkg:
            self.fill(pkg)
        self.assertEqual(self.leftovers(), [])
        self.assertEqual(sorted(self.state()), sorted(PREVIOUS))

    def test_without_hard_links_the_previous_set_is_restored(self):
        # FAT has no hard links: the previous file is renamed aside.
        def no_link(*args, **kwargs):
            raise PermissionError(1, "Operation not permitted")
        with mock.patch.object(core.os, "link", no_link):
            self.close_failing_on("manifest.txt")
            self.assertEqual(self.state(), PREVIOUS)
            self.assertEqual(self.leftovers(), [])
            with FWPackage(str(self.dest)) as pkg:
                self.fill(pkg)
        self.assertEqual(self.state()["u-boot/asmedia/asm2214a-apple.bin"], b"new controller")
        self.assertEqual(self.leftovers(), [])

    def test_directory_is_synced_after_the_renames(self):
        real_fsync, real_replace = os.fsync, os.replace
        events = []
        def fsync(fd):
            st = os.fstat(fd)
            events.append(("fsync", stat.S_ISDIR(st.st_mode), st.st_ino))
            return real_fsync(fd)
        def replace(src, dst, *args, **kwargs):
            events.append(("replace", os.path.basename(dst)))
            return real_replace(src, dst, *args, **kwargs)
        pkg = FWPackage(str(self.dest))
        self.fill(pkg)
        with mock.patch.object(core.os, "fsync", fsync), mock.patch.object(core.os, "replace", replace):
            pkg.close()
        last_replace = max(i for i, e in enumerate(events) if e[0] == "replace")
        synced_dirs = [e[2] for e in events[last_replace:] if e[0] == "fsync" and e[1]]
        self.assertIn(self.dest.stat().st_ino, synced_dirs)
        self.assertIn((self.dest / "u-boot/asmedia").stat().st_ino, synced_dirs)

    def test_second_run_on_the_same_directory_is_refused(self):
        first = FWPackage(str(self.dest))
        self.fill(first)
        with self.assertRaisesRegex(RuntimeError, "Another firmware update"):
            FWPackage(str(self.dest))
        # The first run's temporary files are intact and it completes.
        first.close()
        state = self.state()
        self.assertEqual(sorted(state), sorted(PREVIOUS))
        self.assertEqual(state["u-boot/asmedia/asm2214a-apple.bin"], b"new controller")
        # The lock ends with the package (closed or aborted).
        FWPackage(str(self.dest)).abort()
        with FWPackage(str(self.dest)) as pkg:
            self.fill(pkg)

    def test_second_run_in_another_process_is_refused(self):
        code = ("import sys; sys.path.insert(0, sys.argv[1])\n"
                "from asahi_firmware.core import FWPackage\n"
                "try:\n"
                "    FWPackage(sys.argv[2])\n"
                "except RuntimeError as e:\n"
                "    print(e); sys.exit(7)\n")
        first = FWPackage(str(self.dest))
        try:
            run = subprocess.run([sys.executable, "-c", code,
                                  str(pathlib.Path(__file__).resolve().parents[1]), str(self.dest)],
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 7, run.stderr)
            self.fill(first)
            first.close()
        finally:
            first.abort()
        self.assertEqual(self.state()["u-boot/asmedia/asm2214a-apple.bin"], b"new controller")

    def test_umask_is_not_changed(self):
        old = os.umask(0o027)
        try:
            with mock.patch.object(core.os, "umask", side_effect=AssertionError("umask")):
                with FWPackage(str(self.dest)) as pkg:
                    self.fill(pkg)
        finally:
            os.umask(old)
        for name in PREVIOUS:
            self.assertEqual((self.dest / name).stat().st_mode & 0o777, 0o640, name)


if __name__ == "__main__":
    unittest.main()
