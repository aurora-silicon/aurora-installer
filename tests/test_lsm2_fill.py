# SPDX-License-Identifier: MIT
"""Generated values only: never loads macOS's component or tuning."""
import hashlib
import json
import pathlib
import plistlib
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from asahi_firmware import audio_tuning, lsm2_fill as fill

AID, BUILD, UNIT = "AID901", "00A001", "1" * 64
STRIP = AID + "/DSP/Strips/synthetic.austrip"


def files(short=True):
    ids = sorted(fill.base_ids())
    if short:
        ids = ids[58:]
    data = struct.pack(">III", 0, 0, len(ids))
    data += b"".join(struct.pack(">If", i, (n + 1) / 13) for n, i in enumerate(ids))
    effect = {"unit": {"subtype": fill.SUBTYPE}, "displayname": "Synthetic",
              "aupreset": {"data": data}}
    return {STRIP: plistlib.dumps({"strips": [{"effects": [effect]}]})}


def readback(*_):
    return 17, [{"id": i, "name": f"Generated parameter {i}",
                 "bits": struct.unpack("<I", struct.pack("<f", (n + 1) / 7))[0]}
                for n, i in enumerate(sorted(fill.base_ids(), reverse=True))]


class FillTest(unittest.TestCase):
    def test_complete_short_and_full_noop(self):
        source = files()
        original = dict(source)
        raw = fill.collect(source, AID, BUILD, UNIT, readback)
        obj = fill.validate(raw, AID, BUILD, UNIT)
        capture, = obj["presets"]
        self.assertEqual(len(capture["fill_ids"]), 58)
        self.assertEqual(len(capture["published"]), 1021)
        self.assertEqual(source, original)
        effect = plistlib.loads(source[STRIP])["strips"][0]["effects"][0]
        self.assertEqual(capture["preset_sha256"], hashlib.sha256(effect["aupreset"]["data"]).hexdigest())
        with patch.object(fill, "read_parameters", side_effect=AssertionError("full preset must not host AU")):
            self.assertIsNone(fill.collect(files(False), AID, BUILD, UNIT))
        raw = fill.collect(files(False), AID, BUILD, UNIT, readback, force=True)
        self.assertEqual(json.loads(raw)["presets"][0]["fill_ids"], [])

    def test_missing_and_id_mismatch_readback(self):
        for how in ("missing", "mismatch", "duplicate", "nonfinite", "unnamed"):
            def bad(*args):
                version, records = readback()
                if how == "missing": records.pop()
                elif how == "mismatch": records[-1]["id"] = 0xffffffff
                elif how == "duplicate": records[-1]["id"] = records[0]["id"]
                elif how == "nonfinite": records[-1]["bits"] = 0x7f800000
                else: records[-1]["name"] = ""
                return version, records
            with self.subTest(how=how), self.assertRaises(ValueError):
                fill.collect(files(), AID, BUILD, UNIT, bad)

    def test_binding_manifest_and_private_write(self):
        raw = fill.collect(files(), AID, BUILD, UNIT, readback)
        for aid, build, unit in (("AID902", BUILD, UNIT), (AID, "00A002", UNIT),
                                 (AID, BUILD, "2" * 64), (AID, BUILD, None)):
            with self.assertRaises(ValueError):
                fill.validate(raw, aid, build, unit)
        rec = audio_tuning.fill_record(raw, AID, BUILD, UNIT)
        self.assertEqual(rec["unit_versions"], [17])
        self.assertEqual(rec["sha256"], hashlib.sha256(raw).hexdigest())
        col = audio_tuning.AudioTuningFWCollection.__new__(audio_tuning.AudioTuningFWCollection)
        col.bundle = {fill.NAME: raw}
        with tempfile.TemporaryDirectory() as tmp:
            self.assertTrue(col.write_fallback(tmp))
            path = pathlib.Path(tmp) / audio_tuning.FALLBACK_DIR / fill.NAME
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.read_bytes(), raw)

class IsolatedReadback(unittest.TestCase):
    def test_worker_failure_timeout_and_private_stderr_are_not_logged(self):
        import subprocess
        for response in (subprocess.CompletedProcess([], 1, b"", b"PRIVATE parameter values"),
                         subprocess.TimeoutExpired([], 60)):
            if isinstance(response, Exception):
                context = patch("subprocess.run", side_effect=response)
            else:
                context = patch("subprocess.run", return_value=response)
            with context, self.assertRaises(ValueError) as error:
                fill.isolated_read_parameters("synthetic", {}, {})
            self.assertNotIn("PRIVATE", str(error.exception))

    def test_worker_uses_pipes_and_timeout(self):
        import subprocess
        payload = json.dumps({"unit_version": 17, "published": readback()[1]}).encode()
        with patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0, payload, b"")) as run:
            self.assertEqual(fill.isolated_read_parameters("synthetic", {}, {}), readback())
        self.assertEqual(run.call_args.kwargs["timeout"], 60)
        self.assertTrue(run.call_args.kwargs["capture_output"])
        self.assertEqual(run.call_args.args[0][-1], "--readback")

