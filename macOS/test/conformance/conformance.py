#!/usr/bin/env python3
"""Installer conformance matrix: every recorded Mac x distribution x install mode.

For each cell it replays the machine through the native installer's own
inspection, firmware selection, planning and boot-chain admission
(Development/InstallerDryRun), then checks the pinned boot chain, the
distribution payload and the One True Recovery step against that result.

    conformance.py --dry-run PATH/TO/InstallerDryRun \
        [--distro fedora=DIR --distro arch=DIR --distro nixos=DIR] \
        [--catalogs URL_OR_DIR] [--digests DIR] [--cache DIR] \
        [--markdown OUT.md] [--json OUT.json]

Modes:
  fresh         every existing non-macOS install removed first (macOS only)
  side-by-side  the machine as captured, with its existing install kept

Verdicts: PASS (everything a dry run can prove holds), FAIL (a check failed,
with the reason) and UNTESTED-ON-HW (all software checks hold; the listed
hardware test is still needed). Nothing here writes to a disk, signs, or
talks to a Mac.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
import zlib

HERE = Path(__file__).resolve().parent
MACOS = HERE.parents[1]
REPO = MACOS.parent
DISTROS = {'fedora': 'fedora-aurora', 'arch': 'alarm-aurora', 'nixos': 'nixos-aurora'}
DESKTOPS = ('gnome', 'kde', 'minimal')
MODES = ('fresh', 'side-by-side')


def identity_value(name):
    """A hosting value from Packaging/identity.conf, the one place it is set."""
    conf = HERE.parents[1] / 'Packaging/identity.conf'
    for line in conf.read_text().splitlines():
        key, _, value = line.partition('=')
        if key.strip() == name:
            return value.strip().strip('"')
    raise KeyError(name)


DEFAULT_CATALOGS = identity_value('INSTALLER_PUBLIC_BASE') + '/installer/Profiles'
TYPE_NAMES = {
    '69646961-6700-11aa-aa11-00306543ecac': 'Apple_APFS_ISC',
    '7c3457ef-0000-11aa-aa11-00306543ecac': 'Apple_APFS',
    '52637672-7900-11aa-aa11-00306543ecac': 'Apple_APFS_Recovery',
    'c12a7328-f81f-11d2-ba4b-00a0c93ec93b': 'EFI',
    '0fc63daf-8483-4772-8e79-3d69d8477de4': 'Linux Filesystem',
}
STUB_FILE_LIMIT = 10000  # a stub System volume holds tens of files, macOS hundreds of thousands
TRUST_ROOT_DER_PREFIX = bytes.fromhex('302a300506032b6570032100')


# ---------------------------------------------------------------- pins

def installer_pins():
    """The pins this installer tree ships: the aura submodule and U-Boot ref."""
    aura = subprocess.run(['git', '-C', str(REPO), 'ls-tree', 'HEAD', 'aura'], capture_output=True,
                          text=True, check=True).stdout.split()
    workflow = (REPO / '.github/workflows/uefi-only-build.yaml').read_text()
    uboot = re.search(r'repository:\s*aurora-silicon/u-boot\s*\n(?:.*\n){0,3}?\s*ref:\s*([0-9a-f]{40})', workflow)
    label = re.search(r'Aurora U-Boot (\S+)', workflow)
    return {'aura': aura[2] if len(aura) > 2 else None,
            'u_boot': uboot.group(1) if uboot else None,
            'u_boot_label': label.group(1) if label else None}


def distro_sources(path):
    data = json.loads((Path(path) / 'sources.json').read_text())
    uboot = data.get('uboot-aurora') or data.get('uboot-asahi') or {}
    return {'aura': data.get('aura', {}).get('commit'), 'aura_version': data.get('aura', {}).get('version'),
            'u_boot': uboot.get('commit'), 'kernel': data.get('kernel-aurora', {}).get('commit'),
            'kernel_repository': data.get('kernel-aurora', {}).get('repository')}


def published_sources(repo, sha, cache):
    return json.loads(fetch('https://raw.githubusercontent.com/aurora-silicon/%s/%s/sources.json' % (repo, sha),
                            cache).decode())


# ---------------------------------------------------------------- network

def fetch(url, cache, headers=None):
    key = hashlib.sha256((url + json.dumps(headers or {}, sort_keys=True)).encode()).hexdigest()
    path = Path(cache) / key
    if path.exists():
        return path.read_bytes()
    request = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(request, timeout=120) as response:
        data = response.read()
    path.write_bytes(data)
    return data


def public(url):
    """True when the URL downloads without credentials (HEAD, following redirects)."""
    request = urllib.request.Request(url, method='HEAD')
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status == 200, int(response.headers.get('Content-Length') or -1)
    except Exception as error:  # report, never guess
        return False, repr(error)


class RemoteZip:
    """Reads members of a ZIP that may be published as several parts, by HTTP range."""

    def __init__(self, parts, cache):
        self.parts, self.cache = parts, cache
        self.size = sum(size for _, size in parts)

    def read(self, offset, count):
        out, base = b'', 0
        for url, size in self.parts:
            if offset + count <= base:
                break
            if offset < base + size:
                a, b = max(offset, base) - base, min(offset + count, base + size) - base
                out += fetch(url, self.cache, {'Range': 'bytes=%d-%d' % (a, b - 1)})
            base += size
        if len(out) != count:
            raise ValueError('short range read')
        return out

    def members(self):
        tail = self.read(max(0, self.size - 65557), min(self.size, 65557))
        end = tail.rfind(b'PK\x05\x06')
        count = struct.unpack('<H', tail[end + 10:end + 12])[0]
        size, offset = struct.unpack('<II', tail[end + 12:end + 20])
        if 0xffffffff in (size, offset) or count == 0xffff:
            locator = tail.rfind(b'PK\x06\x07')
            record = self.read(struct.unpack('<Q', tail[locator + 8:locator + 16])[0], 56)
            count, size, offset = struct.unpack('<QQQ', record[32:56])
        directory = self.read(offset, size)
        position, result = 0, {}
        while directory[position:position + 4] == b'PK\x01\x02':
            method = struct.unpack('<H', directory[position + 10:position + 12])[0]
            crc, csize, usize = struct.unpack('<III', directory[position + 16:position + 28])
            nlen, elen, clen = struct.unpack('<HHH', directory[position + 28:position + 34])
            header = struct.unpack('<I', directory[position + 42:position + 46])[0]
            name = directory[position + 46:position + 46 + nlen].decode()
            extra = directory[position + 46 + nlen:position + 46 + nlen + elen]
            q = 0
            while q < len(extra):
                tag, length = struct.unpack('<HH', extra[q:q + 4])
                if tag == 1:
                    field, k = extra[q + 4:q + 4 + length], 0
                    if usize == 0xffffffff:
                        usize = struct.unpack('<Q', field[k:k + 8])[0]; k += 8
                    if csize == 0xffffffff:
                        csize = struct.unpack('<Q', field[k:k + 8])[0]; k += 8
                    if header == 0xffffffff:
                        header = struct.unpack('<Q', field[k:k + 8])[0]; k += 8
                q += 4 + length
            result[name] = {'method': method, 'crc': crc, 'csize': csize, 'usize': usize, 'header': header}
            position += 46 + nlen + elen + clen
        return result

    def extract(self, member):
        header = self.read(member['header'], 30)
        nlen, elen = struct.unpack('<HH', header[26:30])
        data = self.read(member['header'] + 30 + nlen + elen, member['csize'])
        if member['method'] == 8:
            data = zlib.decompressobj(-15).decompress(data)
        if zlib.crc32(data) != member['crc'] or len(data) != member['usize']:
            raise ValueError('ZIP member CRC mismatch')
        return data


# ---------------------------------------------------------------- catalogs

def load_catalog(base, profile, cache):
    """Fetch and authenticate a profile's signed catalog with the app's trust root."""
    root = (MACOS / 'Release/trust-root.ed25519.pub').read_bytes()
    if base.startswith('http'):
        catalog = fetch('%s/%s/catalog.json' % (base, profile), cache)
        signature = fetch('%s/%s/catalog.json.sig' % (base, profile), cache)
    else:
        catalog = (Path(base) / profile / 'catalog.json').read_bytes()
        signature = (Path(base) / profile / 'catalog.json.sig').read_bytes()
    with tempfile.TemporaryDirectory() as temporary:
        key, body, sig = (Path(temporary) / n for n in ('key.der', 'catalog.json', 'catalog.sig'))
        key.write_bytes(TRUST_ROOT_DER_PREFIX + root)
        body.write_bytes(catalog)
        sig.write_bytes(signature)
        verified = subprocess.run(['openssl', 'pkeyutl', '-verify', '-pubin', '-keyform', 'DER', '-inkey', str(key),
                                   '-rawin', '-in', str(body), '-sigfile', str(sig)],
                                  capture_output=True).returncode == 0
    return json.loads(catalog), verified


# ---------------------------------------------------------------- machines

def swift_machine(fixture, mode, constraints):
    """The NativeInstallerDryRunMachine document for one fixture and mode."""
    firmware = fixture['firmware']
    recovery = constraints['recovery_long_versions'].get(firmware['system_os'])
    hardware = {'chipID': constraints['chip_ids'][fixture['soc']], 'bootVersion': firmware['system_iboot'],
                'macOSVersion': firmware['system_os'], 'recoveryVersion': recovery}
    disk = fixture['disk'] or synthetic_disk()
    parts = [dict(p) for p in disk['partitions']]
    macos = macos_partition(parts)
    if mode == 'fresh':
        keep = {'Apple_APFS_ISC', 'Apple_APFS_Recovery'}
        parts = [p for p in parts if TYPE_NAMES[p['type']] in keep or p is macos]
    snapshot_parts, containers, facts = [], [], []
    for number, part in enumerate(parts):
        kind = TYPE_NAMES[part['type']]
        snapshot_parts.append({'identifier': 'disk0s%d' % part['index'], 'uuid': part['uuid'].upper(), 'type': kind,
                               'offset': part['offset'], 'size': part['size'], 'name': part.get('fat_label', '')})
        apfs = part.get('apfs')
        if not apfs:
            continue
        volumes = []
        for index, volume in enumerate(apfs['volumes']):
            row = {'uuid': volume['uuid'].upper(), 'name': volume['name'], 'roles': [volume['role']] if volume['role'] else [],
                   'identifier': 'disk%ds%d' % (number + 1, index + 1)}
            if volume['group'] and volume['role'] in ('System', 'Data'):
                row['group'] = volume['group'].upper()
            volumes.append(row)
        containers.append({'uuid': apfs['uuid'].upper(), 'storeUUID': part['uuid'].upper(), 'volumes': volumes})
        systems = []
        for volume in apfs['volumes']:
            if volume['role'] != 'System':
                continue
            stub = volume['files'] < STUB_FILE_LIMIT
            systems.append({'group': volume['group'].upper(), 'label': volume['name'], 'stub': stub,
                            'version': None if stub else firmware['system_os']})
        # diskutil's MinimumSizePreferred is not readable from Linux; the used
        # bytes are its floor, and the inspection's own reserve (used + 38 GB)
        # is larger, so the estimate cannot widen a plan.
        facts.append({'storeUUID': part['uuid'].upper(), 'capacity': apfs['capacity'], 'free': apfs['free'],
                      'preferredMinimum': apfs['capacity'] - apfs['free'], 'systems': systems})
    return {'deviceIdentifier': fixture['device_identifier'], 'hardware': hardware,
            'snapshot': {'disk': 'disk0', 'devicePath': '/dev/disk0', 'diskSize': disk['size'],
                         'macOSStoreUUID': macos['uuid'].upper(), 'macOSContainerUUID': macos['apfs']['uuid'].upper(),
                         'partitions': snapshot_parts, 'containers': containers},
            'containers': facts}


def macos_partition(parts):
    found = [p for p in parts if p.get('apfs') and TYPE_NAMES[p['type']] == 'Apple_APFS' and any(
        v['role'] == 'System' and v['files'] >= STUB_FILE_LIMIT for v in p['apfs']['volumes'])]
    if len(found) != 1:
        raise ValueError('expected exactly one macOS container')
    return found[0]


def synthetic_disk():
    """A placeholder disk for identity-only fixtures: it exercises support,
    firmware and boot-chain admission, never a plan verdict."""
    gib = 1 << 30
    return {'size': 1000 * gib, 'block_size': 4096, 'synthetic': True, 'partitions': [
        {'index': 1, 'type': '69646961-6700-11aa-aa11-00306543ecac', 'uuid': '00000000-0000-4000-8000-0000000000f1',
         'offset': 24576, 'size': 500 * 1024 * 1024, 'apfs': None},
        {'index': 2, 'type': '7c3457ef-0000-11aa-aa11-00306543ecac', 'uuid': '00000000-0000-4000-8000-0000000000f2',
         'offset': 524312576, 'size': 400 * gib, 'apfs': {
             'uuid': '00000000-0000-4000-8000-0000000000f3', 'capacity': 400 * gib, 'free': 300 * gib, 'volumes': [
                 {'name': 'Macintosh HD', 'role': 'System', 'uuid': '00000000-0000-4000-8000-0000000000f4',
                  'group': '00000000-0000-4000-8000-0000000000f5', 'files': 300000, 'alloc_bytes': 0},
                 {'name': 'Data', 'role': 'Data', 'uuid': '00000000-0000-4000-8000-0000000000f6',
                  'group': '00000000-0000-4000-8000-0000000000f5', 'files': 1, 'alloc_bytes': 0},
                 {'name': 'Preboot', 'role': 'Preboot', 'uuid': '00000000-0000-4000-8000-0000000000f7',
                  'group': None, 'files': 1, 'alloc_bytes': 0},
                 {'name': 'Recovery', 'role': 'Recovery', 'uuid': '00000000-0000-4000-8000-0000000000f8',
                  'group': None, 'files': 1, 'alloc_bytes': 0}]}},
    ]}


# ---------------------------------------------------------------- payload

def stage2_contents(data):
    """The aura version marker, device trees and U-Boot carried by a Stage 2 file."""
    end = data.rfind(b'STACKBOT') + 8
    version = set(m.decode() for m in re.findall(rb'##(?:aura|m1n1)_ver##[ -~]*', data[:end]))
    trees, uboot, position = [], None, end
    while 0 < position < len(data):
        if data[position:position + 2] == b'\x1f\x8b':
            stream = zlib.decompressobj(16 + 15)
            blob = stream.decompress(data[position:])
            used = len(data) - position - len(stream.unused_data)
            if blob[:4] == b'\xd0\x0d\xfe\xed':
                trees.append(fdt_root(blob))
            elif blob[0x38:0x3c] == b'ARM\x64':
                found = re.search(rb'U-Boot (20[0-9.]+[-+a-z0-9]*)', blob)
                uboot = found.group(1).decode() if found else 'unlabelled'
            position += used
        elif data[position:position + 4] == b'\xd0\x0d\xfe\xed':
            size = int.from_bytes(data[position + 4:position + 8], 'big')
            trees.append(fdt_root(data[position:position + size]))
            position += size
        elif data[position:position + 1] == b'\0':
            position += 1
        else:
            break
    return {'versions': sorted(version), 'device_trees': trees, 'u_boot': uboot}


def fdt_root(blob):
    structure, strings = int.from_bytes(blob[8:12], 'big'), int.from_bytes(blob[12:16], 'big')
    position, depth, props = structure, 0, {}
    while position < len(blob):
        token = int.from_bytes(blob[position:position + 4], 'big')
        position += 4
        if token == 1:
            position = (blob.index(b'\0', position) + 4) & ~3
            depth += 1
        elif token == 2:
            depth -= 1
            if depth == 0:
                break
        elif token == 3:
            length, name = struct.unpack('>II', blob[position:position + 8])
            position += 8
            key = blob[strings + name:blob.index(b'\0', strings + name)].decode()
            if depth == 1 and key in ('compatible', 'model'):
                props[key] = blob[position:position + length].split(b'\0')[0].decode()
            position = (position + length + 3) & ~3
        elif token == 9:
            break
    return props


def stage1_version(data):
    return sorted(set(m.decode() for m in re.findall(rb'##(?:aura|m1n1)_ver##[ -~]*', data)))


def esp_archive(remote, members, wanted, path):
    """A local ZIP with every ESP member name; the members the dry run reads hold
    their real CRC-checked bytes and the rest a one-byte placeholder."""
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as archive:
        for name in sorted(members):
            if not name.startswith('esp/') and name != 'aurora-volume.icns':
                continue
            if name.endswith('/'):
                continue
            archive.writestr(name, remote.extract(members[name]) if name in wanted else b'\0')


# ---------------------------------------------------------------- cells

def check(name, ok, detail, hardware=None, scope=None):
    """scope 'published' marks checks of today's signed images rather than the pins."""
    return {'check': name, 'ok': ok, 'detail': detail, 'hardware': hardware, 'scope': scope}


