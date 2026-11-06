# SPDX-License-Identifier: MIT
"""Speaker tuning collection, on synthetic data only.

Based on aurora-audio-dsp by saku (MIT). No Apple tuning file is used or
stored by these tests.
"""
import hashlib
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from asahi_firmware import audio_tuning, lsm2_metadata  # noqa: E402
from asahi_firmware.audio_tuning import AudioTuningFWCollection  # noqa: E402
from macho_fixtures import (CPU_X86_64, fat, other_lattice, padded,  # noqa: E402
                            synthetic_lattice, thin)

LATTICE = synthetic_lattice()
VELOCITY_PARAMETER_MAX = 1.75
_component = None


def setUpModule():
    """Every collection reads a synthetic AudioDSP component."""
    global _component
    _component = tempfile.TemporaryDirectory()
    path = pathlib.Path(_component.name) / "AudioDSP"
    path.write_bytes(fat(thin(padded(LATTICE), cpu=CPU_X86_64), thin(padded(LATTICE))))
    audio_tuning.AUDIODSP_PATH = str(path)
    lsm2_metadata.read = lambda: VELOCITY_PARAMETER_MAX


def tearDownModule():
    _component.cleanup()


def fake_run(nodes, build=b"00A000\n", speakers=None, root=None):
    def run(args, capture_output=True):
        if args[0] == "ioreg" and "device-tree" in args:
            # The device tree root: none unless the test gives one.
            if isinstance(root, Exception):
                raise root
            return subprocess.CompletedProcess(args, 0, b"" if root is None else
                                               plistlib.dumps([root], fmt=plistlib.FMT_XML), b"")
        if args[0] == "ioreg" and "AppleEmbeddedAudioDevice" in args:
            if speakers is None:
                return subprocess.CompletedProcess(args, 0, b"", b"")
            if isinstance(speakers, Exception):
                raise speakers
            return subprocess.CompletedProcess(args, 0, plistlib.dumps(speakers, fmt=plistlib.FMT_XML), b"")
        if args[0] == "ioreg":
            return subprocess.CompletedProcess(args, 0, plistlib.dumps(nodes, fmt=plistlib.FMT_XML), b"")
        if args[0] == "sysctl":
            return subprocess.CompletedProcess(args, 0, build, b"")
        raise AssertionError(args)
    return run


def tunings(root, aid="AID35"):
    folder = root / aid
    (folder / "DSP" / "Strips").mkdir(parents=True)
    (folder / "ADM").mkdir()
    (folder / "ADM" / "config.plist").write_bytes(b"synthetic config")
    (folder / "DSP" / "Strips" / "aid35-aufx-spp3-appl.plist").write_bytes(b"synthetic spp3")
    (folder / "DSP" / "Strips" / "._aid35-aufx-spp3-appl.plist").write_bytes(b"sidecar")
    (folder / ".DS_Store").write_bytes(b"finder")
    (root / "Config").mkdir(exist_ok=True)
    (root / "Config" / f"{aid}.plist").write_bytes(b"synthetic volume config")
    database = {aid: {"Built-in Speaker": {"48k - General": {"Graph": "synthetic.dspg"}}},
                "AID999": {"Built-in Speaker": {}}}
    (root / "DeviceDSPDatabase.plist").write_bytes(plistlib.dumps(database, fmt=plistlib.FMT_BINARY))
    return folder


