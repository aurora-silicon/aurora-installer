#!/usr/bin/env python3
"""Package a finalized distro filesystem bundle and native Recovery template.

One payload serves every supported Mac. It carries no per-Mac firmware,
calibration or radio policy: the native installer collects and derives those
on the Mac being installed.
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
import recovery_payload as omarchy_recovery

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


def assemble(bundle, recovery, output, reuse_payload=False, release_id=None):
    release_id = release_id or datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,79}", release_id):
        raise ValueError("invalid delivery release identifier")
    image = json.loads(regular(bundle / 'image.json').read_text())
    profile = image['installation_profile']
    if not re.fullmatch(r'(fedora|arch|nixos)-(kde|gnome|minimal)', profile):
        raise ValueError('unknown installation profile')
    stage2_members = {}
    manifest_path = bundle / 'stage2.json'
    if manifest_path.exists():
        manifest = json.loads(regular(manifest_path).read_text())
        if manifest.get('schema') != 1 or manifest.get('sourceSha256') != digest(regular(bundle / 'esp/m1n1/boot.bin')):
            raise ValueError('Stage 2 source identity mismatch')
        records = manifest.get('boards')
        if not isinstance(records, dict) or not records:
            raise ValueError('missing Stage 2 board records')
        for board, record in records.items():
            if not re.fullmatch(r'j[0-9]+[a-z]*ap', board):
                raise ValueError('invalid Stage 2 board')
            member = record.get('member')
            if member != 'esp/m1n1/boot-' + board.removesuffix('ap') + '.bin':
                raise ValueError('invalid Stage 2 member')
            path = regular(bundle / member)
            if path.stat().st_size != record.get('bytes') or digest(path) != record.get('sha256'):
                raise ValueError('Stage 2 member identity mismatch')
            stage2_members[board] = member
    if 'j700ap' not in stage2_members:
        # The MacBook Neo cannot load the combined Stage 2 that carries every
        # board's device trees, so the shared payload must carry its own.
        raise ValueError('the MacBook Neo requires a current board-specific Stage 2')
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
    payload = output / (profile + '-' + release_id + '.zip')
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
    # The manifest uses apple,jXXX identifiers; Stage 1 qualification uses jXXXap classes.
    import supported_models
    identifiers, _ = supported_models.load()
    template['aurora_stage1'] = {'kind': 'common-raw-v1', 'qualified_machines': {
        identifier.removeprefix('apple,') + 'ap': ['13.5', '14.8.3', '26.6', '26.6.2'] for identifier in identifiers
    }}
    if stage2_members:
        template['aurora_stage2'] = {'kind': 'board-file-v1', 'board_members': stage2_members}
    # The payload admits every supported Mac, including the MacBook Neo. The
    # native installer derives the Neo's firmware, calibration and radio
    # policy on the Mac itself; the payload carries none of them.
    metadata = output / ('installer-data-' + profile + '.json')
    metadata.write_text(json.dumps({'os_list': [template]}, indent=2) + '\n')
    records = {p.name: {'bytes': p.stat().st_size, 'sha256': digest(p)} for p in (payload, metadata)}
    (output / 'delivery.json').write_text(json.dumps({'schema': 1, 'installation_profile': profile,
        # Kept for adoption, which refuses private inputs and Neo-only QA sets.
        'release_id': release_id, 'private_neo_inputs': False, 'native_neo_reset_qa': False,
        'physical_qualification': 'pending', 'artifacts': records}, indent=2) + '\n')
    print(json.dumps(records, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--filesystems', type=Path, required=True)
    parser.add_argument('--recovery-app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--reuse-payload', action='store_true')
    parser.add_argument('--release-id')
    args = parser.parse_args()
    assemble(args.filesystems, args.recovery_app, args.output, args.reuse_payload, args.release_id)
