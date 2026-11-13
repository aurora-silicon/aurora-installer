"""Offline checks of the conformance harness: fixture privacy, mode derivation,
Stage 2 parsing and the plan and verdict rules. No network, no Swift build."""
import gzip
import importlib.util
import json
from pathlib import Path
import re
import struct
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('conformance', HERE / 'conformance.py')
conformance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(conformance)
CONSTRAINTS = json.loads((HERE / 'fixtures/constraints.json').read_text())
MACHINES = {p.stem: json.loads(p.read_text()) for p in (HERE / 'fixtures/machines').glob('*.json')}


def fdt(compatible):
    strings = b'compatible\0'
    value = compatible.encode() + b'\0'
    value += b'\0' * (-len(value) % 4)
    body = struct.pack('>I', 1) + b'\0\0\0\0' + struct.pack('>III', 3, len(compatible) + 1, 0) + value
    body += struct.pack('>II', 2, 9)
    header_size = 40
    total = header_size + len(body) + len(strings)
    header = struct.pack('>IIIIIIIIII', 0xd00dfeed, total, header_size, header_size + len(body), 0, 17, 16, 0,
                         len(strings), len(body))
    return header + body + strings


class EnrollmentTests(unittest.TestCase):
    SELECTION = (HERE.parent.parent / 'Recovery/Sources/BootSelection.swift').read_text()
    MACHO = {'stage1_mode': 'macho', 'stage2_path': 'm1n1/boot-ctxr.bin'}
    STANDARD = {'stage1_mode': 'macho-standard', 'stage2_path': 'm1n1/boot.bin'}
    RAW = {'stage1_mode': 'raw', 'stage2_path': 'm1n1/boot.bin'}

    def test_a_window_chip_expects_the_padded_compressed_path(self):
        ok, how = conformance.enrollment_check(self.SELECTION, True, [self.MACHO])
        self.assertTrue(ok)
        self.assertIn('--compress', how)
        self.assertNotIn('--raw', how)
        for chain in (self.RAW, self.STANDARD, {'stage1_mode': 'macho', 'stage2_path': 'm1n1/boot.bin'}, {}):
            self.assertFalse(conformance.enrollment_check(self.SELECTION, True, [self.MACHO, chain])[0], chain)
        self.assertFalse(conformance.enrollment_check(self.SELECTION.replace('--compress', ''), True, [self.MACHO])[0])

    def test_other_chips_expect_the_unpadded_mach_o_object(self):
        ok, how = conformance.enrollment_check(self.SELECTION, False, [self.STANDARD, {}])
        self.assertTrue(ok)
        self.assertNotIn('--raw', how)
        self.assertNotIn('--compress', how)
        for chain in (self.RAW, self.MACHO):
            self.assertFalse(conformance.enrollment_check(self.SELECTION, False, [chain])[0], chain)

    def test_any_raw_enrollment_fails_every_chip(self):
        self.assertNotIn('"--raw"', self.SELECTION)
        raw = self.SELECTION.replace(
            'var arguments = ["configure-boot", "-c", stage1, "-v", volume]',
            'var arguments = ["configure-boot", "-c", stage1, "-v", volume, "--raw"]')
        self.assertNotEqual(raw, self.SELECTION)
        for window, chain in ((True, self.MACHO), (False, self.STANDARD)):
            self.assertFalse(conformance.enrollment_check(raw, window, [chain])[0])

    def confined(self, chain, stage2=None):
        machine = {'device_identifier': 'apple,j700'}
        dry = {d: {'boot_chain': chain} for d in conformance.DESKTOPS}
        profiles = {d: {'payload': {'confined_stage2': stage2 or {}}} for d in conformance.DESKTOPS}
        return {c['check']: c for c in conformance.confined_stage2_checks(machine, dry, profiles, ['1.0.0b6'])}

    def test_a_payload_without_it_fails_only_the_published_scope(self):
        checks = self.confined({'confined_stage2_missing': True, 'esp_layout': {}})
        self.assertIsNone(checks['confined stage2']['ok'])
        self.assertIn('not present', checks['confined stage2']['detail'])
        self.assertFalse(checks['published confined stage2']['ok'])
        self.assertEqual(checks['published confined stage2']['scope'], 'published')
        # Not a failure at the pin, and not a pass either: nothing was read.
        self.assertEqual(conformance.verdict(list(checks.values()), True), 'UNTESTED-ON-HW')
        self.assertEqual(conformance.verdict(list(checks.values())), 'FAIL')

    def test_a_payload_with_it_is_checked_like_a_board_stage_two(self):
        layout = {'esp/m1n1/boot-ctxr-j700.bin': 'm1n1/boot-ctxr.bin'}
        good = {'device_trees': [{'compatible': 'apple,j700'}], 'u_boot': '2026.07',
                'versions': ['##aura_ver##1.0.0b6']}
        chain = {'confined_stage2_missing': False, 'esp_layout': layout}
        checks = self.confined(chain, {'esp/m1n1/boot-ctxr-j700.bin': good})
        self.assertTrue(checks['confined stage2']['ok'])
        self.assertTrue(checks['published confined stage2']['ok'])
        other = dict(good, device_trees=[{'compatible': 'apple,j700'}, {'compatible': 'apple,j413'}])
        self.assertFalse(self.confined(chain, {'esp/m1n1/boot-ctxr-j700.bin': other})['confined stage2']['ok'])
        self.assertFalse(self.confined(chain)['confined stage2']['ok'])
        self.assertTrue(conformance.CONFINED_MEMBER.fullmatch('esp/m1n1/boot-ctxr.bin'))
        self.assertFalse(conformance.CONFINED_MEMBER.fullmatch('esp/m1n1/boot-j700.bin'))