def evaluate(machine, mode, distro, dry, context):
    """Every check for one cell. `dry` maps desktop -> dry-run result."""
    checks = []
    board = machine['device_identifier'].removeprefix('apple,') + 'ap'
    sample = dry[DESKTOPS[0]]
    profiles = context['profiles'][distro]

    # 1. machine support: native inspection policy and every signed catalog
    enabled = [d for d in DESKTOPS if machine['device_identifier'] in profiles[d]['enabled']]
    unsigned = [d for d in DESKTOPS if not profiles[d]['verified']]
    ok = sample['supported'] and len(enabled) == len(DESKTOPS) and not unsigned
    reason = []
    if not sample['supported']:
        reason.append('native inspection refuses %s: %s' % (machine['device_identifier'], sample.get('unsupported_reason')))
    if len(enabled) != len(DESKTOPS):
        reason.append('signed catalog enables it for %s of %s desktops' % (len(enabled), len(DESKTOPS)))
    if unsigned:
        reason.append('catalog signature did not verify for %s' % ', '.join(unsigned))
    checks.append(check('supported', ok, '; '.join(reason) or 'inspection policy and all three signed catalogs admit it'))
    if not sample['supported']:
        return checks

    # 2. stub firmware selection
    fw = sample.get('firmware')
    checks.append(check('stub firmware', fw is not None,
                        'selects macOS %s stub (%d B container) from %s' % (fw['version'], fw['stub_bytes'], fw['source_url'])
                        if fw else 'no stub firmware: %s' % sample.get('firmware_error')))
    if not fw:
        return checks

    # 3. Stage 1: filled by the installer, the pinned aura, and within iBoot's known limits
    problems, notes, published = [], [], []
    for desktop in DESKTOPS:
        chain, payload = dry[desktop].get('boot_chain'), profiles[desktop]['payload']
        if not chain:
            problems.append('%s: boot chain refused (%s)' % (desktop, dry[desktop].get('boot_chain_error')))
            continue
        if 'stage1_member' not in chain:
            problems.append('%s: no Stage 1 for %s on the %s stub' % (desktop, board, fw['version']))
            continue
        versions = payload['stage1_versions']
        if not any(v.endswith('##' + context['pins']['aura_label']) for v in versions):
            published.append('%s %s' % (desktop, ', '.join(v.split('##')[-1] for v in versions) or 'unlabelled'))
        notes.append('%s %d B' % (desktop, chain['stage1_bytes']))
    checks.append(check('published stage1', not published, 'payload Stage 1 is not aura %s: %s' % (
        context['pins']['aura_label'], '; '.join(published)) if published else 'payload Stage 1 is aura ' +
        context['pins']['aura_label'], scope='published'))
    limit = context['constraints']['stage1_iboot'].get(board)
    # Without the pinned Stage 1 at hand, the payload's own Stage 1 is the size iBoot sees.
    size = context['pins'].get('stage1_bytes') or max(
        [dry[d]['boot_chain']['stage1_bytes'] for d in DESKTOPS if 'stage1_bytes' in (dry[d].get('boot_chain') or {})],
        default=None)
    if limit and fw['version'] in limit['stub_os'] and size and size >= min(limit['rejected_bytes']):
        problems.append('iBoot on %s (%s stub) rejects the pinned %d B aura Stage 1: %s' % (
            board, fw['version'], size, limit['evidence']))
    proven = context['constraints']['proven_stage1'].get(board)
    checks.append(check('stage1', not problems, '; '.join(problems) or 'filled for ' + ', '.join(notes),
                        None if proven else 'boot the pinned Stage 1 on this board through a real 1TR install'))

    # 4. Stage 2 composition for this board
    problems, published = [], []
    for desktop in DESKTOPS:
        chain, payload = dry[desktop].get('boot_chain'), profiles[desktop]['payload']
        if not chain:
            continue
        selected = [k for k, v in chain['esp_layout'].items() if v == 'm1n1/boot.bin']
        if selected != ['esp/m1n1/boot-%s.bin' % board.removesuffix('ap')]:
            problems.append('%s: Stage 2 for %s is %s, not its board file' % (desktop, board, selected))
            continue
        contents = payload['stage2'].get(board)
        trees = [t.get('compatible') for t in contents['device_trees']]
        if trees != [machine['device_identifier']]:
            problems.append('%s: Stage 2 carries device trees %s' % (desktop, trees))
        if not contents['u_boot']:
            problems.append('%s: Stage 2 carries no U-Boot' % desktop)
        if not any(v.endswith('##' + context['pins']['aura_label']) for v in contents['versions']):
            published.append('%s %s with U-Boot %s' % (
                desktop, ', '.join(v.split('##')[-1] for v in contents['versions']), contents['u_boot']))
    checks.append(check('stage2', not problems, '; '.join(problems) or
                        'board Stage 2 carries only the %s device tree and U-Boot' % machine['device_identifier']))
    checks.append(check('published stage2', not published, 'payload Stage 2 is not aura %s: %s' % (
        context['pins']['aura_label'], '; '.join(published)) if published else 'payload Stage 2 is aura ' +
        context['pins']['aura_label'], scope='published'))

    # 5. U-Boot and aura pins: the distro branch, and the published image's sources
    branch, built = context['branches'][distro], context['built'][distro]
    pins = context['pins']
    for label, sources, scope in (('branch', branch, None), ('published image', built, 'published')):
        if sources is None:
            continue
        problems = []
        if sources['u_boot'] != pins['u_boot']:
            problems.append('U-Boot %s, pin %s' % ((sources['u_boot'] or '?')[:12], pins['u_boot'][:12]))
        if sources['aura'] != pins['aura']:
            problems.append('aura %s, pin %s' % ((sources['aura'] or '?')[:12], pins['aura'][:12]))
        checks.append(check(label + ' pins', not problems, '; '.join(problems) or 'aura %s and U-Boot %s' % (
            pins['aura'][:12], pins['u_boot'][:12]), scope=scope))
    parity = context['parity']
    lag = parity['lagging'].get(distro)
    checks.append(check('distro parity', not lag, lag or 'kernel, aura and U-Boot match the other distributions'))

    # 6. the distribution image: public, sized and digest-checked
    problems, digests = [], []
    for desktop in DESKTOPS:
        payload = profiles[desktop]['payload']
        for url, ok in payload['public'].items():
            if ok is not True:
                problems.append('%s: %s is not publicly downloadable (%s)' % (desktop, url.rsplit('/', 1)[-1], ok))
        result = payload.get('digest')
        if result is None:
            digests.append(desktop)
        elif not result['ok']:
            problems.append('%s: %s' % (desktop, result['detail']))
    detail = '; '.join(problems) or 'all parts public; ' + (
        'all part digests match the signed catalog' if not digests else 'digests not checked in this run for ' + ', '.join(digests))
    checks.append(check('published image', False if problems else (None if digests else True), detail, scope='published'))

    # 7. kernel: built from the pinned source, with this board's device tree
    kernel = context['kernels'][distro]
    checks.append(check('kernel', kernel['has_board'].get(machine['device_identifier'], False) and kernel['ok'],
                        kernel['detail'] % {'board': machine['device_identifier']}))

    # 8. partition plan for this mode
    if machine['disk'] is None:
        checks.append(check('plan', None, 'no disk capture for this machine (down); run collect-machine-profile.py when it is up',
                            'capture the disk read-only, then re-run'))
    else:
        checks.append(plan_check(machine, mode, sample, fw))

    # 9. One True Recovery step
    expected = ['-nca'] if machine['device_identifier'] == 'apple,j700' else ['-nc']
    selection = (MACOS / 'Recovery/Sources/BootSelection.swift').read_text()
    raw = all(flag in selection for flag in ('"--raw"', '"--entry-point", "2048"', '"--lowest-virtual-address", "0"'))
    steps = [c.get('plan', {}).get('required_human_steps') for c in sample.get('candidates', [])]
    fresh_steps = all(s is None or 'enterOneTrueRecovery' in s for s in steps)
    ok = sample['one_true_recovery_boot_policy'] == expected and raw and fresh_steps
    checks.append(check('1tr', ok, 'bputil %s -v <group>, kmutil configure-boot --raw --entry-point 2048 '
                                  '--lowest-virtual-address 0' % ' '.join(sample['one_true_recovery_boot_policy'])
                        if ok else 'boot policy %s (expected %s), raw enrollment %s' % (
                            sample['one_true_recovery_boot_policy'], expected, raw),
                        'run the paired 1TR step on this machine'))
    return checks


