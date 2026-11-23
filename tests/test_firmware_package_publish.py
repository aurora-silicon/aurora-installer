# SPDX-License-Identifier: MIT
"""The vendor firmware package is replaced only by a complete new one: a
run that fails leaves the files the destination already held."""
import gc, io, pathlib, sys, tarfile, tempfile, unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from asahi_firmware import update  # noqa: E402
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


if __name__ == "__main__":
    unittest.main()
