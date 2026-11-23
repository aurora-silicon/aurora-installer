"""The ESP the Wi-Fi firmware and speaker tuning tools mount themselves is
mounted for root only (vfat takes its permissions from the mount options)."""

import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from contextlib import nullcontext
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools" / "wifi-firmware"))
sys.path.insert(0, str(ROOT / "tools" / "speaker-tuning"))

import aurora_wifi_firmware as awf  # noqa: E402
import speaker_tuning as st  # noqa: E402

PRIVATE = {"dmask=0077", "fmask=0177", "nodev", "nosuid", "noexec"}


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


def mounted_esp(tmp, options):
    """As unmounted_esp, with the ESP already mounted read-write at /boot/efi."""
    dt, _, _ = unmounted_esp(tmp)
    calls = []

    def run(args, capture_output=True):
        calls.append(args)
        if args[0] == "findmnt":
            return subprocess.CompletedProcess(args, 0, f"/boot/efi {options}\n".encode(), b"")
        raise AssertionError(args)

    return dt, run, calls


class ReusedEspMountTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def find(self, tool, options):
        root = pathlib.Path(tempfile.mkdtemp(dir=self.tmp))
        dt, run, calls = mounted_esp(root, options)
        with self.assertLogs(tool.log, level="WARNING") if others(options) else nullcontext():
            if tool is awf:
                path, mounted = awf.find_esp(run=run, dt=dt, root=str(root))
            else:
                path, mounted = st.find_esp(
                    run=run, dt_esp=str(dt / "chosen" / "asahi,efi-system-partition"),
                    root=str(root))
        self.assertEqual((str(path), mounted), ("/boot/efi", None))
        self.assertEqual([c[0] for c in calls], ["findmnt"])

    def test_a_mount_others_can_read_is_used_with_a_warning(self):
        for tool in (awf, st):
            self.find(tool, "rw,relatime,fmask=0022,dmask=0022,codepage=437")
            self.find(tool, "rw,relatime,umask=0000")

    def test_a_private_mount_is_used_quietly(self):
        for tool in (awf, st):
            with mock.patch.object(tool.log, "warning") as warning:
                self.find(tool, "rw,relatime,fmask=0077,dmask=0077")
                self.find(tool, "rw,relatime,fmask=0137,dmask=0027")
            warning.assert_not_called()

    def test_mask_parsing(self):
        for tool in (awf, st):
            self.assertTrue(tool.others_can_read("rw,fmask=0022"))
            self.assertFalse(tool.others_can_read("rw,fmask=0077"))
            self.assertFalse(tool.others_can_read("rw,fmask=0004"))
            self.assertFalse(tool.others_can_read("rw,relatime"))
            self.assertFalse(tool.others_can_read("rw,fmask=zz"))


def others(options):
    return any(o in options for o in ("fmask=0022", "umask=0000"))


class UnmountTest(unittest.TestCase):
    def test_a_failed_unmount_is_logged(self):
        failed = subprocess.CompletedProcess(["umount"], 32, b"", b"target is busy")
        for tool in (awf, st):
            esp = (pathlib.Path("/run/x"), "/run/x")
            with mock.patch.object(tool, "find_esp", return_value=esp), \
                    mock.patch.object(tool.subprocess, "run", return_value=failed) as run, \
                    self.assertLogs(tool.log, level="WARNING") as logs:
                with tool.system_esp(None):
                    pass
            self.assertEqual(run.call_args[0][0], ["umount", "/run/x"])
            self.assertIn("target is busy", "\n".join(logs.output))


if __name__ == "__main__":
    unittest.main()