class FixtureTests(unittest.TestCase):
    def test_fixtures_are_scrubbed(self):
        for name, machine in MACHINES.items():
            text = json.dumps(machine)
            for value in re.findall(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', text):
                self.assertTrue(value.startswith('00000000-0000-4000-8000-') or value in conformance.TYPE_NAMES,
                                '%s carries a real UUID' % name)
            for word in ('serial', 'ecid', 'unique-chip', 'mac-address'):
                self.assertNotIn(word, text.lower(), name)

    def test_every_fixture_chip_is_known(self):
        for machine in MACHINES.values():
            self.assertIn(machine['soc'], CONSTRAINTS['chip_ids'])

    def test_fresh_mode_keeps_only_macos(self):
        for name, machine in MACHINES.items():
            if not machine['disk']:
                continue
            fresh = conformance.swift_machine(machine, 'fresh', CONSTRAINTS)
            kinds = [p['type'] for p in fresh['snapshot']['partitions']]
            # The M1 Pro's disk has no recoveryOS container: its Linux root runs to the end.
            captured = {conformance.TYPE_NAMES[p['type']] for p in machine['disk']['partitions']}
            want = ['Apple_APFS_ISC', 'Apple_APFS'] + ['Apple_APFS_Recovery'] * ('Apple_APFS_Recovery' in captured)
            self.assertEqual(sorted(kinds), sorted(want), name)
            kept = conformance.swift_machine(machine, 'side-by-side', CONSTRAINTS)
            self.assertEqual(len(kept['snapshot']['partitions']), len(machine['disk']['partitions']))
            systems = [s for c in kept['containers'] for s in c['systems']]
            self.assertEqual(len([s for s in systems if not s['stub']]), 1, name)

    def test_identity_only_fixture_gets_a_synthetic_disk(self):
        machine = dict(MACHINES['m1pro'], disk=None)
        result = conformance.swift_machine(machine, 'fresh', CONSTRAINTS)
        self.assertEqual(result['hardware']['chipID'], 0x6000)
        self.assertEqual(result['snapshot']['partitions'][1]['type'], 'Apple_APFS')

    def test_j773g_identity_only_profile_resolves_the_t8132_chip(self):
        machine = {
            'device_identifier': 'apple,j773g',
            'soc': 't8132',
            'firmware': {'system_iboot': 'mBoot-18000.161.10', 'system_os': '27.0'},
            'disk': None,
        }
        result = conformance.swift_machine(machine, 'fresh', CONSTRAINTS)
        self.assertEqual(result['deviceIdentifier'], 'apple,j773g')
        self.assertEqual(result['hardware']['chipID'], 0x8132)
        self.assertEqual(result['snapshot']['partitions'][1]['type'], 'Apple_APFS')


class Stage2Tests(unittest.TestCase):
    def test_reads_device_trees_uboot_and_version(self):
        uboot = bytearray(0x100)
        uboot[0x38:0x3c] = b'ARM\x64'
        uboot += b'U-Boot 2026.07-g2409ad5a25f8 (Oct 29 2026)'
        blob = b'##aura_ver##1.0.0b1\0' + b'\0' * 12 + b'STACKBOT' + fdt('apple,j413') + gzip.compress(bytes(uboot))
        contents = conformance.stage2_contents(blob)
        self.assertEqual(contents['versions'], ['##aura_ver##1.0.0b1'])
        self.assertEqual(contents['device_trees'], [{'compatible': 'apple,j413'}])
        self.assertEqual(contents['u_boot'], '2026.07-g2409ad5a25f8')


class RuleTests(unittest.TestCase):
    def test_published_checks_do_not_change_the_at_pin_verdict(self):
        checks = [conformance.check('stage1', True, ''),
                  conformance.check('published stage1', False, '', scope='published')]
        self.assertEqual(conformance.verdict(checks), 'FAIL')
        self.assertEqual(conformance.verdict(checks, at_pin=True), 'PASS')
        checks.append(conformance.check('1tr', True, '', 'run it'))
        self.assertEqual(conformance.verdict(checks, at_pin=True), 'UNTESTED-ON-HW')

    def test_plan_that_overlaps_a_kept_partition_fails(self):
        machine = MACHINES['m2']
        macos = conformance.macos_partition(machine['disk']['partitions'])
        firmware = {'stub_bytes': 2499805184}
        start = macos['offset'] + macos['size'] - 4096 * 256
        result = {'candidates': [{'kind': 'free', 'source': 'disk0s2', 'length_bytes': 30 << 30,
                                  'minimum_container_bytes': 0, 'minimum_install_bytes': 0,
                                  'plan': {'offset_bytes': start, 'length_bytes': 30 << 30, 'os_partitions': []}}]}
        self.assertFalse(conformance.plan_check(machine, 'fresh', result, firmware)['ok'])

    def test_no_candidate_reports_the_shortfall(self):
        machine = MACHINES['m2']
        result = {'candidates': [{'kind': 'resize', 'source': 'disk0s2', 'length_bytes': 1, 'minimum_install_bytes':
                                  14 << 30, 'minimum_container_bytes': 0, 'plan_error': 'invalidRequestedLength'}]}
        check = conformance.plan_check(machine, 'side-by-side', result, {'stub_bytes': 0})
        self.assertFalse(check['ok'])
        self.assertIn('free about', check['detail'])


class CautionTests(unittest.TestCase):
    """A stage1_caution board is warned, then goes ahead; any other board is never warned."""

    CAUTION = {'headline': 'Aurora may not start on this Mac yet', 'reason': 'iBoot may refuse it.',
               'recovery': 'If the Mac shows \u201cmacOS needs to be reinstalled\u201d: choose Always Use, '
                           'then use Erase Linux.',
               'acknowledgement': 'I approve the disk layout above, and I understand Aurora may not start on this Mac.',
               'acknowledgement_resize': 'I approve the disk resize above, and I understand Aurora may not start on '
                                         'this Mac.'}

    def dry(self, caution, supported=True, stage1=True):
        row = {'supported': supported, 'boot_chain': {'stage1_member': 'esp/aurora/stage1.bin'} if stage1 else {},
               'candidates': [{'plan': {}}]}
        if caution:
            row['stage1_caution'] = caution
        return {d: row for d in conformance.DESKTOPS}

    def run_check(self, device, dry):
        context = {'stage1_caution': {'apple,j316s': 'refused', 'apple,j575d': 'untried'}}
        return conformance.stage1_caution({'device_identifier': device, 'disk': {}}, dry, context)

    def test_a_listed_board_is_warned_and_goes_ahead(self):
        result = self.run_check('apple,j316s', self.dry(self.CAUTION))
        self.assertTrue(result['ok'], result)
        self.assertIn('Always Use', result['detail'])

    def test_a_listed_board_without_the_warning_or_blocked_fails(self):
        self.assertFalse(self.run_check('apple,j575d', self.dry(None))['ok'])
        self.assertIn('blocked', self.run_check('apple,j316s', self.dry(self.CAUTION, stage1=False))['detail'])
        self.assertIn('blocked', self.run_check('apple,j316s', self.dry(self.CAUTION, supported=False))['detail'])

    def test_any_other_board_is_never_warned(self):
        self.assertIsNone(self.run_check('apple,j413', self.dry(None)))
        self.assertFalse(self.run_check('apple,j413', self.dry(self.CAUTION))['ok'])


class PayloadPartTests(unittest.TestCase):
    def test_an_unsplit_payload_is_one_part_checked_against_the_payload_digest(self):
        model = {'payloadDigest': 'sha256:' + 'a' * 64, 'payloadArtifact': {
            'sourceURL': 'https://example.invalid/p.zip', 'fileName': 'p.zip', 'sizeBytes': 3}}
        self.assertEqual(conformance.payload_parts(model), [{'sourceURL': 'https://example.invalid/p.zip',
                                                             'fileName': 'p.zip', 'sizeBytes': 3,
                                                             'sha256': 'sha256:' + 'a' * 64}])

    def test_a_split_payload_keeps_its_parts(self):
        parts = [{'sourceURL': 'u', 'fileName': 'p.zip.part00', 'sizeBytes': 1, 'sha256': 'sha256:' + 'b' * 64}]
        model = {'payloadDigest': 'sha256:' + 'a' * 64, 'payloadArtifact': {
            'sourceURL': 'x', 'fileName': 'p.zip', 'sizeBytes': 1, 'parts': parts}}
        self.assertEqual(conformance.payload_parts(model), parts)


class UrlopenRetryTests(unittest.TestCase):
    def test_a_transient_503_is_retried_and_a_404_is_not(self):
        import urllib.error
        from unittest import mock
        calls = []

        def fake(request, timeout):
            calls.append(request)
            if len(calls) == 1:
                raise urllib.error.HTTPError('u', 503, 'Service Unavailable', {}, None)
            return 'ok'
        with mock.patch('urllib.request.urlopen', fake), mock.patch('time.sleep'):
            self.assertEqual(conformance.urlopen('u', timeout=1), 'ok')
        self.assertEqual(len(calls), 2)

        def missing(request, timeout):
            calls.append(request)
            raise urllib.error.HTTPError('u', 404, 'Not Found', {}, None)
        calls.clear()
        with mock.patch('urllib.request.urlopen', missing), mock.patch('time.sleep'):
            with self.assertRaises(urllib.error.HTTPError):
                conformance.urlopen('u', timeout=1)
        self.assertEqual(len(calls), 1)


class PinLabelTests(unittest.TestCase):
    TAG = '0ca7bf85c9946a7ec90a5701c126b70ed144bd34'
    MAIN = '32dccf0297e90e66deac7cf252478b2af9e71d27'

    def label(self, commit):
        tags = json.dumps([{'name': 'v1.0.0b1', 'commit': {'sha': self.TAG}}]).encode()
        with mock.patch.object(conformance, 'fetch', lambda url, cache, headers=None: tags):
            return conformance.aura_label('1.0.0b1', commit, '/nonexistent')

    def test_only_the_tagged_commit_carries_the_bare_release_label(self):
        self.assertEqual(self.label(self.TAG), '1.0.0b1')
        self.assertEqual(self.label(self.MAIN), '1.0.0b1-g32dccf02')

    def labels(self, commit):
        tags = json.dumps([{'name': 'v1.0.0b1', 'commit': {'sha': self.TAG}}]).encode()
        with mock.patch.object(conformance, 'fetch', lambda url, cache, headers=None: tags):
            return conformance.aura_labels('1.0.0b1', commit, '/nonexistent')

    def test_a_packaged_build_of_the_tag_matches_the_pin(self):
        labels = self.labels(self.TAG)
        self.assertEqual(labels, ['1.0.0b1', '1.0.0b1-g0ca7bf85'])
        self.assertTrue(conformance.is_pinned_aura('##aura_ver##1.0.0b1-g0ca7bf85', labels))
        self.assertTrue(conformance.is_pinned_aura('##aura_ver##1.0.0b1', labels))
        self.assertFalse(conformance.is_pinned_aura('##aura_ver##1.0.0b10', labels))

    def test_an_untagged_pin_matches_only_its_own_commit(self):
        labels = self.labels(self.MAIN)
        self.assertEqual(labels, ['1.0.0b1-g32dccf02'])
        self.assertFalse(conformance.is_pinned_aura('##aura_ver##1.0.0b1', labels))

    def test_stage1_proofs_name_the_build_that_booted(self):
        constraints = json.loads((HERE / 'fixtures/constraints.json').read_text())
        for board, proof in constraints['proven_stage1'].items():
            self.assertTrue(proof['aura'] and proof['evidence'], board)
        for commit, record in constraints['pinned_stage1_bytes'].items():
            self.assertRegex(commit, r'\A[0-9a-f]{40}\Z')
            self.assertGreater(record['bytes'], 0)
        limit = constraints['stage1_iboot']['j316sap']
        self.assertLess(max(limit['booted_bytes']), min(limit['rejected_bytes']))


if __name__ == '__main__':
    unittest.main()
