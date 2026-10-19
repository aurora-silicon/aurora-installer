"""Small filesystem fixtures test packaging integrity without mounting disks."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'assemble-distribution-payload.py'
spec = importlib.util.spec_from_file_location('distribution_payload', SCRIPT)
payload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(payload)


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
        self.app = self.root / 'Aurora Installer.app'
        binary = self.app / 'Contents/MacOS/OmarchyRecovery'; binary.parent.mkdir(parents=True); binary.write_bytes(b'recovery-fixture')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'OmarchyRecovery',
            'OmarchyRecoveryBuildMode':'recovery','OmarchyRecoveryDataLayout':'external-install-data-v1'}))

    def test_generic_payload_binds_profile_volume_id_and_native_recovery(self):
        output = self.root / 'output'
        payload.assemble(self.bundle, self.app, output, release_id="fixture")
        metadata = json.loads((output / 'installer-data-fedora-kde.json').read_text())['os_list'][0]
        self.assertEqual(metadata['installation_profile'], 'fedora-kde')
        self.assertEqual(metadata['partitions'][0]['volume_id'], '0xA1B2C3D4')
        self.assertIn('j700ap', metadata['excluded_device_classes'])
        with zipfile.ZipFile(output / metadata['package']) as archive:
            payload.omarchy_recovery.validate_payload(archive)

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
                self.assertEqual(hashlib.sha256(icon).hexdigest(), provenance[distribution]['sha256'])
                self.assertEqual(icon, payload.DISTRIBUTION_ICONS[distribution].read_bytes())
                if distribution in observed:
                    self.assertEqual(icon, observed[distribution])
                observed[distribution] = icon
        self.assertEqual(len(set(observed.values())), 3)

    def test_resume_rejects_an_icon_from_another_distribution(self):
        from unittest.mock import patch
        output = self.root / 'output'
        payload.assemble(self.bundle, self.app, output, release_id="fixture")
        with patch.dict(payload.DISTRIBUTION_ICONS, fedora=payload.DISTRIBUTION_ICONS['nixos']):
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
