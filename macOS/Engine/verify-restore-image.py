#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Verify that the Swift restore-image helper matches its recorded source build.

The app ships the helper in Contents/Helpers (Packaging/build-app.sh); the
engine archive does not carry it. The tracked unsigned build,
RestoreImage/bin/omarchy-restore-image, and any copy given as an argument
(the one in an unsigned app) must be the exact bytes build-record.json pins.
Signing changes those bytes, so a signed copy is identified by its code
signature instead (Packaging/release/sign-app).

Usage: verify-restore-image.py [UNSIGNED_COPY...]
"""
import hashlib
import json
from pathlib import Path
import sys

BINARY = 'RestoreImage/bin/omarchy-restore-image'


def record(engine: Path) -> dict:
    root = engine / 'RestoreImage'
    value = json.loads((root / 'build-record.json').read_text())
    if (value.get('schema') != 1
            or value.get('reference_repository') != 'https://github.com/erykwieliczko/macos-firmware-extract'
            or value.get('reference_commit') != '71b413af680edec1808a709cb7addfbde5c21cfc'
            or value.get('target') != 'arm64-apple-macosx14.0'
            or value.get('reproducibility') != 'two-identical-clean-builds-same-host-pinned-toolchain'
            or not value.get('swift') or not value.get('sdk')):
        raise ValueError('invalid Swift restore-image build identity')
    paths = [root / 'Package.swift', root / 'build.sh', *sorted((root / 'Sources').rglob('*.swift'))]
    expected = [{'path': str(p.relative_to(root)), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
                for p in paths]
    if value.get('sources') != expected:
        raise ValueError('Swift restore-image source differs from its build record')
    return value


def verify_binary(engine: Path, binary: Path) -> None:
    pinned = record(engine)
    if (binary.is_symlink() or not binary.is_file() or binary.stat().st_size != pinned.get('binary_size')
            or hashlib.sha256(binary.read_bytes()).hexdigest() != pinned.get('binary_sha256')):
        raise ValueError(f'{binary} differs from the Swift restore-image build')


def verify(engine: Path) -> None:
    verify_binary(engine, engine / BINARY)


if __name__ == '__main__':
    engine = Path(__file__).resolve().parent
    try:
        verify(engine)
        for argument in sys.argv[1:]:
            verify_binary(engine, Path(argument))
    except (OSError, ValueError) as error:
        raise SystemExit(f'verify-restore-image: {error}')
    print('Swift restore-image source and unsigned build identity verified')