def plan_check(machine, mode, result, firmware):
    parts = machine['disk']['partitions']
    macos = macos_partition(parts)
    kinds = ('free', 'resize')
    candidates = [c for c in result['candidates'] if c['kind'] in kinds]
    planned = [c for c in candidates if 'plan' in c]
    if not planned:
        refused = '; '.join('%s %s: %s' % (c['kind'], c['source'], c.get('plan_error')) for c in candidates)
        a = macos['apfs']
        floor = min((c['minimum_install_bytes'] for c in candidates), default=0)
        short = (a['capacity'] - a['free']) + 38_000_000_000 + floor - a['capacity']
        return check('plan', False, 'no space for a new install: ' + (refused or 'no free or shrinkable space') +
                     container_summary(macos) + ('; free about %.1f GB more in macOS to fit the smallest install' % (
                         short / 1e9) if short > 0 else ''))
    best = max(planned, key=lambda c: (c['kind'] == 'free', c['plan']['length_bytes']))
    plan = best['plan']
    start, end = plan['offset_bytes'], plan['offset_bytes'] + plan['length_bytes']
    kept = [p for p in parts if mode == 'side-by-side' or TYPE_NAMES[p['type']] in (
        'Apple_APFS_ISC', 'Apple_APFS_Recovery') or p is macos]
    for part in kept:
        lo, hi = part['offset'], part['offset'] + part['size']
        if part is macos and best['kind'] == 'resize':
            if start < lo + best['minimum_container_bytes'] or end != hi:
                return check('plan', False, 'resize plan reaches into the kept macOS data')
            continue
        if start < hi and lo < end:
            return check('plan', False, 'plan overlaps kept partition %d' % part['index'])
    sizes = ', '.join('%s %.1f GB' % (p['name'], p['bytes'] / 1e9) for p in plan.get('os_partitions', []))
    room = best['length_bytes'] - (best['minimum_container_bytes'] if best['kind'] == 'resize' else 0)
    return check('plan', True, '%s %s: recommended %.1f GB of %.1f GB available, at %.1f GB (stub %.1f GB, %s); '
                 'macOS untouched%s' % (
        best['kind'], best['source'], plan['length_bytes'] / 1e9, room / 1e9, start / 1e9,
        firmware['stub_bytes'] / 1e9, sizes,
        ' except shrinking its free space' if best['kind'] == 'resize' else ''))


