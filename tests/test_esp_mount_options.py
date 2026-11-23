"""The ESP the Wi-Fi firmware and speaker tuning tools mount themselves is
mounted for root only (vfat takes its permissions from the mount options)."""

import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools" / "wifi-firmware"))
sys.path.insert(0, str(ROOT / "tools" / "speaker-tuning"))

import aurora_wifi_firmware as awf  # noqa: E402
import speaker_tuning as st  # noqa: E402

PRIVATE = {"umask=0077", "nodev", "nosuid", "noexec"}


def unmounted_esp(tmp):
    """A root with the ESP's by-partuuid link and a device tree naming it,
    and a run() that reports it unmounted and records the mount call."""
    (tmp / "dev" / "disk" / "by-partuuid").mkdir(parents=True)
    (tmp / "dev" / "nvme0n1p4").write_bytes(b"")
    os.symlink("../../nvme0n1p4", tmp / "dev/disk/by-partuuid/aaaa-bb")
    dt = tmp / "dt"
    (dt / "chosen").mkdir(parents=True)
    (dt / "chosen" / "asahi,efi-system-partition").write_bytes(b"AAAA-BB\0")
    calls = []

    def run(args, capture_output=True):
        calls.append(args)
        if args[0] == "findmnt":
            return subprocess.CompletedProcess(args, 1, b"", b"")
        if args[0] == "mount":
            return subprocess.CompletedProcess(args, 0, b"", b"")
        raise AssertionError(args)

    return dt, run, calls


def mount_options(args):
    """The -o options of a mount command line, as a set."""
    if "-o" not in args:
        return set()
    return set(args[args.index("-o") + 1].split(","))


class EspMountOptionsTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self._tmp.name)
        self.mountpoint = str(self.tmp / "mnt")

    def tearDown(self):
        self._tmp.cleanup()

    def mount_call(self, calls):
        mounts = [c for c in calls if c[0] == "mount"]
        self.assertEqual(len(mounts), 1, calls)
        self.assertEqual(mounts[0][-1], self.mountpoint)
        return mounts[0]

    def test_wifi_firmware_mounts_the_esp_for_root_only(self):
        dt, run, calls = unmounted_esp(self.tmp)
        with mock.patch.object(awf, "MOUNTPOINT", self.mountpoint):
            path, mounted = awf.find_esp(run=run, dt=dt, root=str(self.tmp))
        self.assertEqual((str(path), mounted), (self.mountpoint, self.mountpoint))
        self.assertLessEqual(PRIVATE, mount_options(self.mount_call(calls)))

    def test_speaker_tuning_mounts_the_esp_for_root_only(self):
        dt, run, calls = unmounted_esp(self.tmp)
        with mock.patch.object(st, "MOUNTPOINT", self.mountpoint):
            path, mounted = st.find_esp(
                run=run, dt_esp=str(dt / "chosen" / "asahi,efi-system-partition"),
                root=str(self.tmp))
        self.assertEqual((str(path), mounted), (self.mountpoint, self.mountpoint))
        self.assertLessEqual(PRIVATE, mount_options(self.mount_call(calls)))


if __name__ == "__main__":
    unittest.main()
