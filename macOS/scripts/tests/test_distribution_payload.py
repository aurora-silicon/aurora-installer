"""Small filesystem fixtures test packaging integrity without mounting disks."""
import hashlib
import importlib.util
import json
import re
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'assemble-distribution-payload.py'
spec = importlib.util.spec_from_file_location('distribution_payload', SCRIPT)
payload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(payload)
import supported_models  # noqa: E402  (on the path the payload module adds)


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
        for name in ('m1n1/boot.bin', 'EFI/BOOT/BOOTAA64.EFI', 'aurora/stage1.bin'):
            path = self.bundle / 'esp' / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(name.encode())
        self.write_neo_stage_two()
        self.app = self.root / 'Aurora Installer.app'
        binary = self.app / 'Contents/MacOS/OmarchyRecovery'; binary.parent.mkdir(parents=True); binary.write_bytes(b'recovery-fixture')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'OmarchyRecovery',
            'OmarchyRecoveryBuildMode':'recovery','OmarchyRecoveryDataLayout':'external-install-data-v1'}))

    def write_neo_stage_two(self, sha256=None, boards=('j700', 'j616s', 'j614s')):
        records = {}
        for board in boards:
            dedicated = self.bundle / ('esp/m1n1/boot-%s.bin' % board)
            dedicated.write_bytes(b'dedicated-stage-two-fixture-' + board.encode())
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

    def test_mach_o_stage_one_must_carry_the_raw_stage_one(self):
        raw = (self.bundle / 'esp/aurora/stage1.bin').read_bytes()
        header = bytearray(0x10000)
        header[:4] = b'\xcf\xfa\xed\xfe'
        header[12:16] = (12).to_bytes(4, 'little')
        macho = self.bundle / 'esp/aurora/stage1.macho'
        macho.write_bytes(bytes(header) + raw + bytes(0x4000 - len(raw)))
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
        self.assertEqual(set(caution), {'apple,j575d', 'apple,j614s'} | oled)
        for identifier in list(caution) + ['apple,j314s', 'apple,j316s', 'apple,j314c', 'apple,j316c',
                                           'apple,j375c', 'apple,j375d']:
            self.assertIn(identifier.removeprefix('apple,') + 'ap', qualified)
        self.assertIn('j413ap', qualified)
        self.assertIn('j700ap', qualified)
        self.assertIn('j614sap', qualified)
        self.assertIn('j616sap', qualified)
        # The OLED MacBook Pros shipped with macOS 27.2 and have no older firmware.
        for identifier in oled:
            self.assertEqual(qualified[identifier.removeprefix('apple,') + 'ap'], ['27.2'])
        self.assertNotIn('27.2', qualified['j616sap'])

    def test_public_payload_without_required_m4_stage_two_is_refused(self):
        self.write_neo_stage_two(boards=('j700', 'j616s'))
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
