"""Pinned firmware entries in the sealed policy match their qualification record."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
POLICY_SOURCE = ROOT / 'Sources/AuroraAppleInstaller/NativeInspectionPolicySource.swift'
QUALIFICATION = ROOT / 'scripts/firmware-qualification.json'
SUPPORTED = ROOT / 'scripts/supported-models.json'

BUILD = re.compile(r'^[0-9]{2}[A-Z][0-9]{1,5}[a-z]?$')
DIGEST = re.compile(r'^sha256:[0-9a-f]{64}$')
APPLE_CDN = 'https://updates.cdn-apple.com/'


def sealed_policy():
    text = POLICY_SOURCE.read_text()
    start = text.index('#"""') + len('#"""')
    end = text.index('"""#', start)
    return json.loads(text[start:end])


def qualification():
    return json.loads(QUALIFICATION.read_text())


class FirmwareQualificationTests(unittest.TestCase):
    def setUp(self):
        self.policy = sealed_policy()
        self.record = qualification()
        self.pinned = {entry['pin']['build']: entry for entry in self.policy['firmware'] if 'pin' in entry}

    def test_every_pinned_entry_has_a_record_and_back(self):
        self.assertEqual(self.record['schema_version'], 1)
        self.assertEqual(set(self.pinned), set(self.record['pins']))
        self.assertIn('26B123', self.pinned)

    def test_pin_fields_agree_with_the_record(self):
        for build, entry in self.pinned.items():
            pin, record = entry['pin'], self.record['pins'][build]
            self.assertRegex(build, BUILD)
            self.assertEqual(entry['version'], record['version'], build)
            self.assertEqual(entry['sourceURL'], record['source_url'], build)
            self.assertTrue(entry['sourceURL'].startswith(APPLE_CDN), build)
            self.assertTrue(entry['sourceURL'].endswith('_' + build + '_Restore.ipsw'), build)
            self.assertEqual(pin['sourceBytes'], record['source_bytes'], build)
            self.assertGreater(pin['sourceBytes'], 0, build)
            self.assertRegex(pin['manifestSHA256'], DIGEST)
            self.assertEqual(pin['manifestSHA256'], record['manifest_sha256'], build)
            self.assertFalse(entry['expert'], build)

    def test_models_are_exactly_the_qualified_and_cautioned_experimental_boards(self):
        manifest = json.loads(SUPPORTED.read_text())
        supported = {identifier.removeprefix('apple,') for identifier in manifest['supported']}
        caution = set(manifest['stage1_caution'])
        for build, entry in self.pinned.items():
            boards = self.record['pins'][build]['boards']
            experimental = self.record['pins'][build].get('experimental_boards', {})
            self.assertFalse(set(boards) & set(experimental), build)
            # A null model list would admit every Mac; a pinned entry always names its boards.
            self.assertIsInstance(entry['models'], list, build)
            self.assertEqual(sorted(entry['models']), sorted(set(boards) | set(experimental)), build)
            self.assertEqual(len(entry['models']), len(set(entry['models'])), build)
            for board, proof in boards.items():
                self.assertIn(board, supported, build + ' ' + board)
                self.assertIn(board, self.policy['devices'], build + ' ' + board)
                # A board is qualified by the kernel release that shipped its support
                # and a recorded hardware result, never by a plan.
                self.assertEqual(set(proof), {'kernel', 'distributions', 'evidence'}, board)
                self.assertTrue(proof['kernel'].strip(), board)
                self.assertTrue(proof['distributions'], board)
                self.assertTrue(proof['evidence'].startswith('https://github.com/aurora-silicon/'), board)
            for board, proof in experimental.items():
                self.assertIn(board, supported, build + ' ' + board)
                self.assertIn('apple,' + board, caution, build + ' ' + board)
                self.assertEqual(self.policy['devices'][board], {'expert': False, 'minimum': '27.2'})
                self.assertEqual(proof['qualification'], 'not_hardware_qualified')
                self.assertEqual(proof['device_tree'],
                                 'arch/arm64/boot/dts/apple/t6050-' + board + '.dts')
                self.assertTrue(proof['evidence'].endswith('/' + proof['device_tree']))
                self.assertTrue(proof['evidence'].startswith(
                    'https://github.com/aurora-silicon/linux/blob/'))
                self.assertEqual(proof['manifest_identity']['device_class'], board + 'ap')
                self.assertEqual(proof['manifest_identity']['chip_id'], '0x6050')
                self.assertRegex(proof['manifest_identity']['board_id'], r'^0x[0-9a-f]{2}$')

    def test_t6050_experimental_admission_keeps_the_verified_source_pin(self):
        expected = {'j714c': '0x0a', 'j714s': '0x08', 'j716c': '0x0e', 'j716s': '0x0c',
                    'j775c': '0x10', 'j775d': '0x12', 'j873s': '0x02'}
        record = self.record['pins']['26B123']
        self.assertEqual(set(record['boards']), {'j615', 'j713'})
        self.assertEqual({board: proof['manifest_identity']['board_id']
                          for board, proof in record['experimental_boards'].items()}, expected)
        pin = self.pinned['26B123']['pin']
        self.assertEqual(pin['sourceBytes'], 25595669503)
        self.assertEqual(pin['manifestSHA256'],
                         'sha256:0fbfae04175cde81ef36d273aa280d39ffe5a54eacba8494b45a59daca462510')
        oled = next(entry for entry in self.policy['firmware']
                    if '26B8125' in entry['sourceURL'])
        self.assertEqual(set(oled['models']), {'k114c', 'k114s', 'k116c', 'k116s'})

    def test_the_27_2_pin_is_last_so_it_wins_where_it_qualifies(self):
        # Selection keeps the last compatible entry in source order.
        self.assertEqual(self.policy['firmware'][-1].get('pin', {}).get('build'), '26B123')

    def test_27_2_1_is_not_admitted(self):
        for entry in self.policy['firmware']:
            self.assertNotIn('26B131', entry['sourceURL'])
            self.assertNotIn('27.2.1', entry['version'])


if __name__ == '__main__':
    unittest.main()