class PrivateTransport(unittest.TestCase):
    def test_vendor_tar_cpio_and_collection_keep_private_modes(self):
        import io
        import tarfile
        from asahi_firmware.core import FWFile, FWPackage
        path = "apple/audio-tuning/" + fill.NAME
        with tempfile.TemporaryDirectory() as tmp:
            pkg = FWPackage(tmp)
            # Even coincidentally identical public data must not create a
            # hardlink between a public inode and the private fill.
            pkg.add_file("other", FWFile("other", b"synthetic"))
            pkg.add_file(path, FWFile(path, b"synthetic"))
            pkg.close()
            with tarfile.open(pathlib.Path(tmp) / "firmware.tar") as tar:
                self.assertTrue(tar.getmember(path).isfile())
                self.assertEqual(tar.getmember(path).mode, 0o600)
            raw = (pathlib.Path(tmp) / "firmware.cpio").read_bytes()
            offset = 0
            modes = {}
            while offset < len(raw):
                self.assertEqual(raw[offset:offset+6], b"070701")
                fields = [int(raw[offset+6+8*i:offset+14+8*i], 16) for i in range(13)]
                start = offset + 110
                name = raw[start:start+fields[11]-1].decode()
                modes[name] = fields[1] & 0o777
                offset = (start + fields[11] + 3) & ~3
                offset = (offset + fields[6] + 3) & ~3
                if name == "TRAILER!!!": break
            self.assertEqual(modes["vendorfw/" + path], 0o600)
            sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tools/speaker-tuning"))
            import speaker_tuning
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode="w") as tar:
                speaker_tuning.tar_add(tar, "audio-tuning/" + fill.NAME, b"synthetic")
            buffer.seek(0)
            with tarfile.open(fileobj=buffer) as tar:
                self.assertEqual(tar.getmembers()[0].mode, 0o600)

class BundleIntegration(unittest.TestCase):
    def test_optional_fill_round_trip_and_old_full_manifest_unchanged(self):
        from test_audio_tuning import LATTICE
        selection = {audio_tuning.DATABASE: plistlib.dumps({AID: {"Built-in Speaker": {}}}),
                     audio_tuning.config_name(901): b"synthetic config"}
        source = files()
        relative = {p[len(AID)+1:]: d for p, d in source.items()}
        raw = fill.collect(source, AID, BUILD, UNIT, readback)
        bundle = audio_tuning.tree(901, relative, None, BUILD, selection=selection,
                                   lattice=LATTICE, unit=UNIT, fill=raw)
        self.assertIn("lsm2_param_fill", json.loads(bundle[audio_tuning.MANIFEST]))
        with tempfile.TemporaryDirectory() as tmp:
            col = audio_tuning.AudioTuningFWCollection.__new__(audio_tuning.AudioTuningFWCollection)
            col.bundle = bundle
            self.assertTrue(col.write_fallback(tmp))
            reread = audio_tuning.AudioTuningFWCollection(path=tmp)
            self.assertEqual(reread.bundle, bundle)
        full = {p[len(AID)+1:]: d for p, d in files(False).items()}
        no_fill = audio_tuning.tree(901, full, None, BUILD, selection=selection,
                                    lattice=LATTICE, unit=UNIT)
        self.assertNotIn("lsm2_param_fill", json.loads(no_fill[audio_tuning.MANIFEST]))

    def test_live_collection_runs_fill_after_identity_and_fails_muted(self):
        from test_audio_tuning import fake_run, tunings, LATTICE
        from macho_fixtures import thin, padded
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            folder = tunings(root, AID)
            relative = STRIP[len(AID)+1:]
            (folder / relative).write_bytes(files()[STRIP])
            component = root / "AudioDSP"
            component.write_bytes(thin(padded(LATTICE)))
            run = fake_run([{"acoustic-id": (901).to_bytes(4, "little")}],
                           root={"serial-number": b"SYNTHETIC0A", "target-type": b"J999"})
            unit = audio_tuning.unit_id(b"SYNTHETIC0A")
            own, _ = audio_tuning.read_folder(str(folder))
            capture_files = {AID + "/" + p: d for p, d in own.items()}
            raw = fill.collect(capture_files, AID, "00A000", unit, readback)
            for result in (raw, ValueError("synthetic AU unavailable")):
                if isinstance(result, Exception): context = patch.object(fill, "collect", side_effect=result)
                else: context = patch.object(fill, "collect", return_value=result)
                with context as capture, patch.object(sys, "platform", "darwin"):
                    col = audio_tuning.AudioTuningFWCollection(tunings_root=str(root), run=run,
                                                               audiodsp=str(component))
                self.assertTrue(col.bundle)
                capture.assert_called_once()
                self.assertEqual(capture.call_args.args[1:4], (AID, "00A000", unit))
                self.assertEqual(fill.NAME in col.bundle, result is raw)

class ForcedReadbackResult(unittest.TestCase):
    def test_explicit_verification_cannot_report_success_without_a_field(self):
        import types
        sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tools/speaker-tuning"))
        import speaker_tuning
        with patch.object(speaker_tuning, "AudioTuningFWCollection",
                          return_value=types.SimpleNamespace(bundle=files(False))):
            with self.assertRaises(speaker_tuning.Refused):
                speaker_tuning.collect(force_lsm2_fill=True)
