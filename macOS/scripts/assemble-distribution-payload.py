#!/usr/bin/env python3
"""Package a finalized distro filesystem bundle and native Recovery template.

One payload serves every supported Mac. It carries no per-Mac firmware,
calibration or radio policy: the native installer collects and derives those
on the Mac being installed.
"""
import argparse
import datetime
import hashlib
import gzip
import io
import json
from pathlib import Path
import plistlib
import re
import struct
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import recovery_payload as aurora_recovery

# Every startup volume shows the Aurora mark: Fedora's, Arch Linux's and
# NixOS's logos are not used for Aurora releases without their owners' permission.
DISTRIBUTION_ICONS = {
    distribution: ROOT / 'Packaging/DistributionIcons/aurora.icns'
    for distribution in ('fedora', 'arch', 'nixos')
}


# The M4 and later Macs the payload must carry a board Stage 2 for, besides the Neo.
OLED_STAGE2_REQUIRED = ('k114c', 'k114s', 'k116c', 'k116s')
BOARD_STAGE2_REQUIRED = ('j604', 'j623', 'j624', 'j713', 'j715', 'j773g', 'j614s', 'j614c',
                         'j616s', 'j616c', 'j773s', 'j575c', 'j813', 'j873g', 'j704', 'j815',
                         'j804', 'j833ct') + OLED_STAGE2_REQUIRED


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def regular(path):
    if not path.is_file() or path.is_symlink():
        raise ValueError('expected regular input: ' + str(path))
    return path


MAX_CONFINED_STAGE2_BYTES = 16 << 20
CONFINED_STAGE2 = re.compile(r'boot-ctxr(?:-([jk][0-9]+[a-z]*))?\.bin')
FDT_MAGIC = b'\xd0\x0d\xfe\xed'


def uses_macho(chip):
    """The native installer's AuraStage1Format.usesMachO: M4 and later. A board
    whose tree names no Apple silicon Mac chip (an A7 iPhone's s5l8960x) is not."""
    return chip is not None and (0x8130 <= chip <= 0x8FFF or 0x6040 <= chip <= 0x6FFF)


def fdt_root_compatible(blob):
    """The root node's compatible strings of the device tree at the start of blob."""
    if len(blob) < 40:
        raise ValueError('short device tree')
    magic, total, structure, strings = struct.unpack_from('>4I', blob)
    strings_size, structure_size = struct.unpack_from('>2I', blob, 32)
    if (magic != 0xD00DFEED or total > len(blob) or structure + structure_size > total
            or strings + strings_size > total):
        raise ValueError('invalid device tree header')
    end = structure + structure_size
    if struct.unpack_from('>I', blob, structure)[0] != 1:
        raise ValueError('device tree has no root node')
    name_end = blob.find(b'\0', structure + 4, end)
    if name_end < 0 or name_end != structure + 4:
        raise ValueError('invalid device tree root name')
    cursor = (name_end + 4) & ~3
    while cursor + 4 <= end:
        token = struct.unpack_from('>I', blob, cursor)[0]
        cursor += 4
        if token == 4:
            continue
        if token != 3 or cursor + 8 > end:
            break
        size, name = struct.unpack_from('>II', blob, cursor)
        cursor += 8
        key = blob[strings + name:blob.find(b'\0', strings + name)]
        value = blob[cursor:cursor + size]
        cursor = (cursor + size + 3) & ~3
        if key == b'compatible':
            return [item.decode('ascii', 'replace') for item in value.split(b'\0') if item]
    raise ValueError('device tree root has no compatible')


def board_chip(path, board):
    """The chip that a board Stage 2's own device tree names as apple,tNNNN, or
    None for a tree that names none (an A7 board names apple,s5l8960x)."""
    data = regular(path).read_bytes()
    cursor = data.find(FDT_MAGIC)
    while cursor >= 0:
        try:
            compatible = fdt_root_compatible(data[cursor:])
        except (ValueError, struct.error):
            compatible = []
        if compatible and compatible[0] == 'apple,' + board:
            for entry in compatible:
                found = re.fullmatch(r'apple,t([0-9a-f]{4})', entry)
                if found:
                    return int(found[1], 16)
            return None
        cursor = data.find(FDT_MAGIC, cursor + 1)
    raise ValueError(path.name + ' has no device tree for ' + board)


