# SPDX-License-Identifier: MIT
"""The compiled-in speaker tuning pin is consistent: the generator pins the
index, the index pins every recipe and names the pinned macOS 27.2 restore
images, and every recipe reads only tuning files and the AudioDSP component
from the image it names. Offsets and digests only; no network."""
import hashlib
import json
import pathlib
import re
import unittest

MACOS = pathlib.Path(__file__).resolve().parents[2]
RESOURCES = MACOS / "Sources" / "AuroraFirmware" / "Resources" / "speaker-tuning"
GENERATOR = MACOS / "Sources" / "AuroraFirmwareRecipeGenerator" / "main.swift"
TUNINGS = "System/Library/Audio/Tunings/"
COMPONENT = "System/Library/Components/AudioDSP.component/Contents/MacOS/AudioDSP"
PINNED = [
    ("26B123", "https://updates.cdn-apple.com/2026FallFCS/c9671975-52db-4fb5-9af2-00217169ba8d/"
               "UniversalMac_27.2_26B123_Restore.ipsw"),
    ("26B8125", "https://updates.cdn-apple.com/2026FallFCS/b83bb963-ebd8-4608-8b5d-fdc70cb24927/"
                "UniversalMac_27.2_26B8125_Restore.ipsw"),
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


class SpeakerTuningPinTest(unittest.TestCase):
    def setUp(self):
        self.raw = (RESOURCES / "index.json").read_bytes()
        self.index = json.loads(self.raw)

    def test_generator_pins_the_index(self):
        found = re.search(r'let speakerTuningIndexDigest = "([0-9a-f]{64})"', GENERATOR.read_text())
        self.assertIsNotNone(found)
        self.assertEqual(found.group(1), sha(self.raw))

    def test_the_pin_is_macos_27_2(self):
        self.assertEqual(self.index["schema"], 1)
        self.assertEqual(self.index["release"], "27.2")
        self.assertEqual([(i["build"], i["url"]) for i in self.index["images"]], PINNED)

    def test_every_recipe_is_pinned_and_reads_only_tuning(self):
        names = {p.name for p in RESOURCES.glob("*.json")} - {"index.json"}
        expected = set()
        boards = set()
        for image in self.index["images"]:
            self.assertFalse(boards & set(image["boards"]), "a board in two images")
            boards |= set(image["boards"])
            self.assertEqual({str(a) for a in image["boards"].values()}, set(image["recipes"]))
            for aid, digest in image["recipes"].items():
                name = f"{image['build']}-AID{aid}.json"
                expected.add(name)
                raw = (RESOURCES / name).read_bytes()
                self.assertEqual(sha(raw), digest, name)
                recipe = json.loads(raw)
                self.assertEqual(recipe["source"], {"url": image["url"],
                                                    "size_bytes": image["size_bytes"],
                                                    "sha256": image["sha256"]})
                files = [f["name"] for f in recipe["files"]]
                self.assertIn(COMPONENT, files)
                self.assertIn(f"{TUNINGS}Config/AID{aid}.plist", files)
                self.assertTrue(any(f.startswith(f"{TUNINGS}AID{aid}/") for f in files))
                for f in recipe["files"]:
                    self.assertEqual(f["name"], f["source"])
                    self.assertEqual(f["transform"], "identity")
                    self.assertTrue(f["name"] == COMPONENT or f["name"].startswith(TUNINGS))
                    self.assertFalse(f["name"].startswith(TUNINGS + "AID")
                                     and not f["name"].startswith(f"{TUNINGS}AID{aid}/"))
        self.assertEqual(names, expected)


if __name__ == "__main__":
    unittest.main()
