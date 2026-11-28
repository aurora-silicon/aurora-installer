# SPDX-License-Identifier: GPL-2.0-only

import hashlib
import io
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


TOOL = Path(__file__).resolve().parents[3] / "tools/check-firmware-inventory.py"
CAMERA = "com.apple.factorydata/iCCl-synthetic-module"
TRUST = "com.apple.factorydata/trustobject-current"
SETFILE = "apple/isp_synthetic.dat"


class FirmwareInventoryTests(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.esp = Path(work.name)
        self.local = self.esp / "asahi/all_firmware.tar.gz"
        self.vendor = self.esp / "vendorfw/firmware.tar"
        self.inventory = self.esp / "inventory.json"
        for path in (self.local, self.vendor):
            path.parent.mkdir()
        self.record = b"synthetic unit data"
        self.firmware = b"synthetic IPSW data"
        self.inventory.write_text(json.dumps({
            "local": {name: hashlib.sha256(self.record).hexdigest() for name in (CAMERA, TRUST)},
            "vendor": {SETFILE: hashlib.sha256(self.firmware).hexdigest()},
        }))

    @staticmethod
    def write_archive(path, entries):
        with tarfile.open(path, "w:gz" if path.suffix == ".gz" else "w") as archive:
            for name, content in entries:
                info = tarfile.TarInfo(name)
                if content is None:
                    info.type = tarfile.SYMTYPE
                    info.linkname = TRUST
                    archive.addfile(info)
                else:
                    info.size = len(content)
                    archive.addfile(info, io.BytesIO(content))

    def run_check(self, local, vendor):
        self.write_archive(self.local, local)
        self.write_archive(self.vendor, vendor)
        result = subprocess.run(
            [sys.executable, str(TOOL), str(self.inventory), str(self.esp)],
            capture_output=True, text=True, check=False,
        )
        self.assertNotIn(CAMERA, result.stdout + result.stderr)
        return result

    def test_complete_inventory(self):
        result = self.run_check(
            [("./" + CAMERA, self.record), (TRUST, self.record)], [(SETFILE, self.firmware)],
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_calibration_trust_or_setfile(self):
        local = [(CAMERA, self.record), (TRUST, self.record)]
        vendor = [(SETFILE, self.firmware)]
        for actual_local, actual_vendor in ((local[:1], vendor), (local[1:], vendor), (local, [])):
            with self.subTest(local=actual_local, vendor=actual_vendor):
                result = self.run_check(actual_local, actual_vendor)
                self.assertEqual(result.returncode, 1)
                self.assertIn("1 missing", result.stdout)

    def test_wrong_bytes_empty_record_link_and_duplicate(self):
        for bad_entry in ((CAMERA, b"different unit"), (CAMERA, b""), (CAMERA, None)):
            with self.subTest(entry=bad_entry):
                result = self.run_check([(TRUST, self.record), bad_entry], [(SETFILE, self.firmware)])
                self.assertEqual(result.returncode, 1)
                self.assertIn("1 invalid", result.stdout)
        result = self.run_check(
            [(TRUST, self.record), (CAMERA, self.record), (CAMERA, self.record)],
            [(SETFILE, self.firmware)],
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("1 invalid", result.stdout)