def oled_stage2_images(combined, manifest):
    """Derive missing OLED board images from the authenticated common image.

    Earlier image builders kept K-board DTBs in boot.bin but their j-only
    splitters omitted board files. Match every existing board digest before
    using the same Aura prefix and compressed next stage for the missing ones.
    """
    records = manifest['boards']
    missing = [board for board in OLED_STAGE2_REQUIRED if board + 'ap' not in records]
    if not missing:
        return {}
    if len(combined) > 64 << 20 or hashlib.sha256(combined).hexdigest() != manifest['sourceSha256']:
        raise ValueError('OLED Stage 2 common image identity mismatch')
    candidates = []
    start = combined.find(FDT_MAGIC)
    while start >= 0:
        prefix = combined[:start]
        if manifest.get('auraSha256') and hashlib.sha256(prefix).hexdigest() != manifest['auraSha256']:
            start = combined.find(FDT_MAGIC, start + 1)
            continue
        cursor, trees, count = start, {}, 0
        try:
            while combined[cursor:cursor + 4] == FDT_MAGIC:
                if cursor + 8 > len(combined):
                    raise ValueError('truncated OLED device tree')
                size = struct.unpack_from('>I', combined, cursor + 4)[0]
                if size < 40 or cursor + size > len(combined) or count >= 512:
                    raise ValueError('invalid OLED device tree length')
                blob = combined[cursor:cursor + size]
                compatible = fdt_root_compatible(blob)
                if compatible and re.fullmatch(r'apple,[jk][0-9]+[a-z]*', compatible[0]):
                    board = compatible[0].removeprefix('apple,')
                    trees.setdefault(board, []).append(blob)
                cursor += size
                count += 1
            trailer = combined[cursor:]
            if not trees or not trailer.startswith(b'\x1f\x8b\x08'):
                raise ValueError('missing compressed OLED next stage')
            with gzip.GzipFile(fileobj=io.BytesIO(trailer)) as stream:
                if len(stream.read((64 << 20) + 1)) > 64 << 20:
                    raise ValueError('OLED next stage is too large')
            if manifest.get('deviceTreeCount', count) != count:
                raise ValueError('OLED device tree count differs')
            if manifest.get('nextStageSha256', hashlib.sha256(trailer).hexdigest()) != hashlib.sha256(trailer).hexdigest():
                raise ValueError('OLED next stage identity differs')
            for name, record in records.items():
                board = name.removesuffix('ap')
                if board not in trees:
                    raise ValueError('existing board is absent from common Stage 2')
                image = prefix + b''.join(trees[board]) + trailer
                if len(image) != record['bytes'] or hashlib.sha256(image).hexdigest() != record['sha256']:
                    raise ValueError('existing board differs from common Stage 2')
            candidates.append((prefix, trees, trailer))
        except (ValueError, EOFError, OSError, struct.error):
            pass
        start = combined.find(FDT_MAGIC, start + 1)
    if len(candidates) != 1:
        raise ValueError('cannot identify the authenticated OLED Stage 2 components')
    prefix, trees, trailer = candidates[0]
    images = {}
    for board in missing:
        if board not in trees:
            raise ValueError('common Stage 2 has no device tree for ' + board)
        compatible = fdt_root_compatible(trees[board][0])
        chips = [int(match[1], 16) for value in compatible
                 if (match := re.fullmatch(r'apple,t([0-9a-f]{4})', value))]
        if not chips or not uses_macho(chips[0]):
            raise ValueError('OLED device tree does not name a Mach-O Mac chip')
        data = prefix + b''.join(trees[board]) + trailer
        if not data or len(data) > MAX_CONFINED_STAGE2_BYTES:
            raise ValueError('OLED Stage 2 exceeds its 16 MiB slot')
        images[board] = (data, len(trees[board]))
    return images


