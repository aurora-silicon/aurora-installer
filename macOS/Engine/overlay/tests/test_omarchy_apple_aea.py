# SPDX-License-Identifier: MIT
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
import omarchy_apple_aea as aea  # noqa: E402


DECODER = '/var/db/test/imported-handoff-1/omarchy-restore-image'
TEAM_REQUIREMENT = ('anchor apple generic and identifier "org.example.restore-image" '
                    'and certificate 1[field.1.2.840.113635.100.6.2.6] '
                    'and certificate leaf[field.1.2.840.113635.100.6.1.13] '
                    'and certificate leaf[subject.OU] = "ABCDE12345"')
AD_HOC_REQUIREMENT = 'identifier "org.example.restore-image" and cdhash H"' + 'a' * 40 + '"'


def locate():
    return DECODER


class DecoderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.helper = self.root / 'omarchy-restore-image'
        self.helper.write_bytes(b'\xcf\xfa\xed\xfe signed decoder')
        self.helper.chmod(0o500)
        self.commands = []

    def environment(self, requirement=TEAM_REQUIREMENT, path=None):
        return {aea.DECODER_ENVIRONMENT: str(path or self.helper), aea.REQUIREMENT_ENVIRONMENT: requirement}

    def accept(self, command, check, stdout, stderr):
        self.assertTrue(check)
        self.commands.append(command)

    def test_a_developer_id_or_pinned_ad_hoc_decoder_is_checked_with_codesign(self):
        for requirement in (TEAM_REQUIREMENT, AD_HOC_REQUIREMENT,
                            AD_HOC_REQUIREMENT.replace('a' * 40, 'b' * 64)):
            with self.subTest(requirement=requirement):
                self.commands.clear()
                path = aea.decoder(self.environment(requirement), run=self.accept)
                self.assertEqual(path, str(self.helper))
                self.assertEqual(self.commands, [[
                    '/usr/bin/codesign', '--verify', '--strict', '-R=' + requirement, str(self.helper)]])

    def test_without_the_apps_decoder_nothing_runs_not_even_a_bundled_or_path_copy(self):
        # Neither a copy beside the engine (older engines shipped bin/) nor
        # one on $PATH is ever a candidate: only the app's absolute path.
        self.assertFalse(hasattr(aea, 'DECODER'))
        for environment in ({}, {aea.REQUIREMENT_ENVIRONMENT: TEAM_REQUIREMENT},
                            {aea.DECODER_ENVIRONMENT: 'omarchy-restore-image',
                             aea.REQUIREMENT_ENVIRONMENT: TEAM_REQUIREMENT},
                            {'PATH': str(self.root), aea.REQUIREMENT_ENVIRONMENT: TEAM_REQUIREMENT}):
            with self.subTest(environment=environment), self.assertRaisesRegex(
                    aea.AppleInputError, 'passed no omarchy-restore-image'):
                aea.decoder(environment, run=self.accept)
        self.assertEqual(self.commands, [])

    def test_a_requirement_that_is_not_the_apps_is_refused(self):
        for requirement in ('', 'identifier "org.example.restore-image"',
                            TEAM_REQUIREMENT.replace('"ABCDE12345"', '"short"'),
                            AD_HOC_REQUIREMENT.replace('a' * 40, 'a' * 39),
                            TEAM_REQUIREMENT + ' or anchor apple',
                            AD_HOC_REQUIREMENT.replace('and cdhash', 'or cdhash'),
                            'identifier "x" or identifier "y" and cdhash H"' + 'a' * 40 + '"',
                            # Any Apple certificate of the team is not a Developer ID (TN3127).
                            'anchor apple generic and identifier "org.example.restore-image" '
                            'and certificate leaf[subject.OU] = "ABCDE12345"',
                            TEAM_REQUIREMENT.replace('certificate 1[field.1.2.840.113635.100.6.2.6] and ', ''),
                            'anchor apple generic'):
            with self.subTest(requirement=requirement), self.assertRaisesRegex(
                    aea.AppleInputError, 'requirement is missing'):
                aea.decoder(self.environment(requirement), run=self.accept)
        self.assertEqual(self.commands, [])

    def test_a_missing_linked_or_shared_decoder_is_refused(self):
        link = self.root / 'link'
        link.symlink_to(self.helper)
        shared = self.root / 'shared'
        shared.write_bytes(b'decoder')
        shared.chmod(0o777)
        cases = {self.root / 'missing': 'unavailable', link: 'not a private executable',
                 shared: 'not a private executable', self.root: 'not a private executable'}
        for path, message in cases.items():
            with self.subTest(path=path), self.assertRaisesRegex(aea.AppleInputError, message):
                aea.decoder(self.environment(path=path), run=self.accept)
        self.assertEqual(self.commands, [])

    def test_an_unsigned_or_differently_signed_decoder_is_refused(self):
        def reject(command, check, stdout, stderr):
            raise subprocess.CalledProcessError(3, command, stderr=b'test requirement unsatisfied')
        with self.assertRaisesRegex(aea.AppleInputError, "not the installer app's signed decoder"):
            aea.decoder(self.environment(), run=reject)

    def test_decrypt_and_radio_fetch_use_the_verified_decoder(self):
        source = self.root / 'image.dmg.aea'
        source.write_bytes(b'AEA1')
        calls = []

        def run(command, check, **kwargs):
            calls.append(command)
            if command[0] == '/usr/bin/codesign':
                return
            Path(command[3]).write_bytes(b'plain')

        environment = self.environment()
        aea.decrypt(source, self.root / 'image.dmg', run=run,
                    locate=lambda: aea.decoder(environment, run=run))
        self.assertEqual(calls[0][:3], ['/usr/bin/codesign', '--verify', '--strict'])
        self.assertEqual(calls[1][0], str(self.helper))


class DecryptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'image.dmg.aea'
        self.source.write_bytes(b'AEA1 archive')
        self.destination = self.root / 'image.dmg'
        self.commands = []

    def run_decoder(self, command, check):
        self.assertTrue(check)
        self.commands.append(command)
        Path(command[3]).write_bytes(b'plain')

    def test_the_decoder_gets_the_archive_and_its_digest(self):
        aea.decrypt(self.source, self.destination, run=self.run_decoder, locate=locate)
        self.assertEqual(self.commands, [[
            DECODER, str(self.source),
            hashlib.sha256(b'AEA1 archive').hexdigest(), str(self.destination),
        ]])
        self.assertEqual(self.destination.read_bytes(), b'plain')

    def test_an_existing_destination_is_never_overwritten(self):
        self.destination.write_bytes(b'keep')
        with self.assertRaisesRegex(aea.AppleInputError, 'already exists'):
            aea.decrypt(self.source, self.destination, run=self.run_decoder, locate=locate)
        self.assertEqual(self.commands, [])
        self.assertEqual(self.destination.read_bytes(), b'keep')

    def test_a_decoder_that_writes_nothing_is_an_error(self):
        with self.assertRaisesRegex(aea.AppleInputError, 'wrote no image.dmg'):
            aea.decrypt(self.source, self.destination, run=lambda command, check: None, locate=locate)


class RecipeTests(unittest.TestCase):
    def test_the_bundled_recipe_pins_the_25g83_radio_inputs(self):
        recipe = json.loads(aea.recipe())
        self.assertIn('25G83', recipe['source']['url'])
        names = {entry['name'] for entry in recipe['files']}
        for name in ('sunrise/IZUBA_W7932_2.bin', 'sunrise/IZUBA_wifi.cfg',
                     'bluetooth/MT7932_PTB_IzubaA_0.1.0.0_20251021141303.ptx'):
            self.assertIn(name, names)

    def test_a_damaged_recipe_is_refused(self):
        original = aea.RECIPE
        aea.RECIPE = original.replace('e', 'f', 1)
        self.addCleanup(setattr, aea, 'RECIPE', original)
        with self.assertRaisesRegex(aea.AppleInputError, 'damaged'):
            aea.recipe()


class NeoRadioRootTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.factory = Path(self.temporary.name) / 'FactoryData'
        self.factory.mkdir()
        self.commands = []

    def fetch(self, prefixes):
        def run(command, check):
            self.assertTrue(check)
            self.commands.append(command)
            self.assertEqual(Path(command[2]).read_bytes(), aea.recipe())
            for prefix in prefixes:
                (Path(command[4]) / prefix).mkdir(parents=True)
                (Path(command[4]) / prefix / 'file.bin').write_bytes(prefix.encode())
        return run

    def test_fetched_files_land_where_the_collector_reads_them(self):
        with aea.neo_radio_root(run=self.fetch(('sunrise', 'bluetooth', 'camera')),
                                factory_data=str(self.factory), locate=locate) as root:
            self.assertEqual(Path(root, aea.IZUBA, 'file.bin').read_bytes(), b'sunrise')
            self.assertEqual(Path(root, aea.BLUETOOTH, 'file.bin').read_bytes(), b'bluetooth')
            self.assertEqual(os.readlink(Path(root, aea.FACTORY_DATA)), str(self.factory))
        self.assertEqual(self.commands[0][:2], [DECODER, 'firmware-ranges'])
        self.assertEqual(self.commands[0][3], aea.RECIPE_SHA256)
        self.assertFalse(Path(root).exists())

    def test_without_the_apps_decoder_nothing_is_fetched(self):
        with self.assertRaisesRegex(aea.AppleInputError, 'passed no omarchy-restore-image'):
            with aea.neo_radio_root(run=self.fetch(('sunrise', 'bluetooth')), factory_data=str(self.factory),
                                    locate=lambda: aea.decoder({})):
                pass
        self.assertEqual(self.commands, [])

    def test_a_fetch_without_bluetooth_files_is_refused(self):
        with self.assertRaisesRegex(aea.AppleInputError, 'no bluetooth files'):
            with aea.neo_radio_root(run=self.fetch(('sunrise',)), factory_data=str(self.factory),
                                    locate=locate):
                pass


if __name__ == '__main__':
    unittest.main()