class AudioTuningTest(unittest.TestCase):
    def test_acoustic_id_is_one_little_endian_word(self):
        self.assertEqual(audio_tuning.acoustic_id(b"\x23\0\0\0"), 35)
        self.assertIsNone(audio_tuning.acoustic_id(b"\x23"))
        self.assertIsNone(audio_tuning.acoustic_id(b"\0\0\0\0"))

    def test_laptop_collects_folder_record_and_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            spts = bytes(range(16))
            col = AudioTuningFWCollection(
                tunings_root=str(root),
                run=fake_run([{"acoustic-id": b"\x23\0\0\0", "speaker-thiele-small": spts}]))
            names = sorted(n for n, _ in col.files())
            self.assertEqual(names, [
                "apple/audio-tuning/AID35/ADM/config.plist",
                "apple/audio-tuning/AID35/DSP/Strips/aid35-aufx-spp3-appl.plist",
                "apple/audio-tuning/Config/AID35.plist",
                "apple/audio-tuning/DeviceDSPDatabase.plist",
                "apple/audio-tuning/lsm2-mask-lattice.bin",
                "apple/audio-tuning/lsm2-metadata.json",
                "apple/audio-tuning/manifest.json",
                "apple/audio-tuning/speaker-thiele-small.bin",
            ])
            files = dict(col.files())
            meta = json.loads(files["apple/audio-tuning/manifest.json"].data)
            self.assertEqual(meta["aid"], "AID35")
            self.assertEqual(meta["macos_build"], "00A000")
            self.assertEqual(meta["based_on"], "aurora-audio-dsp by saku (MIT)")
            self.assertEqual(meta["device_dsp_database"], "DeviceDSPDatabase.plist")
            self.assertEqual(meta["config"], "Config/AID35.plist")
            self.assertEqual(meta["schema"], 2)
            self.assertIs(meta["complete"], True)
            self.assertEqual(meta["source_file_count"], 2)
            self.assertEqual(meta["source_file_count"],
                             sum(r["path"].startswith("AID35/") for r in meta["files"]))
            entry = plistlib.loads(files["apple/audio-tuning/DeviceDSPDatabase.plist"].data)
            self.assertEqual(list(entry), ["AID35"])
            self.assertEqual(meta["speaker_thiele_small"]["sha256"], hashlib.sha256(spts).hexdigest())
            for rec in meta["files"]:
                data = files["apple/audio-tuning/" + rec["path"]].data
                self.assertEqual(rec["sha256"], hashlib.sha256(data).hexdigest())

            # The fallback archive round-trips through the Linux-side update.
            out = root / "fallback"
            self.assertTrue(col.write_fallback(str(out)))
            again = AudioTuningFWCollection(str(out))
            self.assertEqual(sorted(n for n, _ in again.files()), names)
            (out / "audio-tuning" / "AID35" / "ADM" / "config.plist").write_bytes(b"changed")
            self.assertEqual(AudioTuningFWCollection(str(out)).files(), [])

    def test_desktop_without_calibration_still_gets_tuning(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root, "AID12")
            col = AudioTuningFWCollection(
                tunings_root=str(root), run=fake_run([{"acoustic-id": b"\x0c\0\0\0"}]))
            names = [n for n, _ in col.files()]
            self.assertIn("apple/audio-tuning/AID12/ADM/config.plist", names)
            self.assertNotIn("apple/audio-tuning/speaker-thiele-small.bin", names)

    def test_absent_or_ambiguous_nodes_collect_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            self.assertEqual(AudioTuningFWCollection(tunings_root=str(root), run=fake_run([])).files(), [])
            two = [{"acoustic-id": b"\x23\0\0\0"}, {"acoustic-id": b"\x09\0\0\0"}]
            self.assertEqual(AudioTuningFWCollection(tunings_root=str(root), run=fake_run(two)).files(), [])
            missing = [{"acoustic-id": b"\x09\0\0\0"}]
            self.assertEqual(AudioTuningFWCollection(tunings_root=str(root), run=fake_run(missing)).files(), [])

    def test_links_out_of_the_folder_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            folder = tunings(root)
            (root / "outside").write_bytes(b"x")
            (folder / "escape").symlink_to(root / "outside")
            col = AudioTuningFWCollection(
                tunings_root=str(root), run=fake_run([{"acoustic-id": b"\x23\0\0\0"}]))
            self.assertEqual(col.files(), [])


AID35 = [{"acoustic-id": b"\x23\0\0\0"}]


def collect(root):
    return AudioTuningFWCollection(tunings_root=str(root), run=fake_run(AID35))


def fallback(tmp):
    """A collected bundle written out as the fallback archive's directory."""
    root = pathlib.Path(tmp)
    tunings(root)
    col = collect(root)
    out = root / "fallback"
    assert col.write_fallback(str(out))
    return out, out / "audio-tuning"


def rewrite(bundle, edit):
    path = bundle / "manifest.json"
    meta = json.loads(path.read_bytes())
    edit(meta)
    path.write_text(json.dumps(meta))


