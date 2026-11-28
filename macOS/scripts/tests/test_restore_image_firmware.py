"""Every Mac the sealed policy admits gets each firmware class its restore image carries.

restore-image-firmware.json records, per admitted restore image and Mac, what the
Mac's build identity carries (scripts/restore_image_firmware.py writes it from the
images). These tests fail when the policy admits an image or Mac the record lacks,
or when a class the image carries has no collector or source: the N1 Wi-Fi and
Bluetooth image and ticket, speaker tuning, the radios of the other Macs.
Synthetic bytes only.
"""
import json
import re
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT.parent))

from asahi_firmware import centauri  # noqa: E402

POLICY_SOURCE = ROOT / 'Sources/AuroraAppleInstaller/NativeInspectionPolicySource.swift'
RECORD = ROOT / 'scripts/restore-image-firmware.json'
KERNEL = ROOT / 'scripts/n1-kernel-firmware.json'
SPEAKER = ROOT / 'Sources/AuroraFirmware/Resources/speaker-tuning/index.json'
RADIO = ROOT / 'Sources/AuroraFirmware/Resources/radio-firmware/index.json'
BROADCOM = ROOT / 'Sources/AuroraFirmware/BroadcomFirmware.swift'
NEO_RECIPE_BUILD = '25G83'

# Macs the policy admits whose restore image the speaker tuning pin does not
# cover yet: no tuning is collected and Linux keeps their speakers muted.
UNTUNED = {'j804', 'j833ct'}
# The MacBook Neo's camera and radio firmware comes from the 25G83 recipe
# (Resources/j700-25G83-ranges.json) whatever stub it gets; the 26.6 (25G72)
# stub is still admitted for it. Open: a 25G72 recipe or drop the entry.
NEO_STUB_MISMATCH = {('25G72', 'j700')}

# SEQUENCE { IA5String "IM4M", INTEGER 0 }, as tests/test_centauri.py.
IMAGE = bytes(0x20) + b'rkosftab' + bytes(8) + b'synthetic N1 image'
TICKET = bytes([0x30, 0x09, 0x16, 0x04]) + b'IM4M' + bytes([0x02, 0x01, 0x00])


def sealed_policy():
    text = POLICY_SOURCE.read_text()
    start = text.index('#"""') + len('#"""')
    return json.loads(text[start:text.index('"""#', start)])


def admitted(policy, record):
    """(build, machine, identity record) for every Mac each image is admitted for."""
    out = []
    for entry, image in zip(policy['firmware'], record['images']):
        for machine, identity in image['identities'].items():
            if entry['models'] is None or machine in entry['models']:
                out.append((image['build'], machine, identity))
    return out


class RestoreImageFirmwareTests(unittest.TestCase):
    def setUp(self):
        self.policy = sealed_policy()
        self.record = json.loads(RECORD.read_text())
        self.kernel = json.loads(KERNEL.read_text())['names']
        self.rows = admitted(self.policy, self.record)

    def test_the_record_covers_every_admitted_image_and_mac(self):
        self.assertEqual(self.record['schema'], 1)
        self.assertEqual(
            [entry['sourceURL'] for entry in self.policy['firmware']],
            [image['url'] for image in self.record['images']],
            'regenerate restore-image-firmware.json with scripts/restore_image_firmware.py')
        for entry, image in zip(self.policy['firmware'], self.record['images']):
            if entry['models'] is not None:
                self.assertEqual(sorted(entry['models']), sorted(image['identities']), image['build'])
            if 'pin' in entry:
                self.assertEqual(entry['pin']['build'], image['build'])
        machines = {machine for _, machine, _ in self.rows}
        self.assertTrue(set(self.policy['devices']) <= machines)

    def test_every_n1_mac_gets_its_image_and_ticket_under_the_name_its_driver_requests(self):
        n1 = {machine for _, machine, identity in self.rows if identity['n1_images']}
        self.assertTrue({'j714s', 'j813', 'j873g', 'k114s', 'k116s'} <= n1)
        self.assertEqual(set(self.kernel), n1, 'n1-kernel-firmware.json must name every N1 Mac')
        for build, machine, identity in self.rows:
            with self.subTest(build=build, machine=machine):
                if not identity['n1_images']:
                    self.assertNotIn('n1_ticket', identity)
                    continue
                # One image and the model's ticket in the stub's restore manifests:
                # anything else installs without Wi-Fi and Bluetooth.
                self.assertEqual(identity['n1_images'], 1)
                self.assertTrue(identity['n1_ticket'])
                name = centauri.firmware_name(machine)
                if self.kernel[machine] is not None:
                    self.assertEqual(name, self.kernel[machine])
                else:
                    self.assertEqual(name, f'apple/centauri/{machine}-ftab.bin')
                with tempfile.TemporaryDirectory() as tmp:
                    directory = Path(tmp, machine)
                    directory.mkdir()
                    (directory / centauri.IMAGE).write_bytes(IMAGE)
                    (directory / centauri.ticket_name(machine)).write_bytes(TICKET)
                    files = dict(centauri.CentauriFWCollection(tmp).files())
                self.assertEqual(list(files), [name])
                self.assertTrue(centauri.owned(name))

    def test_every_admitted_mac_has_a_speaker_tuning_image(self):
        index = json.loads(SPEAKER.read_text())
        tuned = {board[:-2] for image in index['images'] for board in image['boards']}
        devices = set(self.policy['devices'])
        self.assertEqual(devices - tuned, UNTUNED)
        self.assertFalse(UNTUNED & tuned, 'a tuned Mac is still listed as untuned')

    def test_every_other_mac_has_a_radio_source_of_its_stub_image(self):
        index = json.loads(RADIO.read_text())
        recipes = {image['build']: set(image['boards']) for image in index['images']}
        broadcom = BROADCOM.read_text()
        start = broadcom.index('= [', broadcom.index('m4ProMaxWiFi'))
        m4 = set(re.findall(r'"(j[0-9]+[a-z]*)":', broadcom[start:broadcom.index(']', start)]))
        self.assertEqual(m4, {'j614s', 'j614c', 'j616s', 'j616c'})
        mismatched = set()
        for build, machine, identity in self.rows:
            with self.subTest(build=build, machine=machine):
                if identity['n1_images']:
                    continue
                if machine == 'j700':
                    if build != NEO_RECIPE_BUILD:
                        mismatched.add((build, machine))
                    continue
                # The stub's own Recovery image carries the Broadcom set; an
                # M4 Pro or Max board needs its board from the same image's
                # System volume recipe.
                if machine in m4:
                    self.assertIn(machine + 'ap', recipes.get(build, set()))
        self.assertEqual(mismatched, NEO_STUB_MISMATCH)


if __name__ == '__main__':
    unittest.main()