def container_summary(macos):
    a = macos['apfs']
    used = a['capacity'] - a['free']
    return ' (macOS container %.1f GB, %.1f GB used; a resize keeps used + 38 GB)' % (a['capacity'] / 1e9, used / 1e9)


def verdict(checks, at_pin=False):
    if at_pin:
        checks = [c for c in checks if c.get('scope') != 'published']
    if any(c['ok'] is False for c in checks):
        return 'FAIL'
    if any(c['ok'] is None for c in checks) or any(c['hardware'] for c in checks):
        return 'UNTESTED-ON-HW'
    return 'PASS'


# ---------------------------------------------------------------- driver

def run_dry(binary, machine, metadata, digest, archive):
    with tempfile.TemporaryDirectory() as temporary:
        m, md = Path(temporary) / 'machine.json', Path(temporary) / 'metadata.json'
        m.write_text(json.dumps(machine))
        md.write_bytes(metadata)
        arguments = [binary, '--machine', str(m), '--metadata', str(md), '--payload-digest', digest]
        if archive:
            arguments += ['--esp-archive', str(archive)]
        out = subprocess.run(arguments, capture_output=True, text=True)
        if out.returncode:
            raise RuntimeError('InstallerDryRun failed: ' + out.stderr.strip())
        return json.loads(out.stdout)