class CompletenessTest(unittest.TestCase):
    """A short read never becomes a bundle, and a bundle that cannot prove
    it is complete is refused."""

    def assertNothing(self, col):
        self.assertEqual(col.files(), [])
        self.assertEqual(col.bundle, {})

    @unittest.skipIf(os.geteuid() == 0, "root reads unreadable directories")
    def test_unlistable_directory_fails_the_collection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            strips = tunings(root) / "DSP" / "Strips"
            strips.chmod(0)
            try:
                with self.assertLogs("asahi_firmware.audio_tuning", "WARNING"):
                    self.assertNothing(collect(root))
            finally:
                strips.chmod(0o755)

    def test_directory_link_fails_the_collection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            folder = tunings(root)
            (folder / "Linked").symlink_to(folder / "DSP", target_is_directory=True)
            self.assertNothing(collect(root))

    def test_dangling_or_special_link_fails_the_collection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            folder = tunings(root)
            (folder / "ADM" / "gone.plist").symlink_to(folder / "ADM" / "missing.plist")
            self.assertNothing(collect(root))

    def test_link_within_the_folder_is_a_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            folder = tunings(root)
            (folder / "ADM" / "alias.plist").symlink_to("config.plist")
            files = dict(collect(root).files())
            self.assertEqual(files["apple/audio-tuning/AID35/ADM/alias.plist"].data,
                             b"synthetic config")
            meta = json.loads(files["apple/audio-tuning/manifest.json"].data)
            self.assertEqual(meta["source_file_count"], 3)

    def test_missing_config_or_database_entry_is_no_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            (root / "Config" / "AID35.plist").unlink()
            self.assertNothing(collect(root))
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            (root / "DeviceDSPDatabase.plist").write_bytes(
                plistlib.dumps({"AID999": {}}, fmt=plistlib.FMT_BINARY))
            self.assertNothing(collect(root))
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            (root / "DeviceDSPDatabase.plist").unlink()
            self.assertNothing(collect(root))

    def test_oversized_config_is_no_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            (root / "Config" / "AID35.plist").write_bytes(b"x" * ((1 << 20) + 1))
            self.assertNothing(collect(root))

    def test_short_count_is_refused_by_the_writer(self):
        with self.assertRaises(ValueError):
            audio_tuning.tree(35, {"a": b"1"}, None, "00A000",
                              {"DeviceDSPDatabase.plist": b"d", "Config/AID35.plist": b"c"},
                              source_count=2, lattice=LATTICE,
                              velocity_parameter_max=VELOCITY_PARAMETER_MAX)

    def test_update_accepts_the_intact_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, _ = fallback(tmp)
            self.assertEqual(len(AudioTuningFWCollection(str(out)).files()), 7)

    def test_update_refuses_inconsistent_manifests(self):
        def drop_folder_record(meta):
            meta["files"] = [r for r in meta["files"] if r["path"] != "AID35/ADM/config.plist"]

        def drop_config(meta):
            meta["files"] = [r for r in meta["files"] if r["path"] != "Config/AID35.plist"]

        def stray(meta):
            meta["files"].append({"path": "elsewhere/x", "bytes": 0,
                                  "sha256": hashlib.sha256(b"").hexdigest()})

        edits = {
            "incomplete": lambda m: m.update(complete=False),
            "no completeness flag": lambda m: m.pop("complete"),
            "no count": lambda m: m.pop("source_file_count"),
            "count too high": lambda m: m.update(source_file_count=3),
            "folder record dropped": drop_folder_record,
            "config dropped": drop_config,
            "config null": lambda m: m.update(config=None),
            "database null": lambda m: m.update(device_dsp_database=None),
            "aid mismatch": lambda m: m.update(aid="AID99"),
            "old schema": lambda m: m.update(schema=1),
            "path outside the layout": stray,
            "huge record": lambda m: m["files"][0].update(bytes=(64 << 20) + 1),
        }
        for name, edit in edits.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                out, bundle = fallback(tmp)
                rewrite(bundle, edit)
                self.assertNothing(AudioTuningFWCollection(str(out)))

    def test_update_refuses_linked_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, bundle = fallback(tmp)
            entry = bundle / "AID35" / "ADM" / "config.plist"
            copy = pathlib.Path(tmp) / "copy"
            copy.write_bytes(entry.read_bytes())
            entry.unlink()
            entry.symlink_to(copy)
            self.assertNothing(AudioTuningFWCollection(str(out)))

    def test_collection_failure_never_raises_and_leaves_nothing(self):
        """The invariant the installer relies on: any failure is logged,
        no partial bundle is kept, and the installation carries on."""
        def broken(args, capture_output=True):
            raise OSError("ioreg failed")
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertLogs("asahi_firmware.audio_tuning", "WARNING"):
                col = AudioTuningFWCollection(tunings_root=tmp, run=broken)
            self.assertNothing(col)
            self.assertFalse(col.write_fallback(tmp))
            self.assertFalse((pathlib.Path(tmp) / "audio-tuning").exists())

    def test_fallback_write_failure_leaves_no_partial_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            col = collect(root)
            out = root / "fallback"
            # A file where AID35/ must be a directory stops the write midway.
            (out / "audio-tuning").mkdir(parents=True)
            (out / "audio-tuning" / "AID35").write_bytes(b"in the way")
            with self.assertLogs("asahi_firmware.audio_tuning", "WARNING"):
                self.assertFalse(col.write_fallback(str(out)))
            self.assertFalse((out / "audio-tuning").exists())



SPEAKER = {"device UID": "Speaker", "speakerID": 3}


