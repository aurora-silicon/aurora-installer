#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check that an engine archive's native code is exactly the authenticated runtime's.

Apple's notary service inspects every Mach-O inside an app, archived ones
included, and rejects any that lacks a Developer ID signature, a secure
timestamp or the hardened runtime. The engine's only Mach-O files are the
Python runtime kept byte for byte from the authenticated .28 base, which was
signed that way (scripts/resign-engine.sh). runtime-macho.json pins each one
by path and SHA-256. Any other native code, such as a helper tool, belongs in
the app bundle, where the release signing reaches it.

Usage: verify-engine-macho.py [--signatures] ARCHIVE...

--signatures also asks codesign (macOS) that each one verifies strictly for
every architecture and, per architecture, carries a Developer ID Application
signature with a secure timestamp and the hardened runtime. The byte pins
stay: a signature check alone would admit any other Developer ID code.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

INVENTORY = Path(__file__).resolve().parent / 'runtime-macho.json'
# Thin (32/64-bit, either byte order) and universal (fat, fat64) headers.
MACHO_MAGIC = {
    b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
    b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca',
}


def is_macho(data):
    return data[:4] in MACHO_MAGIC


def inventory(path=INVENTORY):
    document = json.loads(Path(path).read_text())
    if set(document) != {'base_sha256', 'files'} or not document['files']:
        raise ValueError('invalid runtime Mach-O inventory')
    return document['files']


def archived_macho(archive):
    """{member name: (sha256, bytes)} for every regular Mach-O member of ARCHIVE."""
    found = {}
    with tarfile.open(archive, mode='r:*') as source:
        for member in source:
            if not member.isfile():
                continue
            data = source.extractfile(member).read()
            if is_macho(data):
                found[member.name.removeprefix('./')] = (hashlib.sha256(data).hexdigest(), data)
    return found


def run(*command):
    result = subprocess.run(command, capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def signature_findings(name, path):
    """What notarization would refuse in NAME, checked where it sits in the
    extracted engine (framework and app binaries bind their Info.plist): every
    architecture must verify strictly and carry a Developer ID Application
    signature, a secure timestamp and the hardened runtime."""
    findings = []
    status, output = run('codesign', '--verify', '--strict', '--all-architectures', str(path))
    if status != 0:
        findings.append(f'{name}: codesign --verify --strict --all-architectures fails: '
                        + ' '.join(output.replace(str(path), name).split())[:200])
    status, architectures = run('lipo', '-archs', str(path))
    architectures = architectures.split() if status == 0 else []
    if not architectures:
        findings.append(f'{name}: lipo cannot list its architectures')
    for architecture in architectures:
        status, details = run('codesign', '--display', '--verbose=4', '--arch', architecture, str(path))
        where = f'{name} ({architecture})'
        if status != 0 or 'Authority=Developer ID Application: ' not in details:
            findings.append(f'{where}: not signed with a Developer ID Application certificate')
        if 'Timestamp=' not in details:
            findings.append(f'{where}: signature has no secure timestamp')
        if not any(line.startswith('CodeDirectory ') and 'runtime' in line for line in details.splitlines()):
            findings.append(f'{where}: hardened runtime is not enabled')
    return findings


def extracted(archive, directory):
    """ARCHIVE unpacked into DIRECTORY the way the app unpacks it: by macOS
    tar, which turns AppleDouble members into the extended attributes the
    framework's resource seal covers. Members must stay inside DIRECTORY."""
    with tarfile.open(archive, mode='r:*') as source:
        for member in source:
            name = Path(member.name)
            if name.is_absolute() or '..' in name.parts or not (member.isfile() or member.isdir() or member.issym()):
                raise ValueError(f'unsafe archive member {member.name}')
    status, output = run('/usr/bin/tar', '-xzf', str(archive), '-C', str(directory), '--no-same-owner')
    if status != 0:
        raise ValueError('tar cannot unpack the engine: ' + output.strip()[:200])
    return Path(directory)


def verify(archive, pinned=None, signatures=False, complete=True):
    """Every finding for ARCHIVE; an empty list means it passes.

    COMPLETE also requires every pinned runtime file to be present, as for
    the engine's own producer; the app's release guard only refuses extras.
    """
    pinned = inventory() if pinned is None else pinned
    found = archived_macho(archive)
    findings = []
    signed = []
    for name, (digest, _) in sorted(found.items()):
        if name not in pinned:
            findings.append(f'{name}: a Mach-O that is not part of the authenticated runtime')
        elif pinned[name] != digest:
            findings.append(f'{name}: differs from the authenticated runtime')
        else:
            signed.append(name)
    for name in sorted(set(pinned) - set(found)) if complete else ():
        findings.append(f'{name}: the authenticated runtime file is missing')
    if signatures and signed:
        with tempfile.TemporaryDirectory(prefix='engine-macho.') as directory:
            root = extracted(archive, directory)
            for name in signed:
                findings.extend(signature_findings(name, root / name))
    return findings


def main(arguments):
    signatures = arguments[:1] == ['--signatures']
    archives = arguments[1:] if signatures else arguments
    if not archives or any(argument.startswith('-') for argument in archives):
        print(__doc__.strip().split('\n\n')[2], file=sys.stderr)
        return 64
    if signatures and not (shutil.which('codesign') and shutil.which('lipo')):
        print('verify-engine-macho: --signatures needs codesign and lipo (macOS)', file=sys.stderr)
        return 64
    status = 0
    for archive in archives:
        findings = verify(archive, signatures=signatures)
        for finding in findings:
            print(f'verify-engine-macho: {archive}: {finding}', file=sys.stderr)
        if findings:
            status = 1
        else:
            print(f'verify-engine-macho: {archive}: {len(inventory())} runtime Mach-O files, nothing else')
    return status


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
