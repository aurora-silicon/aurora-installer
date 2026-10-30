"""Offline checks of the conformance harness: fixture privacy, mode derivation,
Stage 2 parsing and the plan and verdict rules. No network, no Swift build."""
import gzip
import importlib.util
import json
from pathlib import Path
import re
import struct
import unittest

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
            self.assertEqual(sorted(kinds), sorted(['Apple_APFS_ISC', 'Apple_APFS', 'Apple_APFS_Recovery']), name)
            kept = conformance.swift_machine(machine, 'side-by-side', CONSTRAINTS)
            self.assertEqual(len(kept['snapshot']['partitions']), len(machine['disk']['partitions']))
            systems = [s for c in kept['containers'] for s in c['systems']]
            self.assertEqual(len([s for s in systems if not s['stub']]), 1, name)

    def test_identity_only_fixture_gets_a_synthetic_disk(self):
        machine = dict(MACHINES['m1pro'])
        result = conformance.swift_machine(machine, 'fresh', CONSTRAINTS)
        self.assertEqual(result['hardware']['chipID'], 0x6000)
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


class ExpectationTests(unittest.TestCase):
    def cell(self, opt_in, supported):
        return {'machine': 'x', 'mode': 'fresh', 'distro': 'fedora', 'opt_in': opt_in, 'at_pin': 'FAIL',
                'checks': [{'check': 'supported', 'ok': supported}]}

    def test_an_unknown_board_that_stops_being_refused_by_default_is_a_regression(self):
        expected = {'cells': {'x/fresh/fedora': {'verdict': 'FAIL', 'must_fail': ['supported']},
                              'x/fresh/fedora/full-send': {'verdict': 'FAIL', 'must_ok': ['supported']}}}
        self.assertEqual(conformance.compare_expected([self.cell(None, False), self.cell('full-send', True)],
                                                      expected), 0)
        self.assertEqual(conformance.compare_expected([self.cell(None, True)], expected), 1)
        self.assertEqual(conformance.compare_expected([self.cell('full-send', False)], expected), 1)

    def test_experimental_fixtures_declare_their_levels(self):
        for name, machine in MACHINES.items():
            for level in (machine.get('experimental') or {}).get('opt_in', []):
                self.assertIn(level, ('bootloader-only', 'full-send'), name)


if __name__ == '__main__':
    unittest.main()