class SpeakerIDTest(unittest.TestCase):
    def test_selection(self):
        sid = audio_tuning.speaker_id
        self.assertEqual(sid([SPEAKER, {"device UID": "Codec Output", "speakerID": 1}]), 3)
        self.assertEqual(sid([{"device UID": "Speaker", "speakerID": 65535}]), 65535)
        self.assertIsNone(sid([]))
        self.assertIsNone(sid([{"device UID": "Speaker"}]))
        self.assertIsNone(sid([SPEAKER, dict(SPEAKER)]))
        for bad in (True, 3.0, -1, 1 << 32, "3", b"\x03\0\0\0"):
            with self.subTest(bad):
                self.assertIsNone(sid([{"device UID": "Speaker", "speakerID": bad}]))

    def collected(self, root, speakers):
        col = AudioTuningFWCollection(
            tunings_root=str(root), run=fake_run(AID35, speakers=speakers))
        return col, json.loads(dict(col.files())["apple/audio-tuning/manifest.json"].data)

    def test_manifest_round_trip_and_fallback_recollection(self):
        for speakers, expected in (([SPEAKER], 3),
                                   ([{"device UID": "Speaker", "speakerID": 65535}], 65535),
                                   (None, None),
                                   ([{"device UID": "Speaker", "speakerID": 2.5}], None),
                                   ([SPEAKER, SPEAKER], None),
                                   (OSError("ioreg failed"), None)):
            with self.subTest(expected=expected, speakers=speakers), \
                    tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp)
                tunings(root)
                col, meta = self.collected(root, speakers)
                self.assertIn("speaker_id", meta)
                self.assertEqual(meta["speaker_id"], expected)
                self.assertEqual(len(col.files()), 7)
                out = root / "fallback"
                self.assertTrue(col.write_fallback(str(out)))
                again = AudioTuningFWCollection(str(out))
                meta = json.loads(dict(again.files())["apple/audio-tuning/manifest.json"].data)
                self.assertEqual(meta["speaker_id"], expected)

    def test_update_checks_the_speaker_id(self):
        accepted = {"missing": lambda m: m.pop("speaker_id"),
                    "null": lambda m: m.update(speaker_id=None),
                    "zero": lambda m: m.update(speaker_id=0),
                    "max": lambda m: m.update(speaker_id=4294967295)}
        refused = {"bool": True, "float": 3.0, "negative": -1, "string": "3",
                   "overflow": 4294967296, "list": [3]}
        for name, edit in accepted.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                out, bundle = fallback(tmp)
                rewrite(bundle, edit)
                self.assertEqual(len(AudioTuningFWCollection(str(out)).files()), 7)
        for name, value in refused.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                out, bundle = fallback(tmp)
                rewrite(bundle, lambda m: m.update(speaker_id=value))
                self.assertEqual(AudioTuningFWCollection(str(out)).files(), [])

    def test_collection_failure_stays_non_fatal_with_a_speaker_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            (root / "Config" / "AID35.plist").unlink()
            with self.assertLogs("asahi_firmware.audio_tuning", "WARNING"):
                col = AudioTuningFWCollection(
                    tunings_root=str(root), run=fake_run(AID35, speakers=[SPEAKER]))
            self.assertEqual(col.files(), [])
            self.assertFalse(col.write_fallback(tmp))



def speaker_entry(aid="AID35", speaker_paths=(), headphone_paths=()):
    """A synthetic database entry shaped like macOS's: modes holding
    {"Path": ...} references relative to the Tunings root."""
    def mode(paths):
        return {"Output": [{"Hardware": [{"Graph": {"Path": p}} for p in paths]}],
                "UnderlyingDeviceProperties": [{"Selector": "spid", "Value": 65535}]}
    return {aid: {"Built-in Speaker": {"48k - General": mode(speaker_paths)},
                  "Built-in Headphone": {"48k - General": mode(headphone_paths)}}}


def layout27(root, speaker_paths=("AID35/DSP/Strips/aid35-aufx-spp3-appl.plist",),
             headphone_paths=("Common/Graphs/builtin_headphone_out.dspg",), shared_db=False):
    """The macOS 27 layout: no shared DeviceDSPDatabase.plist, the entry in
    AID<n>/DSP/DSPDatabase.plist, shared graphs under Common/, a generic
    database and the loudness manager."""
    tunings(root)
    if not shared_db:
        (root / "DeviceDSPDatabase.plist").unlink()
    entry = speaker_entry(speaker_paths=speaker_paths, headphone_paths=headphone_paths)
    (root / "AID35" / "DSP" / "DSPDatabase.plist").write_bytes(
        plistlib.dumps(entry, fmt=plistlib.FMT_BINARY))
    (root / "Common" / "Graphs").mkdir(parents=True)
    (root / "Common" / "Strips").mkdir()
    (root / "Common" / "Graphs" / "builtin_headphone_out.dspg").write_bytes(b"synthetic hp graph")
    (root / "Common" / "Strips" / "shared_speaker.austrip").write_bytes(b"synthetic shared strip")
    (root / "GenericDSPDatabase.plist").write_bytes(plistlib.dumps({"Generic": {}}))
    (root / "DRC").mkdir()
    loudness(root, ["AID44"])
    return entry


def loudness(root, listed):
    (root / "DRC" / "loudness-manager.plist").write_bytes(
        plistlib.dumps({"Format": {"Default": {}}, "Supported_Hardware": listed}))


