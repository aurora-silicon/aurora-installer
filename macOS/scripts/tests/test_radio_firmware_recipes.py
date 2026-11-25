# SPDX-License-Identifier: MIT
"""The compiled-in Wi-Fi firmware recipe list is consistent: the generator
pins the index, the index pins every recipe, every image is a stub restore
image of the sealed inspection policy, and every recipe reads only Wi-Fi
files of its board from that image. Offsets and digests only; no network."""
import hashlib
import json
import pathlib
import re
import sys
import unittest

MACOS = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(MACOS / "scripts"))
import radio_firmware_recipes  # noqa: E402

RESOURCES = MACOS / "Sources" / "AuroraFirmware" / "Resources" / "radio-firmware"
GENERATOR = MACOS / "Sources" / "AuroraFirmwareRecipeGenerator" / "main.swift"
WIFI = "usr/share/firmware/wifi/"


def sha(data):
    return hashlib.sha256(data).hexdigest()


class RadioFirmwarePinTest(unittest.TestCase):
    def setUp(self):
        self.raw = (RESOURCES / "index.json").read_bytes()
        self.index = json.loads(self.raw)

    def test_generator_pins_the_index(self):
        found = re.search(r'let radioFirmwareIndexDigest = "([0-9a-f]{64})"', GENERATOR.read_text())
        self.assertIsNotNone(found)
        self.assertEqual(found.group(1), sha(self.raw))

    def test_every_image_is_an_admitted_stub_and_every_recipe_its_board(self):
        policy = dict(radio_firmware_recipes.policy_images())
        names = {p.name for p in RESOURCES.glob("*.json")} - {"index.json"}
        expected = set()
        self.assertEqual(self.index["kind"], "aurora-radio-firmware-restore-images")
        for image in self.index["images"]:
            self.assertIn(image["url"], policy)
            models = policy[image["url"]]
            for device in image["boards"]:
                self.assertTrue(models is None or device[:-2] in models, device)
            self.assertEqual(set(image["boards"].values()), set(image["recipes"]))
            for board, digest in image["recipes"].items():
                name = f"{image['build']}-{board}.json"
                expected.add(name)
                raw = (RESOURCES / name).read_bytes()
                self.assertEqual(sha(raw), digest)
                recipe = json.loads(raw)
                self.assertEqual(recipe["source"]["url"], image["url"])
                self.assertEqual(recipe["source"]["sha256"], image["sha256"])
                self.assertTrue(recipe["files"])
                own = re.compile(rf"\A(P-)?{re.escape(board)}([-_.]|\Z)")
                for f in recipe["files"]:
                    self.assertEqual(f["name"], f["source"])
                    self.assertTrue(f["name"].startswith(WIFI))
                    self.assertTrue(own.match(f["name"].rsplit("/", 1)[-1]), f["name"])
        self.assertEqual(names, expected)


if __name__ == "__main__":
    unittest.main()