def complete_oled_stage2(bundle, manifest):
    combined = regular(bundle / 'esp/m1n1/boot.bin').read_bytes()
    images = oled_stage2_images(combined, manifest)
    if not images:
        return {}
    regular(bundle / 'esp/aurora/stage1.macho')
    additions = {}
    # Validate every target before writing any new member. Existing board
    # files and the common image are never replaced.
    for board, (data, count) in images.items():
        for name in (f'boot-{board}.bin', f'boot-ctxr-{board}.bin'):
            path = bundle / 'esp/m1n1' / name
            if (path.exists() or path.is_symlink()) and regular(path).read_bytes() != data:
                raise ValueError('OLED Stage 2 target already differs: ' + name)
        additions[board + 'ap'] = {'member': f'esp/m1n1/boot-{board}.bin',
                                 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                                 'deviceTrees': count}
    for board, (data, _) in images.items():
        for name in (f'boot-{board}.bin', f'boot-ctxr-{board}.bin'):
            path = bundle / 'esp/m1n1' / name
            if not path.exists():
                with path.open('xb') as stream:
                    stream.write(data)
    manifest['boards'].update(additions)
    (bundle / 'stage2.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
    return additions


def check_confined_stage2(bundle, stage2_members):
    """The Stage 2 that a padded Mach-O Stage 1 loads, where the payload has one.

    One payload serves every Mac, so a payload without these files still
    assembles, and the native installer refuses M4 and later Macs on it. Where
    they are present, each supported M4 or later board (scripts/supported-models.json,
    which the signed catalogs enable models from) must find one the way the native
    installer looks: its own boot-ctxr-<board>.bin, else boot-ctxr.bin. A board
    the release doesn't support may have a file or not.
    Returns the members, for the metadata to declare.
    """
    esp = bundle / 'esp'
    confined = sorted((esp / 'm1n1').glob('boot-ctxr*.bin'))
    if not confined:
        return []
    if not (esp / 'aurora/stage1.macho').exists():
        raise ValueError('boot-ctxr files need esp/aurora/stage1.macho, the Stage 1 that loads them')
    boards = {member.removeprefix('esp/m1n1/boot-').removesuffix('.bin'): bundle / member
              for member in stage2_members.values()}
    shared, own = False, set()
    for path in confined:
        found = CONFINED_STAGE2.fullmatch(path.name)
        if not found:
            raise ValueError('unexpected Stage 2 file ' + path.name)
        size = regular(path).stat().st_size
        if not size:
            raise ValueError(path.name + ' is empty')
        if size > MAX_CONFINED_STAGE2_BYTES:
            raise ValueError(path.name + ' is larger than the 16 MiB slot aura keeps for it')
        board = found[1]
        if board is None:
            shared = True
        elif board in boards and uses_macho(board_chip(boards[board], board)):
            own.add(board)
        else:
            raise ValueError(path.name + ' is for a board without an M4 or later Stage 2 here')
    if not shared:
        import supported_models
        supported = {identifier.removeprefix('apple,') for identifier in supported_models.load()[0]}
        missing = sorted(board for board, path in boards.items()
                         if board in supported and board not in own and uses_macho(board_chip(path, board)))
        if missing:
            raise ValueError('no boot-ctxr file for the M4 or later boards ' + ', '.join(missing))
    return ['esp/m1n1/' + path.name for path in confined]


def check_stage1_macho(esp):
    """Every Mac enrolls aura's Mach-O boot object for the common Stage 1, so a
    payload with the common Stage 1 must carry it: the native installer never
    enrolls the raw image.

    aura's tools/macho_boot_object.py carries the raw image unchanged at the
    start of __TEXT_EXEC, file offset 0x10000, with no __TEXT_BOOT_EXEC.
    """
    path = esp / 'aurora/stage1.macho'
    if not path.exists():
        if (esp / 'aurora/stage1.bin').exists():
            raise ValueError('esp/aurora/stage1.bin has no Mach-O boot object (esp/aurora/stage1.macho)')
        return
    raw = regular(esp / 'aurora/stage1.bin').read_bytes()
    obj = regular(path).read_bytes()
    if (obj[:4] != b'\xcf\xfa\xed\xfe' or int.from_bytes(obj[12:16], 'little') != 12
            or b'__TEXT_BOOT_EXEC' in obj[:0x8000] or obj[0x10000:0x10000 + len(raw)] != raw):
        raise ValueError('esp/aurora/stage1.macho is not the Mach-O boot object for esp/aurora/stage1.bin')


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
        source_manifest_sha256 = digest(regular(manifest_path))
        manifest = json.loads(regular(manifest_path).read_text())
        if manifest.get('schema') != 1 or manifest.get('sourceSha256') != digest(regular(bundle / 'esp/m1n1/boot.bin')):
            raise ValueError('Stage 2 source identity mismatch')
        records = manifest.get('boards')
        if not isinstance(records, dict) or not records:
            raise ValueError('missing Stage 2 board records')
        for board, record in records.items():
            if not re.fullmatch(r'[jk][0-9]+[a-z]*ap', board):
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
    # The M4 and later Macs boot only their own board Stage 2 as well. A board missing
    # here has no device tree in the image's kernel.
    for board in BOARD_STAGE2_REQUIRED:
        if board not in OLED_STAGE2_REQUIRED and board + 'ap' not in stage2_members:
            raise ValueError('the J' + board[1:] + ' requires a current board-specific Stage 2')
    check_stage1_macho(bundle / 'esp')
    additions = complete_oled_stage2(bundle, manifest)
    stage2_members.update({board: record['member'] for board, record in additions.items()})
    for board in OLED_STAGE2_REQUIRED:
        if board + 'ap' not in stage2_members:
            raise ValueError('the ' + board.upper() + ' requires a current board-specific Stage 2')
    confined = check_confined_stage2(bundle, stage2_members)
    distribution_icon = regular(DISTRIBUTION_ICONS[profile.split('-')[0]])
    expected_layout = {'fedora': 'fedora', 'arch': 'alarm', 'nixos': 'nixos'}[profile.split('-')[0]] + '-btrfs-v1'
    if image['layout_kind'] != expected_layout or image['root_subvolume'] != 'root':
        raise ValueError('incompatible filesystem layout')
    for name in ('boot.img', 'root.img'):
        path = regular(bundle / name)
        if image['images'][name] != {'bytes': path.stat().st_size, 'sha256': digest(path)}:
            raise ValueError('filesystem image identity mismatch: ' + name)
    recovery_manifest = aurora_recovery.app_inventory(recovery)
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
    prefix = 'esp/' + aurora_recovery.PAYLOAD_DIRECTORY + '/'
    for path in sorted(recovery.rglob('*')):
        if path.is_file():
            files[prefix + aurora_recovery.APP_NAME + '/' + path.relative_to(recovery).as_posix()] = path
    manifest_name = prefix + aurora_recovery.MANIFEST_NAME
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
            archive.writestr(prefix + aurora_recovery.MANIFEST_NAME, json.dumps(recovery_manifest, sort_keys=True, indent=2) + '\n')
    with zipfile.ZipFile(payload) as archive:
        aurora_recovery.validate_payload(archive)
    title = {'fedora': 'Aurora Fedora Remix', 'arch': 'Aurora Alarm', 'nixos': 'Aurora NixOS'}[profile.split('-')[0]]
    # omarchy_target and omarchy-native-v1 are the published metadata contract
    # every released installer reads; they predate the Aurora name.
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
    # Every supported Mac is qualified for the common Stage 1. The M1 Pro, Max
    # and Ultra boards in stage1_caution may have it refused by iBoot; the
    # installer warns their owners, with the recovery steps, before installing.
    supported_models.stage1_caution()
    # The OLED MacBook Pros (K114/K116, T6050) shipped with macOS 27.2 and
    # have no older firmware, so 27.2 is the only one they are qualified on.
    template['aurora_stage1'] = {'kind': 'common-raw-v1', 'qualified_machines': {
        identifier.removeprefix('apple,') + 'ap':
            ['27.2'] if identifier.startswith('apple,k')
            else ['13.5', '14.8.3', '26.6', '26.6.2', '27.0', '27.2']
        for identifier in identifiers
    }}
    if stage2_members:
        template['aurora_stage2'] = {'kind': 'board-file-v1', 'board_members': stage2_members}
    # What M4 and later Macs start from, so the installer can refuse one before
    # the payload and the restore image download. It checks the payload against this later.
    template['aurora_macho_boot'] = {
        'kind': 'padded-ctxr-v1',
        'stage1_member': 'esp/aurora/stage1.macho' if (bundle / 'esp/aurora/stage1.macho').exists() else None,
        'confined_members': confined}
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
    if additions:
        (output / 'stage2-completion.json').write_text(json.dumps({
            'schema': 1, 'source_common_sha256': manifest['sourceSha256'],
            'source_manifest_sha256': source_manifest_sha256, 'added_boards': additions,
            'existing_board_members_changed': False}, indent=2) + '\n')
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