class LayoutTest(unittest.TestCase):
    """Both database layouts, shared references and the loudness manager."""

    def roundtrip(self, col, tmp):
        out = pathlib.Path(tmp) / "fallback"
        self.assertTrue(col.write_fallback(str(out)))
        again = AudioTuningFWCollection(str(out))
        self.assertEqual(again.bundle, col.bundle)
        return out, out / "audio-tuning"

    def test_macos26_records_the_shared_database(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            col = collect(root)
            meta = json.loads(col.bundle["manifest.json"])
            self.assertEqual(meta["device_dsp_database_source"], "DeviceDSPDatabase.plist")
            self.assertEqual((meta["shared_files"], meta["loudness_manager"]), ([], None))
            self.assertEqual(meta["schema"], 2)
            self.roundtrip(col, tmp)

    def test_macos27_reads_the_entry_from_the_folder(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            entry = layout27(root)
            col = collect(root)
            self.assertTrue(col.bundle)
            meta = json.loads(col.bundle["manifest.json"])
            self.assertEqual(meta["device_dsp_database_source"], "AID35/DSP/DSPDatabase.plist")
            self.assertEqual(meta["device_dsp_database"], "DeviceDSPDatabase.plist")
            self.assertEqual(plistlib.loads(col.bundle["DeviceDSPDatabase.plist"]), entry)
            self.assertIn("AID35/DSP/DSPDatabase.plist", col.bundle)
            # Headphone-only shared files, the generic database and a
            # loudness manager that does not list this AID stay out.
            self.assertEqual(meta["shared_files"], [])
            self.assertIsNone(meta["loudness_manager"])
            self.assertFalse(any(p.startswith(("Common/", "DRC/", "Generic")) for p in col.bundle))
            self.roundtrip(col, tmp)

    def test_macos27_entry_is_kept_byte_for_byte(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            layout27(root)
            # Apple's irregular mode names must survive unchanged.
            entry = {"AID35": {"Built-in Speaker": {
                "48k - Movie- SSI": {"UnderlyingDeviceProperties": [{"Selector": "spid", "Value": 0}]},
                "48k - Dictation": {},
                "48k - Dictation ": {"UnderlyingDeviceProperties": [{"Selector": "spid", "Value": 65535}]},
            }}}
            data = plistlib.dumps(entry, fmt=plistlib.FMT_BINARY)
            (root / "AID35" / "DSP" / "DSPDatabase.plist").write_bytes(data)
            col = collect(root)
            self.assertEqual(col.bundle["DeviceDSPDatabase.plist"], data)
            self.assertEqual(col.bundle["AID35/DSP/DSPDatabase.plist"], data)
            self.assertEqual(sorted(plistlib.loads(col.bundle["DeviceDSPDatabase.plist"])
                                    ["AID35"]["Built-in Speaker"]),
                             ["48k - Dictation", "48k - Dictation ", "48k - Movie- SSI"])
            self.roundtrip(col, tmp)

    def test_folder_database_with_other_keys_is_reduced_to_the_entry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            entry = layout27(root)
            both = dict(entry, AID99={"Built-in Speaker": {}})
            (root / "AID35" / "DSP" / "DSPDatabase.plist").write_bytes(plistlib.dumps(both))
            self.assertEqual(plistlib.loads(collect(root).bundle["DeviceDSPDatabase.plist"]), entry)

    def test_folder_entry_wins_over_the_shared_database(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            entry = layout27(root, shared_db=True)
            meta = json.loads(collect(root).bundle["manifest.json"])
            self.assertEqual(meta["device_dsp_database_source"], "AID35/DSP/DSPDatabase.plist")
            self.assertEqual(plistlib.loads(collect(root).bundle["DeviceDSPDatabase.plist"]), entry)

    def test_speaker_references_into_common_are_collected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            layout27(root, speaker_paths=("AID35/ADM/config.plist",
                                          "Common/Strips/shared_speaker.austrip"))
            loudness(root, ["AID35", "AID44"])
            col = collect(root)
            meta = json.loads(col.bundle["manifest.json"])
            self.assertEqual([r["path"] for r in meta["shared_files"]],
                             ["Common/Strips/shared_speaker.austrip"])
            self.assertEqual(meta["loudness_manager"]["path"], "DRC/loudness-manager.plist")
            self.assertNotIn("Common/Graphs/builtin_headphone_out.dspg", col.bundle)
            names = [n for n, _ in col.files()]
            self.assertIn("apple/audio-tuning/Common/Strips/shared_speaker.austrip", names)
            self.assertIn("apple/audio-tuning/DRC/loudness-manager.plist", names)
            # Schema 2 readers only look at `files`, which is unchanged.
            self.assertFalse(any(r["path"].startswith(("Common/", "DRC/")) for r in meta["files"]))
            out, bundle = self.roundtrip(col, tmp)
            (bundle / "Common" / "Strips" / "shared_speaker.austrip").write_bytes(b"changed")
            self.assertEqual(AudioTuningFWCollection(str(out)).bundle, {})

    def test_bad_references_leave_the_tuning_out(self):
        cases = {
            "missing shared file": ("Common/Strips/gone.austrip",),
            "missing folder file": ("AID35/DSP/Strips/gone.austrip",),
            "outside Common": ("Mac-0000000000000000/Strips/x.austrip",),
            "another AID": ("AID36/DSP/Strips/x.austrip",),
            "traversal": ("Common/../AID36/x",),
            "absolute": ("/etc/passwd",),
            "bare root": ("Common",),
        }
        for name, paths in cases.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp)
                layout27(root, speaker_paths=paths)
                self.assertEqual(collect(root).bundle, {})

    def test_shared_link_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            layout27(root, speaker_paths=("Common/Strips/linked.austrip",))
            (root / "Common" / "Strips" / "linked.austrip").symlink_to("shared_speaker.austrip")
            self.assertEqual(collect(root).bundle, {})

    def test_malformed_loudness_manager_leaves_the_tuning_out(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            layout27(root)
            (root / "DRC" / "loudness-manager.plist").write_bytes(
                plistlib.dumps({"Supported_Hardware": "AID35"}))
            self.assertEqual(collect(root).bundle, {})

    def test_update_refuses_inconsistent_shared_records(self):
        def drop_shared(meta):
            meta["shared_files"] = []

        def shared_outside(meta):
            meta["shared_files"][0]["path"] = "DRC/x"

        def shared_duplicate(meta):
            meta["shared_files"].append(dict(meta["shared_files"][0]))

        def loudness_moved(meta):
            meta["loudness_manager"]["path"] = "Common/loudness.plist"

        edits = {
            "shared record dropped": drop_shared,
            "shared outside Common": shared_outside,
            "shared duplicate": shared_duplicate,
            "loudness moved": loudness_moved,
            "unknown source": lambda m: m.update(device_dsp_database_source="Elsewhere.plist"),
            "source for another AID": lambda m: m.update(
                device_dsp_database_source="AID36/DSP/DSPDatabase.plist"),
        }
        for name, edit in edits.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp) / "t"
                root.mkdir()
                layout27(root, speaker_paths=("Common/Strips/shared_speaker.austrip",))
                loudness(root, ["AID35"])
                col = collect(root)
                self.assertTrue(col.bundle)
                out, bundle = self.roundtrip(col, tmp)
                rewrite(bundle, edit)
                self.assertEqual(AudioTuningFWCollection(str(out)).bundle, {})

    def test_update_refuses_a_loudness_manager_for_other_aids(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp) / "t"
            root.mkdir()
            layout27(root)
            loudness(root, ["AID35"])
            out, bundle = self.roundtrip(collect(root), tmp)
            data = plistlib.dumps({"Supported_Hardware": ["AID44"]})
            (bundle / "DRC" / "loudness-manager.plist").write_bytes(data)
            rewrite(bundle, lambda m: m["loudness_manager"].update(
                bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
            self.assertEqual(AudioTuningFWCollection(str(out)).bundle, {})

    def test_bundles_without_the_new_keys_still_verify(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, bundle = fallback(tmp)
            rewrite(bundle, lambda m: [m.pop(k) for k in
                                       ("device_dsp_database_source", "shared_files",
                                        "loudness_manager")])
            self.assertTrue(AudioTuningFWCollection(str(out)).bundle)


class LatticeTest(unittest.TestCase):
    """The lsm2 masker lattice: exactly one from the component, or no bundle."""

    def collect_with(self, root, component):
        path = root / "component"
        path.write_bytes(component)
        return AudioTuningFWCollection(tunings_root=str(root), run=fake_run(AID35),
                                       audiodsp=str(path))

    def test_the_bundle_carries_the_lattice_and_its_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            col = collect(root)
            self.assertEqual(col.bundle["lsm2-mask-lattice.bin"], LATTICE)
            meta = json.loads(col.bundle["manifest.json"])
            self.assertEqual(meta["lsm2_mask_lattice"], {
                "path": "lsm2-mask-lattice.bin", "bytes": 800,
                "sha256": hashlib.sha256(LATTICE).hexdigest(),
                "version": 1, "format": "u64le-exclusive-ends", "entries": 100})
            # Not a tuning folder file: the count is the folder's alone.
            self.assertEqual(meta["source_file_count"], 2)
            self.assertNotIn("lsm2-mask-lattice.bin", [r["path"] for r in meta["files"]])
    def test_missing_or_ambiguous_lattice_is_no_bundle_and_an_error(self):
        cases = {
            "missing": thin(b"\x11" * 2048),
            "ambiguous": thin(padded(LATTICE) + padded(other_lattice())),
            "slices disagree": fat(thin(padded(LATTICE), cpu=CPU_X86_64),
                                   thin(padded(other_lattice()))),
            "not a Mach-O file": b"not a component",
        }
        for name, component in cases.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp)
                tunings(root)
                with self.assertLogs("asahi_firmware.audio_tuning", "ERROR") as logs:
                    col = self.collect_with(root, component)
                self.assertIn("lsm2 masker lattice", "\n".join(logs.output))
                self.assertEqual(col.bundle, {})
                self.assertEqual(col.files(), [])

    def test_absent_component_is_no_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            with self.assertLogs("asahi_firmware.audio_tuning", "ERROR"):
                col = AudioTuningFWCollection(tunings_root=str(root), run=fake_run(AID35),
                                              audiodsp=str(root / "absent"))
            self.assertEqual(col.bundle, {})

    def test_the_writer_refuses_a_bundle_without_a_valid_lattice(self):
        args = (35, {"a": b"x"}, None, "00A000",
                {"DeviceDSPDatabase.plist": plistlib.dumps({"AID35": {}}),
                 "Config/AID35.plist": b"c"})
        self.assertTrue(audio_tuning.tree(*args, lattice=LATTICE,
                                          velocity_parameter_max=VELOCITY_PARAMETER_MAX))
        for bad in (None, b"", LATTICE[:-8], b"\0" * 800):
            with self.assertRaisesRegex(ValueError, "lattice"):
                audio_tuning.tree(*args, lattice=bad,
                                  velocity_parameter_max=VELOCITY_PARAMETER_MAX)

    def test_update_reverifies_the_lattice(self):
        valid_but_other = other_lattice()

        def replace(bundle, data):
            (bundle / "lsm2-mask-lattice.bin").write_bytes(data)
            rewrite(bundle, lambda m: m["lsm2_mask_lattice"].update(
                bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))

        damaged = bytearray(LATTICE)
        damaged[-8:] = (320).to_bytes(8, "little")
        edits = {
            "changed bytes": lambda b: (b / "lsm2-mask-lattice.bin").write_bytes(valid_but_other),
            "rehashed invalid table": lambda b: replace(b, bytes(damaged)),
            "short table": lambda b: replace(b, LATTICE[:-8]),
            "unknown version": lambda b: rewrite(b, lambda m: m["lsm2_mask_lattice"].update(version=2)),
            "unknown format": lambda b: rewrite(b, lambda m: m["lsm2_mask_lattice"].update(format="x")),
            "other path": lambda b: rewrite(b, lambda m: m["lsm2_mask_lattice"].update(path="AID35/x")),
            "not a record": lambda b: rewrite(b, lambda m: m.update(lsm2_mask_lattice=[])),
            "file missing": lambda b: (b / "lsm2-mask-lattice.bin").unlink(),
        }
        for name, edit in edits.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                out, bundle = fallback(tmp)
                edit(bundle)
                self.assertEqual(AudioTuningFWCollection(str(out)).bundle, {})
        with tempfile.TemporaryDirectory() as tmp:
            out, bundle = fallback(tmp)
            replace(bundle, valid_but_other)
            self.assertEqual(AudioTuningFWCollection(str(out)).bundle["lsm2-mask-lattice.bin"],
                             valid_but_other)

    def test_a_bundle_collected_before_the_lattice_still_verifies_with_a_warning(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, bundle = fallback(tmp)
            (bundle / "lsm2-mask-lattice.bin").unlink()
            rewrite(bundle, lambda m: m.pop("lsm2_mask_lattice"))
            with self.assertLogs("asahi_firmware.audio_tuning", "WARNING") as logs:
                col = AudioTuningFWCollection(str(out))
            self.assertIn("no lsm2 masker lattice", "\n".join(logs.output))
            self.assertTrue(col.bundle)
            self.assertNotIn("lsm2-mask-lattice.bin", col.bundle)


if __name__ == "__main__":
    unittest.main()


# A made-up serial number, as macOS pads it in the device tree root.
SERIAL = b"SYNTHETIC0A".ljust(32, b"\0")
ROOT = {"target-type": b"J616s\0", "serial-number": SERIAL, "IOPlatformSerialNumber": "SYNTHETIC0A"}


class LSM2MetadataTest(unittest.TestCase):
    def test_synthetic_parameter_families_have_one_collected_maximum(self):
        records = [(name, VELOCITY_PARAMETER_MAX)
                   for _family in range(4) for name in lsm2_metadata.PARAMETER_NAMES]
        self.assertEqual(lsm2_metadata.velocity_parameter_max(records),
                         VELOCITY_PARAMETER_MAX)
        encoded = lsm2_metadata.encode(VELOCITY_PARAMETER_MAX)
        self.assertEqual(lsm2_metadata.decode(encoded), VELOCITY_PARAMETER_MAX)

    def test_missing_nonfinite_and_inconsistent_metadata_is_refused(self):
        for records in [
                [("VelocityLimit0", 1.75), ("VelocityLimit1", 1.75)],
                [("VelocityLimit0", 1.75), ("VelocityLimit1", 1.75),
                 ("VelocityLimit2", float("nan"))],
                [("VelocityLimit0", 1.75), ("VelocityLimit1", 1.5),
                 ("VelocityLimit2", 1.75)],
                [("VelocityLimit0", 1.75), ("VelocityLimit0", 1.75),
                 ("VelocityLimit1", 1.75), ("VelocityLimit2", 1.75)],
        ]:
            with self.subTest(records=records), self.assertRaises(lsm2_metadata.MetadataError):
                lsm2_metadata.velocity_parameter_max(records)

    def test_bundle_metadata_is_hashed_reverified_and_optional_for_old_bundles(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, bundle = fallback(tmp)
            metadata = bundle / "lsm2-metadata.json"
            manifest = json.loads((bundle / "manifest.json").read_bytes())
            self.assertEqual(manifest["lsm2_metadata"]["sha256"],
                             hashlib.sha256(metadata.read_bytes()).hexdigest())
            metadata.write_bytes(lsm2_metadata.encode(1.5))
            self.assertFalse(AudioTuningFWCollection(str(out)).bundle)
        with tempfile.TemporaryDirectory() as tmp:
            out, bundle = fallback(tmp)
            (bundle / "lsm2-metadata.json").unlink()
            rewrite(bundle, lambda manifest: manifest.pop("lsm2_metadata"))
            with self.assertLogs("asahi_firmware.audio_tuning", "WARNING") as logs:
                collected = AudioTuningFWCollection(str(out))
            self.assertTrue(collected.bundle)
            self.assertIn("parameter metadata", "\n".join(logs.output))


class IdentityTest(unittest.TestCase):
    def collect(self, root, nodes=None):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = pathlib.Path(tmp.name)
        tunings(base)
        nodes = nodes or [{"acoustic-id": b"\x23\0\0\0", "speaker-thiele-small": bytes(range(16))}]
        col = AudioTuningFWCollection(tunings_root=str(base), run=fake_run(nodes, root=root))
        self.assertTrue(col.bundle)
        return col, base

    def test_unit_id_rule(self):
        want = hashlib.sha256(b"aurora-speaker-unit-v1\0SYNTHETIC0A").hexdigest()
        self.assertEqual(audio_tuning.unit_id(SERIAL), want)
        # The vector every implementation shares (Python, Rust, Swift).
        self.assertEqual(want, "22fea1b624a25cb3e103ed668fc37e1ef5c0d445e195029caf273827923c793d")
        # Linux's copy (one NUL) is the same unit.
        self.assertEqual(audio_tuning.unit_id(b"SYNTHETIC0A\0"), want)
        self.assertNotEqual(audio_tuning.unit_id(b"SYNTHETIC0A"), hashlib.sha256(b"SYNTHETIC0A").hexdigest())
        for raw in (b"", b"\0" * 32, b"A B", b"A\0B", b"\xff", b"A" * 65, "SYNTHETIC0A", None):
            self.assertIsNone(audio_tuning.unit_id(raw), raw)
        self.assertEqual(audio_tuning.board_name(b"J616s\0"), "j616s")
        self.assertEqual(audio_tuning.board_name("J413AP"), "j413")
        for raw in (b"", b"AP", b"J 413", b"Mac14,2", b"J1234567890", None, 7):
            self.assertIsNone(audio_tuning.board_name(raw), raw)

    def test_the_manifest_names_the_board_and_unit_never_the_serial(self):
        col, _ = self.collect(ROOT)
        meta = json.loads(col.bundle["manifest.json"])
        self.assertEqual(meta["board"], "j616s")
        self.assertEqual(meta["unit_id"], audio_tuning.unit_id(SERIAL))
        for data in col.bundle.values():
            self.assertNotIn(b"SYNTHETIC0A", data)

    def test_an_unreadable_identity_still_collects_without_it(self):
        for root in (None, {}, {"serial-number": b"NOT ONE"}, OSError("ioreg")):
            col, _ = self.collect(root)
            meta = json.loads(col.bundle["manifest.json"])
            self.assertIsNone(meta["unit_id"], root)
        meta = json.loads(self.collect({"serial-number": SERIAL})[0].bundle["manifest.json"])
        self.assertEqual((meta["board"], meta["unit_id"]), (None, audio_tuning.unit_id(SERIAL)))

    def test_update_keeps_and_checks_the_identity(self):
        col, base = self.collect(ROOT)
        out = base / "fallback"
        self.assertTrue(col.write_fallback(str(out)))
        again = AudioTuningFWCollection(str(out))
        self.assertEqual(again.bundle, col.bundle)
        path = out / "audio-tuning" / "manifest.json"
        good = json.loads(path.read_bytes())
        for key, bad in (("board", "J616sAP"), ("board", ""), ("board", 616), ("unit_id", "ABC"),
                         ("unit_id", good["unit_id"].upper()), ("unit_id", 7)):
            meta = dict(good, **{key: bad})
            path.write_text(json.dumps(meta))
            self.assertEqual(AudioTuningFWCollection(str(out)).files(), [], (key, bad))
        # A bundle collected before the identity still verifies, with a warning.
        meta = {k: v for k, v in good.items() if k not in ("board", "unit_id")}
        path.write_text(json.dumps(meta))
        with self.assertLogs("asahi_firmware.audio_tuning", "WARNING") as logs:
            self.assertTrue(AudioTuningFWCollection(str(out)).files())
        self.assertTrue(any("does not name the Mac" in m for m in logs.output))