def kernel_facts(distro, sources, cache):
    repository = (sources['kernel_repository'] or '').removeprefix('https://github.com/')
    commit = sources['kernel']
    listing = json.loads(fetch('https://api.github.com/repos/%s/contents/arch/arm64/boot/dts/apple?ref=%s' % (
        repository, commit), cache, github_headers()))
    names = {item['name'] for item in listing}
    boards = {}
    for name in names:
        found = re.fullmatch(r't[0-9]+-(j[0-9]+[a-z]*)\.dts', name)
        if found:
            boards['apple,' + found.group(1)] = True
    return {'commit': commit, 'has_board': boards, 'ok': True,
            'detail': 'kernel %s (%s) has the %%(board)s device tree' % (commit[:12], repository)}


def distro_parity(sources, cache):
    """Which distributions pin an older kernel, aura or U-Boot than another."""
    lagging = {}
    for key, label in (('kernel', 'kernel'), ('aura', 'aura'), ('u_boot', 'U-Boot')):
        commits = {d: s[key] for d, s in sources.items() if s and s[key]}
        repo = {'kernel': 'linux', 'aura': 'aura', 'u_boot': 'u-boot'}[key]
        for d, commit in commits.items():
            for other, theirs in commits.items():
                if theirs == commit:
                    continue
                compare = json.loads(fetch('https://api.github.com/repos/aurora-silicon/%s/compare/%s...%s' % (
                    repo, commit, theirs), cache, github_headers()))
                if compare.get('ahead_by', 0) > 0:
                    lagging.setdefault(d, [])
                    lagging[d].append('%s %s is %d commits behind %s %s' % (
                        label, commit[:12], compare['ahead_by'], other, theirs[:12]))
    return {'lagging': {d: '; '.join(v) for d, v in lagging.items()}}


