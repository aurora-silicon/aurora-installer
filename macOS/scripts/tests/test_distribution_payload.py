"""Small filesystem fixtures test packaging integrity without mounting disks."""
import hashlib
import gzip
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

# Root compatibles: every board that needs its own Stage 2, an M1, and boards a
# published payload may also carry: A7 boards, whose tree names no apple,tNNNN,
# and M4 or later boards the release doesn't support, such as the M5 Pro J714s.
CHIPS = {'j604': 't8132', 'j623': 't8132', 'j624': 't8132', 'j713': 't8132', 'j715': 't8132',
         'j773g': 't8132', 'j614s': 't6040', 'j616s': 't6040', 'j773s': 't6040', 'j614c': 't6041',
         'j616c': 't6041', 'j575c': 't6041', 'j813': 't8142', 'j873g': 't8152', 'j700': 't8140',
         'j704': 't8142', 'j815': 't8142', 'j804': 't8152', 'j833ct': 't8152',
         'j274': 't8103', 'j714s': 't6050',
         'k114c': 't6050', 'k114s': 't6050', 'k116c': 't6050', 'k116s': 't6050'}
COMPATIBLES = {board: ['apple,' + board, 'apple,' + chip, 'apple,arm-platform']
               for board, chip in CHIPS.items()}
