#!/usr/bin/env python3
"""Package a finalized distro filesystem bundle and native Recovery template.

A private Neo variant may additionally carry recorded original policy inputs.
It is a separate, explicitly local payload and must not be published publicly.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import re
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(ROOT / 'Engine/overlay/src'))
import omarchy_mt7932
import omarchy_recovery

DISTRIBUTION_ICONS = {
    distribution: ROOT / 'Packaging/DistributionIcons' / (distribution + '.icns')
    for distribution in ('fedora', 'arch', 'nixos')
}


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def regular(path):
    if not path.is_file() or path.is_symlink():
        raise ValueError('expected regular input: ' + str(path))
    return path


def assemble(bundle, recovery, output, policy_directory=None, reuse_payload=False, release_id=None,
             native_neo_reset=False):
    release_id = release_id or datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,79}", release_id):
        raise ValueError("invalid delivery release identifier")
    image = json.loads(regular(bundle / 'image.json').read_text())
    profile = image['installation_profile']
    if not re.fullmatch(r'(fedora|arch|nixos)-(kde|gnome|minimal)', profile):
        raise ValueError('unknown installation profile')
    if native_neo_reset:
        if profile != 'nixos-kde' or policy_directory is not None:
            raise ValueError('Neo Reset qualification requires the public NixOS KDE image')
        dedicated = regular(bundle / 'esp/m1n1/boot-j700.bin')
        if dedicated.stat().st_size != 9_277_502 or digest(dedicated) != '0481c2d5d75c93300be6f7c2187746cd06b769f48c6538b134044aabe930b8d2':
            raise ValueError('Neo Reset requires the physically qualified boot payload')
    distribution_icon = regular(DISTRIBUTION_ICONS[profile.split('-')[0]])
    expected_layout = {'fedora': 'fedora', 'arch': 'alarm', 'nixos': 'nixos'}[profile.split('-')[0]] + '-btrfs-v1'
    if image['layout_kind'] != expected_layout or image['root_subvolume'] != 'root':
        raise ValueError('incompatible filesystem layout')
    for name in ('boot.img', 'root.img'):
        path = regular(bundle / name)
        if image['images'][name] != {'bytes': path.stat().st_size, 'sha256': digest(path)}:
            raise ValueError('filesystem image identity mismatch: ' + name)
    recovery_manifest = omarchy_recovery.app_inventory(recovery)
    info = plistlib.loads(regular(recovery / 'Contents/Info.plist').read_bytes())
    if info.get('OmarchyRecoveryBuildMode') != 'recovery' or info.get('OmarchyRecoveryDataLayout') != 'external-install-data-v1':
        raise ValueError('requires the real native Recovery build')
    if output.exists() and not reuse_payload:
        raise ValueError('output exists; use a new release directory')
    output.mkdir(parents=True, exist_ok=reuse_payload)
    suffix = '-neo-local' if policy_directory else ''
    payload = output / (profile + suffix + '-' + release_id + '.zip')
    files = {'boot.img': bundle / 'boot.img', 'root.img': bundle / 'root.img',
             'aurora-volume.icns': distribution_icon}
    for path in sorted((bundle / 'esp').rglob('*')):
        if path.is_symlink():
            raise ValueError('ESP contains a symbolic link')
        if path.is_file():
            files['esp/' + path.relative_to(bundle / 'esp').as_posix()] = path
    prefix = 'esp/' + omarchy_recovery.PAYLOAD_DIRECTORY + '/'
    for path in sorted(recovery.rglob('*')):
        if path.is_file():
            files[prefix + omarchy_recovery.APP_NAME + '/' + path.relative_to(recovery).as_posix()] = path
    policies = {}
    if policy_directory:
        for path in sorted(policy_directory.glob('*.bin')):
            name = path.name
            country = 'XZ' if name == 'world-XZ.bin' else name.removesuffix('.bin')
            if name != 'world-XZ.bin' and not re.fullmatch(r'[A-Z]{2}\.bin', name):
                raise ValueError('invalid local policy filename')
            omarchy_mt7932.validate_policy(regular(path).read_bytes(), country)
            member = 'installer-inputs/mt7932-policy/' + name
            files[member] = path
            policies[name] = member
        if 'world-XZ.bin' not in policies:
            raise ValueError('private Neo payload requires its original world-XZ input')
    manifest_name = prefix + omarchy_recovery.MANIFEST_NAME
    manifest_data = (json.dumps(recovery_manifest, sort_keys=True, indent=2) + '\n').encode()
    if reuse_payload:
        # Interrupted metadata assembly can reuse only a closed, fully verified ZIP.
        with zipfile.ZipFile(payload) as archive:
            if set(archive.namelist()) != set(files) | {manifest_name}:
                raise ValueError('existing payload member inventory differs')
            if archive.read(manifest_name) != manifest_data:
                raise ValueError('existing Recovery manifest differs')
            for name, path in files.items():
                with archive.open(name) as stream:
                    observed = hashlib.file_digest(stream, 'sha256').hexdigest()
                if observed != digest(path):
                    raise ValueError('existing payload content differs: ' + name)
    else:
        with zipfile.ZipFile(payload, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=3, allowZip64=True) as archive:
            for name, path in sorted(files.items()):
                regular(path)
                archive.write(path, name)
            archive.writestr(prefix + omarchy_recovery.MANIFEST_NAME, json.dumps(recovery_manifest, sort_keys=True, indent=2) + '\n')
    with zipfile.ZipFile(payload) as archive:
        omarchy_recovery.validate_payload(archive)
        if policies:
            omarchy_mt7932.collect_policy_inputs(archive, {'kind': 'original-j7rp-v1', 'files': policies})
    title = {'fedora': 'Fedora Aurora Remix', 'arch': 'Aurora ALARM', 'nixos': 'Aurora NixOS'}[profile.split('-')[0]]
    template = {
        'omarchy_target': 'apple-silicon-full-os', 'name': title + ' (' + profile.split('-')[1] + ')',
        'default_os_name': title, 'boot_object': 'm1n1.bin', 'next_object': 'm1n1/boot.bin',
        'package': payload.name, 'icon': 'aurora-volume.icns', 'layout_kind': image['layout_kind'],
        'installation_profile': profile, 'recovery_gui': 'omarchy-native-v1',
        # Developer machine/firmware admission; device qualification is separate.
        'partitions': [
            {'name': 'EFI', 'type': 'EFI', 'size': str(image['efi_bytes']) + 'B', 'format': 'fat',
             'copy_firmware': True, 'copy_installer_data': True, 'source': 'esp',
             'volume_id': '0x' + image['efi_volume_id']},
            {'name': 'Boot', 'type': 'Linux', 'size': str(image['images']['boot.img']['bytes']) + 'B', 'image': 'boot.img'},
            {'name': 'Root', 'type': 'Linux', 'size': str(image['images']['root.img']['bytes']) + 'B', 'image': 'root.img', 'expand': True},
        ],
    }
    # The manifest uses apple,jXXX identifiers; the engine uses jXXXap classes.
    import supported_models
    identifiers, _ = supported_models.load()
    template['aurora_stage1'] = {'kind': 'common-raw-v1', 'qualified_machines': {
        identifier.removeprefix('apple,') + 'ap': ['13.5', '14.8.3', '26.6', '26.6.2'] for identifier in identifiers
    }}
    if policies:
        template.update(allowed_device_classes=['j700ap'], supported_fw=['26.6', '26.6.2'],
                        required_neo_peripherals=['radio'],
                        neo_regulatory_policy={'kind': 'original-j7rp-v1', 'files': policies})
        template['aurora_stage1']['qualified_machines'] = {'j700ap': ['26.6', '26.6.2']}
    elif native_neo_reset:
        # Reset keeps the existing per-device firmware on EFI. This test-only
        # catalog carries no factory input and is never adopted into the feed.
        template.update(allowed_device_classes=['j700ap'], supported_fw=['26.6.2'],
                        required_neo_peripherals=['radio'])
        template['aurora_stage1']['qualified_machines'] = {'j700ap': ['26.6.2']}
        template['aurora_stage2'] = {'kind': 'board-file-v1',
                                     'board_members': {'j700ap': 'esp/m1n1/boot-j700.bin'}}
    else:
        template['excluded_device_classes'] = ['j700ap']
    metadata = output / ('installer-data-' + profile + suffix + '.json')
    metadata.write_text(json.dumps({'os_list': [template]}, indent=2) + '\n')
    records = {p.name: {'bytes': p.stat().st_size, 'sha256': digest(p)} for p in (payload, metadata)}
    (output / 'delivery.json').write_text(json.dumps({'schema': 1, 'installation_profile': profile,
        'release_id': release_id, 'private_neo_inputs': bool(policies),
        'native_neo_reset_qa': bool(native_neo_reset),
        'physical_qualification': 'pending', 'artifacts': records}, indent=2) + '\n')
    print(json.dumps(records, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--filesystems', type=Path, required=True)
    parser.add_argument('--recovery-app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--private-neo-policy-directory', type=Path)
    parser.add_argument('--native-neo-reset', action='store_true')
    parser.add_argument('--reuse-payload', action='store_true')
    parser.add_argument('--release-id')
    args = parser.parse_args()
    assemble(args.filesystems, args.recovery_app, args.output, args.private_neo_policy_directory,
             args.reuse_payload, args.release_id, native_neo_reset=args.native_neo_reset)
