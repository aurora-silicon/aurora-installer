# SPDX-License-Identifier: MIT
"""Wi-Fi collector on synthetic trees: a file it cannot place is left out
and the rest of the tree is still collected."""
import pathlib, sys, tempfile, unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from asahi_firmware.wifi import WiFiFWCollection  # noqa: E402

GOOD = {
    "C-4387__s-C2/maui.trx": b"firmware",
    "C-4387__s-C2/P-maui-X3_M-XXXX_V-u__m-3.1.txt": b"boardrev=0x1\nmacaddr = 00:00\n",
}
GOOD_NAMES = ["brcm/brcmfmac4387c2-pcie.apple,maui.bin",
              "brcm/brcmfmac4387c2-pcie.apple,maui.txt"]


class Names(unittest.TestCase):
    def collect(self, extra):
        with tempfile.TemporaryDirectory() as tmp:
            for name, data in {**GOOD, **extra}.items():
                path = pathlib.Path(tmp) / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            with self.assertLogs("asahi_firmware.wifi", "WARNING") as logs:
                files = dict(WiFiFWCollection(tmp).files())
        return files, logs.output

    def test_well_named_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name, data in GOOD.items():
                path = pathlib.Path(tmp) / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            with self.assertNoLogs("asahi_firmware.wifi", "WARNING"):
                files = dict(WiFiFWCollection(tmp).files())
        self.assertEqual(sorted(files), GOOD_NAMES)
        self.assertEqual(files[GOOD_NAMES[1]].data, b"boardrev=0x1\nmacaddr= 00:00\n")

    def check(self, extra, mention):
        files, logs = self.collect(extra)
        self.assertEqual(sorted(files), GOOD_NAMES)
        self.assertEqual(len(logs), len(extra), logs)
        for line in logs:
            self.assertIn(mention, line)

    def test_name_without_key_value_parts(self):
        self.check({"C-4387__s-C2/notes.txt": b"a=b\n"}, "notes.txt")

    def test_unknown_key(self):
        self.check({"C-4387__s-C2/maui_Z-new.trx": b"other"}, "Z-new")

    def test_file_outside_a_chip_directory(self):
        self.check({"fiji.trx": b"other", "extra/fiji.trx": b"other",
                    "C-4387/fiji.trx": b"other"}, ".trx")

    def test_nvram_that_does_not_parse(self):
        self.check({"C-4387__s-C2/P-fiji_M-XXXX.txt": b"no separator\n",
                    "C-4387__s-C2/P-bali_M-XXXX.txt": b"key=\xff\xfe\n"}, "NVRAM")


class NotRegularFiles(unittest.TestCase):
    """Only regular files (or links to them) are read: an alias that leads
    to a socket or a FIFO, or a socket in the tree, is skipped."""

    def collect(self, make):
        with tempfile.TemporaryDirectory() as tmp:
            for name, data in GOOD.items():
                path = pathlib.Path(tmp) / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            make(pathlib.Path(tmp, "C-4387__s-C2"))
            files = dict(WiFiFWCollection(tmp).files())
        self.assertEqual(sorted(files), GOOD_NAMES)

    def test_sockets_and_links_to_them_are_skipped(self):
        import os, socket
        def make(chip):
            sock = socket.socket(socket.AF_UNIX)
            self.addCleanup(sock.close)
            sock.bind(str(chip / "fiji.trx"))
            os.symlink("fiji.trx", chip / "bali.trx")
            os.symlink("..", chip / "dir.trx")
        self.collect(make)

    def test_link_to_a_fifo_is_skipped(self):
        # Before: open() of the FIFO blocked the collector.
        import os
        def make(chip):
            os.mkfifo(chip / "fifo")
            os.symlink("fifo", chip / "bali.trx")
        self.collect(make)


if __name__ == "__main__":
    unittest.main()