def github_headers():
    token = os.environ.get('GITHUB_TOKEN')
    return {'Authorization': 'Bearer ' + token} if token else {}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--dry-run', required=True, help='InstallerDryRun executable')
    parser.add_argument('--distro', action='append', default=[], help='NAME=CHECKOUT of a distro branch under test')
    parser.add_argument('--catalogs', default=DEFAULT_CATALOGS)
    parser.add_argument('--digests', help='directory of payload digest results (*.result); with --verify-digests, '
                        'where to write them')
    parser.add_argument('--verify-digests', action='store_true',
                        help='download every payload part and check its SHA-256 against the signed catalog')
    parser.add_argument('--expect', help='expected at-pin verdicts; exit 1 only when a cell does worse')
    parser.add_argument('--stage1', help='the pinned aura raw Stage 1, to apply known iBoot size limits')
    parser.add_argument('--machines', default=str(HERE / 'fixtures/machines'))
    parser.add_argument('--cache', default=os.path.join(tempfile.gettempdir(), 'installer-conformance-cache'))
    parser.add_argument('--markdown')
    parser.add_argument('--json')
    args = parser.parse_args()
    Path(args.cache).mkdir(parents=True, exist_ok=True)
    constraints = json.loads((HERE / 'fixtures/constraints.json').read_text())
    pins = installer_pins()
    pins['aura_label'] = fetch('https://raw.githubusercontent.com/aurora-silicon/aura/%s/VERSION' % pins['aura'],
                               args.cache).decode().strip()
    if args.stage1:
        pins['stage1_bytes'] = Path(args.stage1).stat().st_size
    branches = {name: None for name in DISTROS}
    for item in args.distro:
        name, path = item.split('=', 1)
        branches[name] = distro_sources(path)
    machines = [json.loads(p.read_text()) for p in sorted(Path(args.machines).glob('*.json'))]
    boards = {m['device_identifier'].removeprefix('apple,') for m in machines}

    profiles, built, kernels, dry = {}, {}, {}, {}
    for distro, repo in DISTROS.items():
        profiles[distro] = {}
        for desktop in DESKTOPS:
            profile = '%s-%s' % (distro, desktop)
            catalog, verified = load_catalog(args.catalogs, profile, args.cache)
            enabled = {m['deviceIdentifier'] for m in catalog['models'] if m['status'] == 'enabled'}
            model = next(m for m in catalog['models'] if m['status'] == 'enabled')
            artifact = model['payloadArtifact']
            parts = [(p['sourceURL'], p['sizeBytes']) for p in artifact.get('parts') or []] or [
                (artifact['sourceURL'], artifact['sizeBytes'])]
            remote = RemoteZip(parts, args.cache)
            members = remote.members()
            metadata = fetch(model['metadataArtifact']['sourceURL'], args.cache)
            if 'sha256:' + hashlib.sha256(metadata).hexdigest() != model['metadataDigest']:
                raise SystemExit('metadata digest mismatch: ' + profile)
            wanted = {'esp/aurora/stage1.bin', 'aurora-volume.icns'} | {'esp/m1n1/boot-%s.bin' % b for b in boards}
            archive = Path(args.cache) / (profile + '-' + model['payloadDigest'][7:19] + '-esp.zip')
            if not archive.exists():
                esp_archive(remote, members, wanted, archive)
            with zipfile.ZipFile(archive) as z:
                stage1 = z.read('esp/aurora/stage1.bin')
                stage2 = {b + 'ap': stage2_contents(z.read('esp/m1n1/boot-%s.bin' % b)) for b in boards
                          if 'esp/m1n1/boot-%s.bin' % b in z.namelist()}
            public_state = {url: (lambda r: True if r[0] and r[1] in (size, -1) else r)(public(url)) for url, size in parts}
            digest = None
            if args.verify_digests:
                verify_parts(profile, payload_parts(model), args.digests)
            if args.digests:
                results = [json.loads((Path(args.digests) / (p['fileName'] + '.result')).read_text())
                           for p in payload_parts(model) if (Path(args.digests) / (p['fileName'] + '.result')).exists()]
                if len(results) == len(payload_parts(model)):
                    bad = [r['file'] for r in results if not r['ok']]
                    digest = {'ok': not bad, 'detail': 'digest mismatch: ' + ', '.join(bad) if bad else 'all part digests match'}
            source = model.get('evidenceRevision', '')
            run = re.search(r'(\d+)$', source)
            image = json.loads(fetch('https://api.github.com/repos/aurora-silicon/%s/actions/runs/%s' % (repo, run.group(1)),
                                     args.cache, github_headers())) if run else {}
            profiles[distro][desktop] = {
                'enabled': enabled, 'verified': verified, 'metadata': metadata, 'digest_id': model['payloadDigest'],
                'archive': archive, 'payload': {'stage1_versions': stage1_version(stage1), 'stage2': stage2,
                                                'public': public_state, 'digest': digest},
                'image_source': image.get('head_sha'), 'payload_name': artifact['fileName'],
            }
        sha = profiles[distro][DESKTOPS[0]]['image_source']
        built[distro] = distro_sources_from(published_sources(repo, sha, args.cache)) if sha else None
        kernels[distro] = kernel_facts(distro, branches[distro] or built[distro], args.cache)

    parity = distro_parity({d: branches[d] or built[d] for d in DISTROS}, args.cache)
    context = {'parity': parity, 'pins': pins, 'constraints': constraints, 'profiles': profiles, 'branches': branches,
               'built': built, 'kernels': kernels}
    cells = []
    for machine in machines:
        for mode in MODES:
            swift = swift_machine(machine, mode, constraints)
            for distro in DISTROS:
                results = {d: run_dry(args.dry_run, swift, profiles[distro][d]['metadata'],
                                      profiles[distro][d]['digest_id'], profiles[distro][d]['archive'])
                           for d in DESKTOPS}
                checks = evaluate(machine, mode, distro, results, context)
                cells.append({'machine': machine['name'], 'device': machine['device_identifier'], 'mode': mode,
                              'distro': distro, 'verdict': verdict(checks), 'at_pin': verdict(checks, True),
                              'checks': checks})
    report = {'pins': pins, 'branches': branches, 'built': built,
              'images': {d: {k: {'payload': v['payload_name'], 'source': v['image_source']} for k, v in p.items()}
                         for d, p in profiles.items()},
              'cells': cells}
    if args.json:
        Path(args.json).write_text(json.dumps(report, indent=1, sort_keys=True, default=str))
    text = markdown(report)
    if args.markdown:
        Path(args.markdown).write_text(text)
    print(text)
    if not args.expect:
        return 1 if any(c['verdict'] == 'FAIL' for c in cells) else 0
    return compare_expected(cells, json.loads(Path(args.expect).read_text()))


