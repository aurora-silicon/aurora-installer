#!/usr/bin/env python3
"""Trace every installed package to a pinned repository database and its bytes.

For each package in ROOT's local database, finds the repositories (in pacman's
order) whose database lists that name and version, and the archive in the
build's cache (or the candidate repository) whose sha256 is the one such a
database records. Candidates must come from the candidate repository with the
set's own bytes. Prints name|version|repository|filename|sha256 lines and fails
on any package it cannot trace.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def fail(message):
    print(f"package_record: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def desc_fields(text):
    fields, key = {}, None
    for line in text.splitlines():
        if line.startswith('%') and line.endswith('%'):
            key = line.strip('%')
            fields[key] = []
        elif line and key:
            fields[key].append(line)
    return fields


def sync_entries(database):
    """(name, version) -> (filename, sha256) for every package DATABASE lists."""
    entries = {}
    with tempfile.TemporaryDirectory() as scratch:
        subprocess.run(['bsdtar', '-xf', str(database), '-C', scratch], check=True)
        for desc in Path(scratch).glob('*/desc'):
            fields = desc_fields(desc.read_text())
            if all(fields.get(key) for key in ('NAME', 'VERSION', 'FILENAME', 'SHA256SUM')):
                entries[(fields['NAME'][0], fields['VERSION'][0])] = (fields['FILENAME'][0], fields['SHA256SUM'][0])
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--repositories', type=Path, required=True)
    parser.add_argument('--order', required=True)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--candidates', type=Path, required=True)
    args = parser.parse_args()

    order = args.order.split(',')
    databases = {name: sync_entries(args.repositories / name / f'{name}.db') for name in order}
    candidates = {p['name']: p for p in json.loads(args.candidates.read_text())['packages']}
    digests = {}

    def digest_of(path):
        if path not in digests:
            digests[path] = sha256(path) if path.is_file() else None
        return digests[path]

    lines = []
    for desc in sorted((args.root / 'var/lib/pacman/local').glob('*/desc')):
        fields = desc_fields(desc.read_text())
        name, version = fields['NAME'][0], fields['VERSION'][0]
        found = None
        for repository in order:
            listed = databases[repository].get((name, version))
            if listed is None:
                continue
            filename, expected = listed
            places = [args.repositories / repository / filename] if repository == 'omarchy-candidates' \
                else [args.cache / filename]
            if any(digest_of(place) == expected for place in places):
                found = (repository, filename, expected)
                break
        if found is None:
            fail(f'{name} {version} does not trace to a pinned database and archive')
        if name in candidates:
            candidate = candidates[name]
            if found != ('omarchy-candidates', candidate['filename'], candidate['sha256']) \
                    or version != candidate['version']:
                fail(f'{name} {version} is not the candidate set\'s archive')
        lines.append(f'{name}|{version}|{found[0]}|{found[1]}|{found[2]}')
    missing = sorted(set(candidates) - {line.split('|', 1)[0] for line in lines})
    if missing:
        fail('candidate packages are not installed: ' + ', '.join(missing))
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
