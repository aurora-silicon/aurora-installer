# SPDX-License-Identifier: MIT
"""Extraction of all_firmware.tar.gz: only what stays inside the extracted
tree reaches the collectors. Synthetic archives only."""
import errno, io, os, pathlib, sys, tarfile, tempfile, unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from asahi_firmware import update  # noqa: E402

BT = "BCM4387C2_19.3.395.4044_PCIE_macOS_MaldivesES2_CLPC_3ANT_OS_USI_20211013.bin"
OUTSIDE = b"CONTENT OF A FILE OUTSIDE THE ARCHIVE\n"


def member(tar, name, data=None, link=None, kind=None):
    ti = tarfile.TarInfo(name)
    if kind is not None:
        ti.type = kind
        if link is not None:
            ti.linkname = link
        tar.addfile(ti)
    elif link is not None:
        ti.type = tarfile.SYMTYPE
        ti.linkname = link
        tar.addfile(ti)
    elif data is None:
        ti.type = tarfile.DIRTYPE
        ti.mode = 0o755
        tar.addfile(ti)
    else:
        ti.size = len(data)
        tar.addfile(ti, io.BytesIO(data))


class Workdir(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = pathlib.Path(tmp.name)
        self.source = self.tmp / "source"
        self.source.mkdir()
        self.archive = self.source / "all_firmware.tar.gz"
        self.outside = self.tmp / "outside.bin"
        self.outside.write_bytes(OUTSIDE)

    def build(self, fill):
        with tarfile.open(self.archive, "w:gz") as tar:
            fill(tar)


class UpdateFirmwareLinks(Workdir):
    """update_firmware() end to end, without a kernelcache."""

    def package(self):
        dest = self.tmp / "vendorfw"
        dest.mkdir()
        kernel = mock.Mock()
        kernel.return_value.files.return_value = []
        with mock.patch.object(update, "KernelFWCollection", kernel):
            update.update_firmware(self.source, dest)
        out = {}
        with tarfile.open(dest / "firmware.tar") as tar:
            for m in tar.getmembers():
                src = m
                while src.islnk():
                    src = tar.getmember(src.linkname)
                out[m.name] = tar.extractfile(src).read()
        return out

    def test_links_that_leave_the_archive_are_not_packaged(self):
        def fill(tar):
            member(tar, "firmware/bluetooth/" + BT, link=str(self.outside))
            member(tar, "firmware/wifi/C-4387__s-C2/P-maui_M-XXXX.trx", link=str(self.outside))
            member(tar, "firmware/wifi/C-4387__s-C2/P-fiji_M-XXXX.trx",
                   link="../../../../outside.bin")
        self.build(fill)
        files = self.package()
        self.assertEqual(files, {})

    def test_aliases_inside_the_archive_are_packaged(self):
        def fill(tar):
            member(tar, "firmware/bluetooth/" + BT, b"bluetooth")
            member(tar, "firmware/wifi/C-4387__s-C2/maui.trx", b"wifi")
            member(tar, "firmware/wifi/C-4387__s-C2/maui-X3.trx", link="maui.trx")
            member(tar, "firmware/wifi/C-4387__s-C2/fiji.trx", link="../../shared/fiji.trx")
            member(tar, "firmware/shared/fiji.trx", b"wifi fiji")
        self.build(fill)
        files = self.package()
        self.assertEqual(files["brcm/brcmbt4387c2-apple,maldives-u.bin"], b"bluetooth")
        wifi = {n: d for n, d in files.items() if n.startswith("brcm/brcmfmac")}
        self.assertEqual(set(wifi.values()), {b"wifi", b"wifi fiji"})
        self.assertTrue(any("maui" in n for n in wifi), wifi)
        self.assertTrue(any("fiji" in n for n in wifi), wifi)


class ExtractArchive(Workdir):
    def extract(self, fill):
        from asahi_firmware.archive import extract_archive
        self.build(fill)
        self.dest = self.tmp / "extracted"
        self.dest.mkdir()
        return extract_archive(self.archive, self.dest)

    def tree(self):
        out = {}
        for parent, dirs, names in os.walk(self.dest):
            for n in dirs + names:
                p = pathlib.Path(parent, n)
                rel = str(p.relative_to(self.dest))
                if p.is_symlink():
                    out[rel] = "link:" + os.readlink(p)
                elif p.is_file():
                    out[rel] = p.read_bytes()
        return out

    def assert_nothing_escaped(self):
        root = os.path.realpath(self.dest)
        for parent, dirs, names in os.walk(self.dest):
            for n in dirs + names:
                real = os.path.realpath(os.path.join(parent, n))
                self.assertTrue(real == root or real.startswith(root + os.sep), real)
        self.assertEqual(self.outside.read_bytes(), OUTSIDE)
        self.assertEqual(sorted(p.name for p in self.tmp.iterdir()),
                         ["extracted", "outside.bin", "source"])

    def test_files_directories_and_inside_links(self):
        def fill(tar):
            member(tar, "./")
            member(tar, "./firmware")
            member(tar, "./firmware/wifi/a.trx", b"a")
            member(tar, "firmware/wifi/alias.trx", link="a.trx")
            member(tar, "fud_firmware/j1/Multitouch.im4p", link="../Firmware/mt.im4p")
            member(tar, "fud_firmware/Firmware/mt.im4p", b"mt")
            member(tar, "firmware/wifi/dangling.trx", link="absent.trx")
            member(tar, "firmware/wifi/hard.trx", link="firmware/wifi/a.trx", kind=tarfile.LNKTYPE)
        self.assertEqual(self.extract(fill), [])
        self.assertEqual(self.tree(), {
            "firmware/wifi/a.trx": b"a",
            "firmware/wifi/alias.trx": "link:a.trx",
            "firmware/wifi/dangling.trx": "link:absent.trx",
            "firmware/wifi/hard.trx": b"a",
            "fud_firmware/j1/Multitouch.im4p": "link:../Firmware/mt.im4p",
            "fud_firmware/Firmware/mt.im4p": b"mt",
        })
        self.assertEqual((self.dest / "fud_firmware/j1/Multitouch.im4p").read_bytes(), b"mt")
        self.assert_nothing_escaped()

    def test_names_outside_the_destination(self):
        def fill(tar):
            member(tar, str(self.tmp / "absolute.bin"), b"x")
            member(tar, "../parent.bin", b"x")
            member(tar, "firmware/../../parent2.bin", b"x")
            member(tar, "firmware/ok.bin", b"ok")
        skipped = self.extract(fill)
        self.assertEqual(len(skipped), 3)
        self.assertEqual(self.tree(), {"firmware/ok.bin": b"ok"})
        self.assert_nothing_escaped()

    def test_links_outside_the_destination(self):
        def fill(tar):
            member(tar, "firmware/abs.bin", link=str(self.outside))
            member(tar, "firmware/up.bin", link="../../outside.bin")
            member(tar, "firmware/updir", link="../..")
            member(tar, "firmware/hard.bin", link=str(self.outside), kind=tarfile.LNKTYPE)
            member(tar, "firmware/hard2.bin", link="../outside.bin", kind=tarfile.LNKTYPE)
            member(tar, "firmware/ok.bin", b"ok")
        skipped = self.extract(fill)
        self.assertEqual(len(skipped), 5)
        self.assertEqual(self.tree(), {"firmware/ok.bin": b"ok"})
        self.assert_nothing_escaped()

    def test_link_that_leaves_through_another_link(self):
        # here -> . stays inside; a/b/out's name stays inside too, but
        # here/.. is the destination's parent.
        def fill(tar):
            member(tar, "here", link=".")
            member(tar, "a/b/out.bin", link="../../here/../outside.bin")
            member(tar, "a/b/ok.bin", b"ok")
        skipped = self.extract(fill)
        self.assertEqual(skipped, ["a/b/out.bin"])
        self.assertEqual(self.tree(), {"here": "link:.", "a/b/ok.bin": b"ok"})
        self.assert_nothing_escaped()

    def test_nothing_is_written_through_a_link(self):
        def fill(tar):
            member(tar, "real/keep.bin", b"keep")
            member(tar, "dir", link="real")
            member(tar, "dir/keep.bin", b"replaced")
            member(tar, "dir/new.bin", b"new")
            member(tar, "dir/sub", None)
            member(tar, "real/hard.bin", link="dir/keep.bin", kind=tarfile.LNKTYPE)
        skipped = self.extract(fill)
        self.assertEqual(skipped, ["dir/keep.bin", "dir/new.bin", "dir/sub", "real/hard.bin"])
        self.assertEqual(self.tree(), {"dir": "link:real", "real/keep.bin": b"keep"})
        self.assert_nothing_escaped()

    def test_devices_and_fifos_are_skipped(self):
        def fill(tar):
            member(tar, "firmware/fifo.bin", kind=tarfile.FIFOTYPE)
            member(tar, "firmware/null.bin", kind=tarfile.CHRTYPE)
            member(tar, "firmware/disk.bin", kind=tarfile.BLKTYPE)
            member(tar, "firmware/ok.bin", b"ok")
        skipped = self.extract(fill)
        self.assertEqual(len(skipped), 3)
        self.assertEqual(self.tree(), {"firmware/ok.bin": b"ok"})

    def test_later_member_replaces_an_earlier_one(self):
        def fill(tar):
            member(tar, "firmware/a.bin", link=str(self.outside))
            member(tar, "firmware/a.bin", b"first")
            member(tar, "firmware/a.bin", b"second")
            member(tar, "firmware/b.bin", b"file")
            member(tar, "firmware/b.bin", link="a.bin")
        skipped = self.extract(fill)
        self.assertEqual(skipped, ["firmware/a.bin"])
        self.assertEqual(self.tree(), {"firmware/a.bin": b"second", "firmware/b.bin": "link:a.bin"})
        self.assert_nothing_escaped()

    def test_uncompressed_archive(self):
        self.archive = self.source / "all_firmware.tar"
        from asahi_firmware.archive import extract_archive
        with tarfile.open(self.archive, "w") as tar:
            member(tar, "firmware/ok.bin", b"ok")
        self.dest = self.tmp / "extracted"
        self.dest.mkdir()
        self.assertEqual(extract_archive(self.archive, self.dest), [])
        self.assertEqual(self.tree(), {"firmware/ok.bin": b"ok"})


class Limits(ExtractArchive):
    """An archive larger than a firmware archive is refused (ArchiveError,
    a ValueError); a member the filesystem refuses is skipped."""

    def extract(self, fill):
        # Each call starts from an empty destination.
        import shutil
        shutil.rmtree(self.tmp / "extracted", ignore_errors=True)
        return super().extract(fill)

    def limit(self, name, value):
        from asahi_firmware import archive
        patch = mock.patch.object(archive, name, value, create=True)
        patch.start()
        self.addCleanup(patch.stop)

    def files(self, n, size=1):
        def fill(tar):
            for i in range(n):
                member(tar, f"firmware/f{i}.bin", b"x" * size)
        return fill

    def test_limits_are_far_above_a_real_archive(self):
        # J616s (macOS 26): 3567 members, largest 4.6 MB, 87 MB in all.
        from asahi_firmware import archive
        self.assertGreaterEqual(archive.MAX_MEMBERS, 10 * 3567)
        self.assertGreaterEqual(archive.MAX_MEMBER_SIZE, 10 * 4625152)
        self.assertGreaterEqual(archive.MAX_TOTAL_SIZE, 10 * 87028545)
        self.assertTrue(issubclass(archive.ArchiveError, ValueError))

    def test_too_many_members(self):
        self.limit("MAX_MEMBERS", 5)
        self.assertEqual(self.extract(self.files(5)), [])
        with self.assertRaisesRegex(ValueError, "more than 5 members"):
            self.extract(self.files(6))

    def test_members_count_whatever_their_kind(self):
        self.limit("MAX_MEMBERS", 5)
        def fill(tar):
            for i in range(6):
                member(tar, f"firmware/l{i}", link="absent")
        with self.assertRaises(ValueError):
            self.extract(fill)

    def test_member_too_large(self):
        self.limit("MAX_MEMBER_SIZE", 100)
        self.assertEqual(self.extract(self.files(1, 100)), [])
        with self.assertRaisesRegex(ValueError, "101 bytes"):
            self.extract(self.files(1, 101))
        self.assertFalse((self.dest / "firmware/f0.bin").exists())

    def test_too_many_bytes_in_all(self):
        self.limit("MAX_TOTAL_SIZE", 1000)
        self.assertEqual(self.extract(self.files(10, 100)), [])
        with self.assertRaisesRegex(ValueError, "more than 1000 bytes"):
            self.extract(self.files(11, 100))

    def test_refused_archive_publishes_nothing(self):
        self.limit("MAX_MEMBERS", 2)
        self.build(self.files(3))
        dest = self.tmp / "vendorfw"
        dest.mkdir()
        (dest / "manifest.txt").write_bytes(b"old\n")
        with self.assertRaises(ValueError):
            update.update_firmware(self.source, dest)
        self.assertEqual(sorted(p.name for p in dest.iterdir() if not p.name.startswith(".")),
                         ["manifest.txt"])
        self.assertEqual((dest / "manifest.txt").read_bytes(), b"old\n")

    def test_name_too_long_is_skipped(self):
        long = "firmware/" + "n" * 300 + ".bin"
        def fill(tar):
            member(tar, long, b"x")
            member(tar, "firmware/" + "d" * 300 + "/a.bin", b"x")
            member(tar, "firmware/longlink.bin", link="t" * 6000)
            member(tar, "firmware/ok.bin", b"ok")
        skipped = self.extract(fill)
        self.assertEqual(len(skipped), 3, skipped)
        self.assertIn(long, skipped)
        self.assertEqual(self.tree(), {"firmware/ok.bin": b"ok"})

    def test_archive_read_error_leaves_the_previous_package_untouched(self):
        self.build(self.files(2))
        dest = self.tmp / "vendorfw"
        dest.mkdir()
        manifest = dest / "manifest.txt"
        manifest.write_bytes(b"previous package\n")
        for error in (OSError(errno.EIO, "Input/output error"), OSError("Read failed")):
            with self.subTest(error=error):
                source = mock.Mock()
                source.read.side_effect = error
                with mock.patch.object(tarfile.TarFile, "extractfile", return_value=source):
                    with self.assertRaises(OSError) as raised:
                        update.update_firmware(self.source, dest)
                self.assertIs(raised.exception, error)
                self.assertEqual(list(dest.iterdir()), [manifest])
                self.assertEqual(manifest.read_bytes(), b"previous package\n")

    def test_write_error_stops_the_extraction_and_leaves_no_part(self):
        from asahi_firmware import archive
        def copy(src, out):
            out.write(b"part")
            raise OSError(errno.EIO, "Input/output error")
        with mock.patch.object(archive.shutil, "copyfileobj", copy):
            with self.assertRaises(OSError):
                self.extract(self.files(2))
        self.assertEqual(self.tree(), {})

    def test_full_filesystem_stops_the_extraction(self):
        from asahi_firmware import archive
        def copy(src, out):
            out.write(b"part")
            raise OSError(errno.ENOSPC, "No space left on device")
        with mock.patch.object(archive.shutil, "copyfileobj", copy):
            with self.assertRaises(OSError):
                self.extract(self.files(2))
        self.assertEqual(self.tree(), {})


if __name__ == "__main__":
    unittest.main()