RANK = {'PASS': 0, 'UNTESTED-ON-HW': 1, 'FAIL': 2}


def compare_expected(cells, expected):
    """Fail only on regressions against the recorded at-pin verdicts."""
    worse = []
    for cell in cells:
        key = '%s/%s/%s' % (cell['machine'], cell['mode'], cell['distro'])
        want = expected['cells'].get(key, {}).get('verdict', 'PASS')
        if RANK[cell['at_pin']] > RANK[want]:
            worse.append('%s: %s, expected %s' % (key, cell['at_pin'], want))
        elif RANK[cell['at_pin']] < RANK[want]:
            print('improved: %s: %s, was %s; update fixtures/expected.json' % (key, cell['at_pin'], want))
    for line in worse:
        print('REGRESSION ' + line, file=sys.stderr)
    return 1 if worse else 0


def payload_parts(model):
    """The files a payload is published as, each with the digest the catalog
    gives it. An unsplit payload is one file whose digest is payloadDigest."""
    artifact = model['payloadArtifact']
    return artifact.get('parts') or [{'sourceURL': artifact['sourceURL'], 'fileName': artifact['fileName'],
                                      'sizeBytes': artifact['sizeBytes'], 'sha256': model['payloadDigest']}]


def verify_parts(profile, parts, directory):
    """Stream each payload part once and record whether it matches the catalog."""
    Path(directory).mkdir(parents=True, exist_ok=True)
    for part in parts:
        out = Path(directory) / (part['fileName'] + '.result')
        if out.exists():
            continue
        digest, count = hashlib.sha256(), 0
        with urllib.request.urlopen(part['sourceURL'], timeout=300) as response:
            while True:
                block = response.read(1 << 20)
                if not block:
                    break
                digest.update(block)
                count += len(block)
        got = 'sha256:' + digest.hexdigest()
        out.write_text(json.dumps({'profile': profile, 'file': part['fileName'], 'bytes': count, 'sha256': got,
                                   'expected': part['sha256'], 'expected_bytes': part['sizeBytes'],
                                   'ok': got == part['sha256'] and count == part['sizeBytes']}))


