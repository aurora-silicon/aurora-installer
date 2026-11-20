# SPDX-License-Identifier: MIT
"""The Python collector's bundles for the shared parity fixture.

The native installer's test (NativeAudioTuningParityTests) checks its own
bundles against the same expected.json, so both collectors write the same
bytes. Synthetic data only.
"""
import json
import os
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import audio_tuning_parity as parity  # noqa: E402


def tree(root):
    out = {}
    for path in sorted(pathlib.Path(root).rglob("*")):
        rel = path.relative_to(root).as_posix()
        if path.is_symlink():
            out[rel] = ("link", os.readlink(path))
        elif path.is_file():
            out[rel] = path.read_bytes()
    return out


class ParityFixtureTest(unittest.TestCase):
    def test_the_fixture_is_what_the_generator_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            parity.build(directory)
            self.assertEqual(tree(directory), tree(parity.ROOT))

    def test_each_case_is_the_expected_bundle(self):
        expected = json.loads(parity.EXPECTED.read_text())
        self.assertEqual(sorted(expected), sorted(parity.CASES))
        for name in sorted(parity.CASES):
            with self.subTest(case=name):
                bundle = parity.collect(parity.ROOT, name)
                self.assertEqual(parity.digests(bundle), expected[name])

    def test_the_cases_cover_both_layouts_and_the_fill(self):
        bundles = {name: parity.collect(parity.ROOT, name) for name in parity.CASES}
        manifests = {name: json.loads(b["manifest.json"]) for name, b in bundles.items()}
        self.assertIn("lsm2-param-fill.bin", bundles["aid97"])
        self.assertNotIn("lsm2_param_fill", manifests["aid98"])
        self.assertEqual(manifests["aid97"]["device_dsp_database_source"],
                         "DeviceDSPDatabase.plist")
        self.assertEqual(manifests["aid98"]["device_dsp_database_source"],
                         "AID98/DSP/DSPDatabase.plist")
        # macOS 27 with only its entry: copied byte for byte.
        self.assertEqual(bundles["aid99"]["DeviceDSPDatabase.plist"],
                         bundles["aid99"]["AID99/DSP/DSPDatabase.plist"])
        # Reduced entries are re-encoded as XML.
        for name in ("aid97", "aid98"):
            self.assertTrue(bundles[name]["DeviceDSPDatabase.plist"].startswith(b"<?xml"))
        self.assertIsNone(manifests["aid98"]["board"])
        self.assertIsNone(manifests["aid98"]["loudness_manager"])
        self.assertEqual(manifests["aid99"]["speaker_id"], 65535)
        self.assertNotIn("AID97/._ADM", bundles["aid97"])
        self.assertIn("Common/Strips/empty.plist", bundles["aid97"])


if __name__ == "__main__":
    unittest.main()
