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
import unittest.mock
from unittest.mock import patch
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from asahi_firmware import audio_tuning, lsm2_fill as fill

AID, BUILD, UNIT = "AID901", "00A001", "1" * 64
STRIP = AID + "/DSP/Strips/synthetic.austrip"


COMPONENT = "c" * 64


def files(short=True, extra=()):
    ids = sorted(fill.base_ids())
    if short:
        ids = ids[58:]
    ids += list(extra)
    data = struct.pack(">III", 0, 0, len(ids))
    data += b"".join(struct.pack(">If", i, (n + 1) / 13) for n, i in enumerate(ids))
    effect = {"unit": {"subtype": fill.SUBTYPE}, "displayname": "Synthetic",
              "aupreset": {"data": data}}
    return {STRIP: plistlib.dumps({"strips": [{"effects": [effect]}]})}


def readback(*_, extra=(), version=17):
    ids = sorted(fill.base_ids() | set(extra), reverse=True)
    return {"unit_version": version, "component_sha256": COMPONENT,
            "published": [{"id": i, "name": f"Generated parameter {i}",
                           "bits": struct.unpack("<I", struct.pack("<f", (n + 1) / 7))[0]}
                          for n, i in enumerate(ids)]}


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
        for how in ("missing", "mismatch", "duplicate", "nonfinite", "noversion", "nocomponent"):
            def bad(*args):
                result = readback()
                records = result["published"]
                # records[-1] is the lowest base ID, which the short preset omits.
                if how == "missing": records.pop()
                elif how == "mismatch": records[-1]["id"] = 0xffffffff
                elif how == "duplicate": records[-1]["id"] = records[0]["id"]
                elif how == "nonfinite": records[-1]["bits"] = 0x7f800000
                elif how == "noversion": result["unit_version"] = None
                else: result["component_sha256"] = ""
                return result
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

class SchemaAndVersion(unittest.TestCase):
    """J713-shaped cases: counts and IDs only, generated values."""
    EXTRA = 21512  # append-map ID carried by a short preset

    def test_short_preset_with_published_append_id_is_accepted(self):
        source = files(extra=[self.EXTRA])
        saved = next(fill.presets(source))[2]
        self.assertEqual((len(saved), len(fill.missing_ids(saved))), (964, 58))
        self.assertTrue(fill.needs_fill(source))
        raw = fill.collect(source, AID, BUILD, UNIT, lambda *a: readback(extra=[self.EXTRA]))
        capture, = fill.validate(raw, AID, BUILD, UNIT)["presets"]
        self.assertEqual(len(capture["fill_ids"]), 58)
        self.assertNotIn(self.EXTRA, capture["fill_ids"])
        self.assertEqual(len(capture["published"]), 1022)

    def test_unit_published_ids_beyond_the_schema_are_kept_as_provenance(self):
        # The unit may publish many more IDs than the preset saves.
        more = sorted(fill.extension_ids())[:182]
        raw = fill.collect(files(), AID, BUILD, UNIT, lambda *a: readback(extra=more))
        capture, = json.loads(raw)["presets"]
        self.assertEqual(len(capture["published"]), 1021 + 182)
        self.assertEqual(len(capture["fill_ids"]), 58)

    def test_append_id_the_unit_does_not_publish_is_refused(self):
        with self.assertRaisesRegex(ValueError, "does not publish 1 saved"):
            fill.collect(files(extra=[self.EXTRA]), AID, BUILD, UNIT, readback)

    def test_unknown_saved_id_is_refused_before_hosting(self):
        unknown = 21513  # next to the append ID, but in no schema
        self.assertNotIn(unknown, fill.base_ids() | fill.extension_ids())
        host = unittest.mock.Mock(side_effect=AssertionError("must not host the AU"))
        with self.assertRaisesRegex(ValueError, "outside the known lsm2 schema: 21513"):
            fill.collect(files(extra=[unknown]), AID, BUILD, UNIT, host)
        with self.assertRaisesRegex(ValueError, "outside the known lsm2 schema"):
            fill.collect(files(extra=[unknown]), AID, BUILD, UNIT,
                         lambda *a: readback(extra=[unknown]))

    def test_short_is_defined_by_missing_base_ids_not_record_count(self):
        # 1,021 records but one base ID swapped for an append ID: short.
        ids = sorted(fill.base_ids())[1:] + [self.EXTRA]
        self.assertEqual(len(ids), 1021)
        self.assertEqual(len(fill.missing_ids(set(ids))), 1)
        data = struct.pack(">III", 0, 0, len(ids)) + b"".join(struct.pack(">If", i, 0.5) for i in ids)
        effect = {"unit": {"subtype": fill.SUBTYPE}, "aupreset": {"data": data}}
        source = {STRIP: plistlib.dumps({"strips": [{"effects": [effect]}]})}
        self.assertTrue(fill.needs_fill(source))
        raw = fill.collect(source, AID, BUILD, UNIT, lambda *a: readback(extra=[self.EXTRA]))
        self.assertEqual(len(json.loads(raw)["presets"][0]["fill_ids"]), 1)

    def test_unit_version_zero_is_bound_by_component(self):
        raw = fill.collect(files(), AID, BUILD, UNIT, lambda *a: readback(version=0))
        capture, = json.loads(raw)["presets"]
        self.assertEqual((capture["unit_version"], capture["component_sha256"]), (0, COMPONENT))
        self.assertEqual(audio_tuning.fill_record(raw, AID, BUILD, UNIT)["unit_versions"], [0])

    def test_unit_version_rule(self):
        # The J713 ClassInfo key set: no auversion, preset format version 0.
        j713 = {k: 0 for k in ("manufacturer", "type", "subtype", "version", "name", "data",
                               "DefaultAudioChannelLayout")}
        self.assertEqual(fill.unit_version(j713, 0), 0)
        self.assertEqual(fill.unit_version(j713, 9), 9)
        self.assertEqual(fill.unit_version({"auversion": 9}, 0), 9)
        self.assertEqual(fill.unit_version({"auversion": 9}, 9), 9)
        for info, registry in (({"auversion": 9}, 8), ({"auversion": "9"}, 0),
                               ({"auversion": -1}, 0), ({"auversion": 2**32}, 0)):
            with self.subTest(info=info, registry=registry), self.assertRaises(ValueError):
                fill.unit_version(info, registry)

    def test_component_digest_and_unreadable_component(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "component"
            path.write_bytes(b"synthetic component")
            self.assertEqual(fill.component_digest(str(path)),
                             hashlib.sha256(b"synthetic component").hexdigest())
            with self.assertRaisesRegex(ValueError, "component unreadable"):
                fill.component_digest(str(path) + ".absent")

    def test_captures_from_different_units_are_refused(self):
        source = files()
        second = AID + "/DSP/Strips/second.austrip"
        source[second] = source[STRIP]
        calls = iter((readback(), readback(version=18)))
        with self.assertRaisesRegex(ValueError, "different units"):
            fill.collect(source, AID, BUILD, UNIT, lambda *a: next(calls))

    def test_empty_names_and_nonfinite_unused_values_are_provenance_only(self):
        def odd(*_):
            result = readback(extra=[self.EXTRA])
            for r in result["published"]:
                if r["id"] == self.EXTRA:
                    r["bits"] = 0x7fc00000  # carried by the preset, never filled
                r["name"] = ""
            return result
        raw = fill.collect(files(extra=[self.EXTRA]), AID, BUILD, UNIT, odd)
        self.assertEqual(len(json.loads(raw)["presets"][0]["fill_ids"]), 58)


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
        payload = json.dumps(readback()).encode()
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