def distro_sources_from(data):
    uboot = data.get('uboot-aurora') or data.get('uboot-asahi') or {}
    return {'aura': data.get('aura', {}).get('commit'), 'aura_version': data.get('aura', {}).get('version'),
            'u_boot': uboot.get('commit'), 'kernel': data.get('kernel-aurora', {}).get('commit'),
            'kernel_repository': data.get('kernel-aurora', {}).get('repository')}


def markdown(report):
    lines = ['Today: the installer with the signed catalogs it downloads now. At the pin: the same, once images',
             'built from the pinned branches are published (checks of today\'s images left out).', '',
             '| Machine | Mode | Fedora (today / at pin) | Arch (today / at pin) | NixOS (today / at pin) |',
             '| --- | --- | --- | --- | --- |']
    index = {(c['machine'], c['mode'], c['distro']): c for c in report['cells']}
    for machine in dict.fromkeys(c['machine'] for c in report['cells']):
        for mode in MODES:
            row = [machine, mode] + ['%s / %s' % (index[(machine, mode, d)]['verdict'], index[(machine, mode, d)]['at_pin'])
                                     for d in DISTROS]
            lines.append('| ' + ' | '.join(row) + ' |')
    lines.append('')
    for cell in report['cells']:
        lines.append('### %s, %s, %s: %s today, %s at the pin' % (
            cell['machine'], cell['mode'], cell['distro'], cell['verdict'], cell['at_pin']))
        for c in cell['checks']:
            mark = {True: 'ok', False: 'FAIL', None: 'untested'}[c['ok']]
            lines.append('- %s %s: %s%s' % (mark, c['check'], c['detail'],
                                           ' (hardware: %s)' % c['hardware'] if c['hardware'] else ''))
        lines.append('')
    return '\n'.join(lines) + '\n'


if __name__ == '__main__':
    sys.exit(main())
