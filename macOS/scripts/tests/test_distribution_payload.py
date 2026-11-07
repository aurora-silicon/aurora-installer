"""Small filesystem fixtures test packaging integrity without mounting disks."""
import hashlib
import importlib.util
import json
import re
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'assemble-distribution-payload.py'
spec = importlib.util.spec_from_file_location('distribution_payload', SCRIPT)
payload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(payload)
import supported_models  # noqa: E402  (on the path the payload module adds)

# Root compatibles. A published payload also carries A7 boards, whose tree names no
# apple,tNNNN, and M4 or later boards the release doesn't support, such as the J713.
COMPATIBLES = {board: ['apple,' + board, 'apple,' + chip, 'apple,arm-platform'] for board, chip in (
    ('j700', 't8140'), ('j616s', 't6040'), ('j614s', 't6040'), ('j274', 't8103'), ('j713', 't8132'))}
COMPATIBLES['j71'] = ['apple,j71', 'apple,s5l8960x', 'apple,arm-platform']


def device_tree(compatibles):
    """A minimal flattened device tree whose root has these compatibles."""
    strings = b'compatible\0'
    value = b''.join(item.encode() + b'\0' for item in compatibles)
    value += b'\0' * (-len(value) % 4)
    structure = (struct.pack('>I', 1) + b'\0' * 4 + struct.pack('>III', 3, len(value) - value.count(b'\0') + len(compatibles), 0)
                 + value + struct.pack('>II', 2, 9))
    header = 40
    total = header + len(structure) + len(strings)
    return struct.pack('>10I', 0xD00DFEED, total, header, header + len(structure), 0, 17, 16, 0,
                       len(strings), len(structure)) + structure + strings


class DistributionPayloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle = self.root / 'bundle'; self.bundle.mkdir()
        images = {}
        for name in ('boot.img', 'root.img'):
            data = (name.encode() + b'\0') * 128
            (self.bundle / name).write_bytes(data)
            images[name] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
        self.image = {'installation_profile': 'fedora-kde', 'layout_kind': 'fedora-btrfs-v1',
                      'root_subvolume': 'root', 'efi_bytes': 524288000, 'efi_volume_id': 'A1B2C3D4', 'images': images}
        (self.bundle / 'image.json').write_text(json.dumps(self.image))
        for name in ('m1n1/boot.bin', 'm1n1/boot-ctxr.bin', 'EFI/BOOT/BOOTAA64.EFI', 'aurora/stage1.bin'):
            path = self.bundle / 'esp' / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(name.encode())
        self.write_stage_one_macho()
        self.write_neo_stage_two()
        self.app = self.root / 'Aurora Installer.app'
        binary = self.app / 'Contents/MacOS/OmarchyRecovery'; binary.parent.mkdir(parents=True); binary.write_bytes(b'recovery-fixture')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'OmarchyRecovery',
            'OmarchyRecoveryBuildMode':'recovery','OmarchyRecoveryDataLayout':'external-install-data-v1'}))

    def write_stage_one_macho(self):
        raw = (self.bundle / 'esp/aurora/stage1.bin').read_bytes()
        header = bytearray(0x10000)
        header[:4] = b'\xcf\xfa\xed\xfe'
        header[12:16] = (12).to_bytes(4, 'little')
        (self.bundle / 'esp/aurora/stage1.macho').write_bytes(bytes(header) + raw + bytes(0x4000 - len(raw)))

    def write_neo_stage_two(self, sha256=None, boards=('j700', 'j616s', 'j614s', 'j71', 'j713')):
        records = {}
        for board in boards:
            dedicated = self.bundle / ('esp/m1n1/boot-%s.bin' % board)
            dedicated.write_bytes(b'dedicated-stage-two-fixture-' + board.encode()
                                  + device_tree(COMPATIBLES[board]))
            records[board + 'ap'] = {'member': 'esp/m1n1/boot-%s.bin' % board,
                                     'bytes': dedicated.stat().st_size,
                                     'sha256': (sha256 if board == 'j700' else None) or payload.digest(dedicated)}
        manifest = {'schema': 1, 'sourceSha256': payload.digest(self.bundle / 'esp/m1n1/boot.bin'),
                    'boards': records}
        (self.bundle / 'stage2.json').write_text(json.dumps(manifest))

    def remove_neo_stage_two(self):
        (self.bundle / 'stage2.json').unlink()
        (self.bundle / 'esp/m1n1/boot-j700.bin').unlink()

    def test_generic_payload_binds_profile_volume_id_and_native_recovery(self):
        output = self.root / 'output'
        payload.assemble(self.bundle, self.app, output, release_id="fixture")
        metadata = json.loads((output / 'installer-data-fedora-kde.json').read_text())['os_list'][0]
        self.assertEqual(metadata['installation_profile'], 'fedora-kde')
        self.assertEqual(metadata['partitions'][0]['volume_id'], '0xA1B2C3D4')
        with zipfile.ZipFile(output / metadata['package']) as archive:
            payload.aurora_recovery.validate_payload(archive)

    def assembled(self, name):
        output = self.root / name
        payload.assemble(self.bundle, self.app, output, release_id='fixture')
        return json.loads((output / 'installer-data-fedora-kde.json').read_text())['os_list'][0], output

    def test_a_payload_without_the_mach_o_files_still_serves_every_other_mac(self):
        # One payload serves every Mac; the native installer refuses M4 and later on it.
        (self.bundle / 'esp/m1n1/boot-ctxr.bin').unlink()
        metadata, _ = self.assembled('no-ctxr')
        self.assertEqual(metadata['aurora_macho_boot'], {
            'kind': 'padded-ctxr-v1', 'stage1_member': 'esp/aurora/stage1.macho', 'confined_members': []})
        (self.bundle / 'esp/aurora/stage1.macho').unlink()
        metadata, _ = self.assembled('no-macho')
        self.assertEqual(metadata['aurora_macho_boot']['stage1_member'], None)

    def test_mach_o_files_that_are_present_are_checked(self):
        shared = self.bundle / 'esp/m1n1/boot-ctxr.bin'
        metadata, _ = self.assembled('shared')
        self.assertEqual(metadata['aurora_macho_boot']['confined_members'], ['esp/m1n1/boot-ctxr.bin'])
        (self.bundle / 'esp/aurora/stage1.macho').unlink()
        with self.assertRaisesRegex(ValueError, 'stage1.macho'):
            self.assembled('no-object')
        self.write_stage_one_macho()
        shared.write_bytes(b'')
        with self.assertRaisesRegex(ValueError, 'empty'):
            self.assembled('empty-stage-two')
        with shared.open('wb') as stream:
            stream.truncate((16 << 20) + 1)
        with self.assertRaisesRegex(ValueError, '16 MiB'):
            self.assembled('large-stage-two')
        shared.unlink()
        (self.bundle / 'esp/m1n1/boot-ctxr-j700.bin').symlink_to(self.bundle / 'esp/m1n1/boot-j700.bin')
        with self.assertRaisesRegex(ValueError, 'regular'):
            self.assembled('linked-stage-two')

    def test_board_files_must_cover_every_m4_or_later_board_as_the_installer_looks(self):
        shared = self.bundle / 'esp/m1n1/boot-ctxr.bin'
        shared.unlink()
        (self.bundle / 'esp/m1n1/boot-ctxr-j700.bin').write_bytes(b'board file')
        # The native installer would refuse a J614s or J616s on this payload. The
        # unsupported J713 and the A7 J71 need nothing.
        with self.assertRaisesRegex(ValueError, r'boards j614s, j616s$'):
            self.assembled('neo-only')
        for board in ('j616s', 'j614s'):
            (self.bundle / ('esp/m1n1/boot-ctxr-%s.bin' % board)).write_bytes(b'board file')
        metadata, output = self.assembled('every-board')
        self.assertEqual(metadata['aurora_macho_boot']['confined_members'], [
            'esp/m1n1/boot-ctxr-j614s.bin', 'esp/m1n1/boot-ctxr-j616s.bin', 'esp/m1n1/boot-ctxr-j700.bin'])
        with zipfile.ZipFile(output / metadata['package']) as archive:
            self.assertEqual(archive.read('esp/m1n1/boot-ctxr-j700.bin'), b'board file')
        # A board the release doesn't support may carry its own file too.
        (self.bundle / 'esp/m1n1/boot-ctxr-j713.bin').write_bytes(b'board file')
        self.assembled('unsupported-board-file')
        # The shared file covers a board without its own.
        (self.bundle / 'esp/m1n1/boot-ctxr-j614s.bin').unlink()
        shared.write_bytes(b'shared')
        self.assembled('board-and-shared')

    def test_a_board_file_must_be_for_an_m4_or_later_board_here(self):
        self.write_neo_stage_two(boards=('j700', 'j616s', 'j614s', 'j274'))
        (self.bundle / 'esp/m1n1/boot-ctxr-j274.bin').write_bytes(b'board file')
        with self.assertRaisesRegex(ValueError, 'boot-ctxr-j274.bin'):
            self.assembled('m1-board')
        (self.bundle / 'esp/m1n1/boot-ctxr-j274.bin').unlink()
        (self.bundle / 'esp/m1n1/boot-ctxr-j71.bin').write_bytes(b'board file')
        with self.assertRaisesRegex(ValueError, 'boot-ctxr-j71.bin'):
            self.assembled('a7-board')
        (self.bundle / 'esp/m1n1/boot-ctxr-j71.bin').unlink()
        (self.bundle / 'esp/m1n1/boot-ctxr-j999.bin').write_bytes(b'board file')
        with self.assertRaisesRegex(ValueError, 'boot-ctxr-j999.bin'):
            self.assembled('unknown-board')
        (self.bundle / 'esp/m1n1/boot-ctxr-j999.bin').unlink()
        (self.bundle / 'esp/m1n1/boot-ctxr-other.bin').write_bytes(b'board file')
        with self.assertRaisesRegex(ValueError, 'unexpected'):
            self.assembled('odd-name')

    def test_an_a7_board_names_no_mac_chip(self):
        path = self.bundle / 'esp/m1n1/boot-j71.bin'
        self.assertIsNone(payload.board_chip(path, 'j71'))
        self.assertFalse(payload.uses_macho(None))
        self.assertEqual(payload.board_chip(self.bundle / 'esp/m1n1/boot-j713.bin', 'j713'), 0x8132)

    def test_the_chip_rule_matches_the_installer(self):
        for chip in (0x8132, 0x6040, 0x6041, 0x8140, 0x8142, 0x6050, 0x8150):
            self.assertTrue(payload.uses_macho(chip), hex(chip))
        for chip in (0x8103, 0x6000, 0x8112, 0x6020, 0x8122, 0x6030, 0x6032, 0x6034):
            self.assertFalse(payload.uses_macho(chip), hex(chip))

    def test_mach_o_stage_one_must_carry_the_raw_stage_one(self):
        raw = (self.bundle / 'esp/aurora/stage1.bin').read_bytes()
        header = bytearray(0x10000)
        header[:4] = b'\xcf\xfa\xed\xfe'
        header[12:16] = (12).to_bytes(4, 'little')
        macho = self.bundle / 'esp/aurora/stage1.macho'
        output = self.root / 'output'
        payload.assemble(self.bundle, self.app, output, release_id='fixture')
        metadata = json.loads((output / 'installer-data-fedora-kde.json').read_text())['os_list'][0]
        with zipfile.ZipFile(output / metadata['package']) as archive:
            self.assertEqual(archive.read('esp/aurora/stage1.macho'), macho.read_bytes())
        for bad in (bytes(header) + b'another stage 1', bytes(header[:0x100]) + b'__TEXT_BOOT_EXEC'
                    + bytes(header[0x110:]) + raw, b'\0' * 0x10000 + raw):
            macho.write_bytes(bad)
            with self.assertRaises(ValueError):
                payload.assemble(self.bundle, self.app, self.root / ('bad-' + str(len(bad))), release_id='fixture')

    def test_public_payload_admits_the_neo_with_its_own_stage_two(self):
        output = self.root / 'output'
        payload.assemble(self.bundle, self.app, output, release_id='fixture')
        metadata = json.loads((output / 'installer-data-fedora-kde.json').read_text())['os_list'][0]
        supported, _ = supported_models.load()
        boards = {identifier.removeprefix('apple,') + 'ap' for identifier in supported}
        self.assertIn('j700ap', boards)
        self.assertEqual(set(metadata['aurora_stage1']['qualified_machines']), boards)
        self.assertEqual(metadata['aurora_stage2']['board_members']['j700ap'],
                         'esp/m1n1/boot-j700.bin')
        for key in ('excluded_device_classes', 'allowed_device_classes', 'supported_fw',
                    'required_neo_peripherals', 'neo_regulatory_policy'):
            self.assertNotIn(key, metadata)
        with zipfile.ZipFile(output / metadata['package']) as archive:
            names = archive.namelist()
        self.assertIn('esp/m1n1/boot-j700.bin', names)
        self.assertFalse(any(name.startswith('installer-inputs/') for name in names))
        receipt = json.loads((output / 'delivery.json').read_text())
        self.assertFalse(receipt['private_neo_inputs'])
        self.assertFalse(receipt['native_neo_reset_qa'])

    def test_every_supported_board_is_qualified_and_only_untried_boards_are_cautioned(self):
        # Ryan 2026-10-30: M1 to M3 and the A18 Pro are supported. A board
        # whose Stage 1 is untried is warned about, not blocked. The M1 Pro,
        # Max and Ultra left the list once aura's Stage 1 shrank to 1.6 MB.
        output = self.root / 'output'
        payload.assemble(self.bundle, self.app, output, release_id='fixture')
        qualified = json.loads((output / 'installer-data-fedora-kde.json').read_text())['os_list'][0][
            'aurora_stage1']['qualified_machines']
        caution = supported_models.stage1_caution()
        self.assertEqual(set(caution), {'apple,j575d', 'apple,j614s', 'apple,j616c'})
        for identifier in list(caution) + ['apple,j314s', 'apple,j316s', 'apple,j314c', 'apple,j316c',
                                           'apple,j375c', 'apple,j375d']:
            self.assertIn(identifier.removeprefix('apple,') + 'ap', qualified)
        self.assertIn('j413ap', qualified)
        self.assertIn('j700ap', qualified)
        self.assertIn('j614sap', qualified)
        self.assertIn('j616sap', qualified)

    def test_public_payload_without_required_m4_stage_two_is_refused(self):
        self.write_neo_stage_two(boards=('j700', 'j616s'))
        output = self.root / 'output'
        with self.assertRaisesRegex(ValueError, 'J614s requires a current board-specific'):
            payload.assemble(self.bundle, self.app, output, release_id='fixture')
        self.assertFalse(output.exists())

    def test_the_installer_warns_about_exactly_the_caution_boards(self):
        source = (SCRIPT.parents[1] / 'Sources/AuroraInstallerUXCore/Stage1Caution.swift').read_text()
        table = source[source.index('static let reasons'):]
        swift = set(re.findall(r'"(apple,j[0-9]+[a-z]*)":', table))
        self.assertEqual(swift, set(supported_models.stage1_caution()))

    def test_public_payload_without_the_neo_stage_two_is_refused(self):
        self.remove_neo_stage_two()
        output = self.root / 'output'
        with self.assertRaisesRegex(ValueError, 'MacBook Neo requires a current board-specific'):
            payload.assemble(self.bundle, self.app, output, release_id='fixture')
        self.assertFalse(output.exists())
        self.write_neo_stage_two(sha256='0' * 64)
        with self.assertRaisesRegex(ValueError, 'member identity mismatch'):
            payload.assemble(self.bundle, self.app, output, release_id='fixture')
        self.assertFalse(output.exists())

    def test_one_payload_serves_every_mac(self):
        # No option builds a board-only payload or narrows the boards a payload admits.
        source = SCRIPT.read_text()
        for fragment in ('--private-neo-policy-directory', '--native-neo-reset', 'neo-local',
                         'allowed_device_classes', 'excluded_device_classes'):
            self.assertNotIn(fragment, source)

    def test_all_nine_profiles_use_the_selected_distribution_symbol(self):
        observed = {}
        provenance = json.loads((payload.ROOT / 'Packaging/DistributionIcons/provenance.json').read_text())['icons']
        for distribution, layout in [('fedora', 'fedora'), ('arch', 'alarm'), ('nixos', 'nixos')]:
            for desktop in ('kde', 'gnome', 'minimal'):
                profile = distribution + '-' + desktop
                self.image.update(installation_profile=profile, layout_kind=layout + '-btrfs-v1')
                (self.bundle / 'image.json').write_text(json.dumps(self.image))
                output = self.root / profile
                payload.assemble(self.bundle, self.app, output, release_id="fixture")
                metadata = json.loads((output / ('installer-data-' + profile + '.json')).read_text())['os_list'][0]
                with zipfile.ZipFile(output / metadata['package']) as archive:
                    icon = archive.read(metadata['icon'])
                self.assertEqual(icon[:4], b'icns')
                self.assertEqual(int.from_bytes(icon[4:8], 'big'), len(icon))
                self.assertIn(distribution, provenance['aurora']['used_by'])
                self.assertEqual(hashlib.sha256(icon).hexdigest(), provenance['aurora']['sha256'])
                self.assertEqual(icon, payload.DISTRIBUTION_ICONS[distribution].read_bytes())
                if distribution in observed:
                    self.assertEqual(icon, observed[distribution])
                observed[distribution] = icon
        # Every system's startup volume shows the Aurora mark.
        self.assertEqual(set(provenance), {'aurora'})
        self.assertEqual(len(set(observed.values())), 1)

    def test_resume_rejects_an_icon_from_another_distribution(self):
        from unittest.mock import patch
        output = self.root / 'output'
        payload.assemble(self.bundle, self.app, output, release_id="fixture")
        other = self.root / 'other.icns'
        other.write_bytes(b'icns' + (16).to_bytes(4, 'big') + b'not-aurora')
        with patch.dict(payload.DISTRIBUTION_ICONS, fedora=other):
            with self.assertRaisesRegex(ValueError, 'content differs: aurora-volume.icns'):
                payload.assemble(self.bundle, self.app, output, reuse_payload=True, release_id="fixture")

    def test_source_corruption_is_rejected_before_archive_creation(self):
        (self.bundle / 'root.img').write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'image identity mismatch'):
            payload.assemble(self.bundle, self.app, self.root / 'output')
        self.assertFalse((self.root / 'output').exists())

    def test_resume_verifies_every_existing_member_against_inputs(self):
        output = self.root / 'output'; payload.assemble(self.bundle, self.app, output, release_id="fixture")
        path = output / 'fedora-kde-fixture.zip'
        with zipfile.ZipFile(path) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        files['root.img'] = b'x' * len(files['root.img'])
        with zipfile.ZipFile(path, 'w') as archive:
            for name, data in files.items(): archive.writestr(name, data)
        with self.assertRaisesRegex(ValueError, 'content differs: root.img'):
            payload.assemble(self.bundle, self.app, output, reuse_payload=True, release_id="fixture")

if __name__ == '__main__': unittest.main()