COMPATIBLES['j71'] = ['apple,j71', 'apple,s5l8960x', 'apple,arm-platform']
# Every supported M4 or later board, which a payload must carry a board Stage 2 for.
M4_OR_LATER = ('j700',) + payload.BOARD_STAGE2_REQUIRED


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

    def write_neo_stage_two(self, sha256=None, boards=M4_OR_LATER + ('j71', 'j714s')):
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

    def common_with_missing_oled(self, omit_tree=None, wrong_chip=None):
        aura = b'authenticated-aura-fixture'
        trailer = gzip.compress(b'authenticated-u-boot-fixture', mtime=0)
        boards = M4_OR_LATER + ('j71', 'j714s')
        trees = {}
        for board in boards:
            if board == omit_tree:
                continue
            compatible = COMPATIBLES[board]
            if board == wrong_chip:
                compatible = ['apple,' + board, 'apple,t8103', 'apple,arm-platform']
            trees[board] = device_tree(compatible)
        combined = aura + b''.join(trees.values()) + trailer
        (self.bundle / 'esp/m1n1/boot.bin').write_bytes(combined)
        (self.bundle / 'esp/m1n1/boot-ctxr.bin').write_bytes(combined)
        records = {}
        for board in boards:
            path = self.bundle / f'esp/m1n1/boot-{board}.bin'
            if board in payload.OLED_STAGE2_REQUIRED:
                path.unlink(missing_ok=True)
                continue
            data = aura + trees[board] + trailer
            path.write_bytes(data)
            records[board + 'ap'] = {'member': f'esp/m1n1/boot-{board}.bin',
                                     'bytes': len(data), 'sha256': payload.digest(path),
                                     'deviceTrees': 1}
        manifest = {'schema': 1, 'sourceSha256': hashlib.sha256(combined).hexdigest(),
                    'auraSha256': hashlib.sha256(aura).hexdigest(),
                    'nextStageSha256': hashlib.sha256(trailer).hexdigest(),
                    'deviceTreeCount': len(trees), 'boards': records}
        (self.bundle / 'stage2.json').write_text(json.dumps(manifest))
        return manifest

    def test_completes_oled_from_common_without_changing_existing_members(self):
        self.common_with_missing_oled()
        before = {str(p.relative_to(self.bundle)): p.read_bytes()
                  for p in self.bundle.rglob('*') if p.is_file() and p.name != 'stage2.json'}
        metadata, _ = self.assembled('oled')
        for name, data in before.items():
            self.assertEqual((self.bundle / name).read_bytes(), data, name)
        for board in payload.OLED_STAGE2_REQUIRED:
            member = f'esp/m1n1/boot-{board}.bin'
            self.assertEqual(metadata['aurora_stage2']['board_members'][board + 'ap'], member)
            data = (self.bundle / member).read_bytes()
            self.assertEqual(payload.board_chip(self.bundle / member, board), 0x6050)
            self.assertEqual((self.bundle / f'esp/m1n1/boot-ctxr-{board}.bin').read_bytes(), data)
            self.assertIn(f'esp/m1n1/boot-ctxr-{board}.bin',
                          metadata['aurora_macho_boot']['confined_members'])
            self.assertEqual(metadata['aurora_stage1']['qualified_machines'][board + 'ap'], ['27.2'])
        manifest = (self.bundle / 'stage2.json').read_bytes()
        self.assembled('oled-again')
        self.assertEqual((self.bundle / 'stage2.json').read_bytes(), manifest)

    def test_missing_oled_tree_fails_without_writing_partial_members(self):
        self.common_with_missing_oled(omit_tree='k116s')
        with self.assertRaisesRegex(ValueError, 'no device tree for k116s'):
            self.assembled('missing-oled')
        self.assertFalse(list((self.bundle / 'esp/m1n1').glob('boot-k*.bin')))

    def test_oled_cannot_use_a_different_existing_board_build(self):
        manifest = self.common_with_missing_oled()
        path = self.bundle / 'esp/m1n1/boot-j614s.bin'
        path.write_bytes(path.read_bytes() + b'different-build')
        manifest['boards']['j614sap'].update(bytes=path.stat().st_size, sha256=payload.digest(path))
        (self.bundle / 'stage2.json').write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'authenticated OLED Stage 2 components'):
            self.assembled('wrong-oled-source')
        self.assertFalse(list((self.bundle / 'esp/m1n1').glob('boot-k*.bin')))

    def test_oled_rejects_a_non_mach_o_chip(self):
        self.common_with_missing_oled(wrong_chip='k114c')
        with self.assertRaisesRegex(ValueError, 'Mach-O Mac chip'):
            self.assembled('wrong-oled-chip')

    def test_oled_rejects_a_stage_two_that_exceeds_its_slot(self):
        self.common_with_missing_oled()
        with patch.object(payload, 'MAX_CONFINED_STAGE2_BYTES', 64):
            with self.assertRaisesRegex(ValueError, '16 MiB slot'):
                self.assembled('large-oled')

    def test_reuse_cannot_label_an_old_archive_as_oled_complete(self):
        self.common_with_missing_oled()
        metadata, output = self.assembled('old-archive')
        path = output / metadata['package']
        replacement = path.with_suffix('.replacement.zip')
        with zipfile.ZipFile(path) as original, zipfile.ZipFile(replacement, 'w') as changed:
            for info in original.infolist():
                if '/boot-k' not in info.filename and '/boot-ctxr-k' not in info.filename:
                    changed.writestr(info, original.read(info.filename))
        replacement.replace(path)
        with self.assertRaisesRegex(ValueError, 'existing payload member inventory differs'):
            payload.assemble(self.bundle, self.app, output, reuse_payload=True, release_id='fixture')

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
        # The native installer would refuse every other M4 or later Mac on this
        # payload. The unsupported J714s and the A7 J71 need nothing.
        others = sorted(payload.BOARD_STAGE2_REQUIRED)
        with self.assertRaisesRegex(ValueError, r'boards ' + ', '.join(others) + '$'):
            self.assembled('neo-only')
        for board in others:
            (self.bundle / ('esp/m1n1/boot-ctxr-%s.bin' % board)).write_bytes(b'board file')
        metadata, output = self.assembled('every-board')
        self.assertEqual(metadata['aurora_macho_boot']['confined_members'],
                         ['esp/m1n1/boot-ctxr-%s.bin' % board for board in sorted(M4_OR_LATER)])
        with zipfile.ZipFile(output / metadata['package']) as archive:
            self.assertEqual(archive.read('esp/m1n1/boot-ctxr-j700.bin'), b'board file')
        # A board the release doesn't support may carry its own file too.
        (self.bundle / 'esp/m1n1/boot-ctxr-j714s.bin').write_bytes(b'board file')
        self.assembled('unsupported-board-file')
        # The shared file covers a board without its own.
        (self.bundle / 'esp/m1n1/boot-ctxr-j614s.bin').unlink()
        shared.write_bytes(b'shared')
        self.assembled('board-and-shared')

    def test_a_board_file_must_be_for_an_m4_or_later_board_here(self):
        self.write_neo_stage_two(boards=M4_OR_LATER + ('j274',))
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
        oled = {'apple,k114c', 'apple,k114s', 'apple,k116c', 'apple,k116s'}
        self.assertEqual(set(caution), oled | {'apple,j575d', 'apple,j614s', 'apple,j604', 'apple,j623',
                                        'apple,j624', 'apple,j715', 'apple,j773g', 'apple,j614c',
                                        'apple,j616c', 'apple,j773s', 'apple,j575c', 'apple,j813', 'apple,j873g',
                                        'apple,j704', 'apple,j815', 'apple,j804', 'apple,j833ct'})
        for identifier in list(caution) + ['apple,j314s', 'apple,j316s', 'apple,j314c', 'apple,j316c',
                                           'apple,j375c', 'apple,j375d']:
            self.assertIn(identifier.removeprefix('apple,') + 'ap', qualified)
        self.assertIn('j413ap', qualified)
        self.assertIn('j700ap', qualified)
        self.assertIn('j614sap', qualified)
        self.assertIn('j616sap', qualified)
        # The M6 Mac mini's stub is macOS 27.0, the firmware aura was brought up on.
        self.assertIn('27.0', qualified['j873gap'])
        self.assertIn('26.6.2', qualified['j813ap'])
        # The M6 MacBook Pro and iMac shipped with macOS 27.2 (26B7124), their only firmware.
        self.assertIn('27.2', qualified['j804ap'])
        self.assertIn('27.2', qualified['j833ctap'])
        self.assertIn('26.6.2', qualified['j704ap'])
        self.assertIn('26.6.2', qualified['j815ap'])
        # The OLED MacBook Pros shipped with macOS 27.2 and have no older firmware.
        for identifier in oled:
            self.assertEqual(qualified[identifier.removeprefix('apple,') + 'ap'], ['27.2'])

    def test_public_payload_without_required_m4_stage_two_is_refused(self):
        self.write_neo_stage_two(boards=('j700',) + tuple(b for b in payload.BOARD_STAGE2_REQUIRED if b != 'j614s'))
        output = self.root / 'output'
        with self.assertRaisesRegex(ValueError, 'J614s requires a current board-specific'):
            payload.assemble(self.bundle, self.app, output, release_id='fixture')
        self.assertFalse(output.exists())

    def test_the_installer_warns_about_exactly_the_caution_boards(self):
        source = (SCRIPT.parents[1] / 'Sources/AuroraInstallerUXCore/Stage1Caution.swift').read_text()
        table = source[source.index('static let reasons'):]
        swift = set(re.findall(r'"(apple,[jk][0-9]+[a-z]*)":', table))
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
