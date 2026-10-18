#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Verify that the bundled Swift helper matches its recorded source build."""
import hashlib
import json
from pathlib import Path


def verify(engine: Path) -> None:
    root = engine / 'RestoreImage'
    record = json.loads((root / 'build-record.json').read_text())
    if (record.get('schema') != 1
            or record.get('reference_repository') != 'https://github.com/erykwieliczko/macos-firmware-extract'
            or record.get('reference_commit') != '71b413af680edec1808a709cb7addfbde5c21cfc'
            or record.get('target') != 'arm64-apple-macosx14.0'
            or record.get('reproducibility') != 'two-identical-clean-builds-same-host-pinned-toolchain'
            or not record.get('swift') or not record.get('sdk')):
        raise ValueError('invalid Swift restore-image build identity')
    paths = [root / 'Package.swift', root / 'build.sh', *sorted((root / 'Sources').rglob('*.swift'))]
    expected = [{'path': str(p.relative_to(root)), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
                for p in paths]
    if record.get('sources') != expected:
        raise ValueError('Swift restore-image source differs from its build record')
    if (engine / 'overlay/bin/omarchy-restore-image.LICENSE').read_bytes() != (root / 'LICENSE').read_bytes():
        raise ValueError('bundled restore-image license differs from its source notice')
    binary = engine / 'overlay/bin/omarchy-restore-image'
    if (binary.stat().st_size != record.get('binary_size')
            or hashlib.sha256(binary.read_bytes()).hexdigest() != record.get('binary_sha256')):
        raise ValueError('bundled restore-image differs from its Swift build')


if __name__ == '__main__':
    verify(Path(__file__).resolve().parent)
    print('Bundled Swift restore-image source and build identity verified')
