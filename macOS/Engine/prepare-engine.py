#!/usr/bin/env python3
"""Produce the pinned engine from this checkout and an authenticated runtime base."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


REBUILD = load('engine_rebuild', ROOT / 'Engine/rebuild-python-overlay.py')
MODES = load('engine_modes', ROOT / 'Engine/verify-archive-modes.py')


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_file(path, size, digest):
    if (not path.is_file() or path.is_symlink() or path.stat().st_size != size
            or file_digest(path) != digest):
        raise ValueError('engine input size or digest mismatch: ' + str(path))


def download(url, destination, expected_size):
    if not url.startswith('https://'):
        raise ValueError('engine inputs require HTTPS')
    with urlopen(url, timeout=120) as source, destination.open('xb') as target:
        copied = 0
        while block := source.read(1024 * 1024):
            copied += len(block)
            if copied > expected_size:
                raise ValueError("engine runtime download exceeds its pinned size")
            target.write(block)


def cached_base(cache, identity, fetch=download):
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / identity['base_sha256']
    if target.exists() or target.is_symlink():
        try:
            verify_file(target, identity['base_size_bytes'], identity['base_sha256'])
            return target
        except ValueError:
            target.unlink()
    with tempfile.TemporaryDirectory(prefix='base-', dir=cache) as temporary:
        fresh = Path(temporary) / 'runtime.tar.gz'
        urls = [identity['base_url'], *identity.get('base_mirror_urls', [])]
        for index, url in enumerate(urls):
            try:
                fetch(url, fresh, identity['base_size_bytes'])
                verify_file(fresh, identity['base_size_bytes'], identity['base_sha256'])
                break
            except (OSError, ValueError):
                fresh.unlink(missing_ok=True)
                if index == len(urls) - 1:
                    raise
        try:
            os.link(fresh, target)
        except FileExistsError:
            verify_file(target, identity['base_size_bytes'], identity['base_sha256'])
    return target


def source_checkout(path, lock):
    upstream = lock['upstream_installer']
    path.mkdir()
    subprocess.run(['git', 'init', '-q', str(path)], check=True)
    subprocess.run(['git', '-C', str(path), 'remote', 'add', 'origin', upstream['repository']], check=True)
    commits = [upstream['commit'], lock['incremental_build']['upstream_delta']['base_commit']]
    subprocess.run(['git', '-C', str(path), 'fetch', '--no-tags', '--depth=1', 'origin', *commits], check=True)
    subprocess.run(['git', '-C', str(path), 'checkout', '--detach', upstream['commit']], check=True)
    subprocess.run(['git', '-C', str(path), 'submodule', 'update', '--init', '--recursive', '--depth=1'], check=True)
    return path


def reproduce(checkout, base, destination, identity, build=REBUILD.rebuild):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='engine-reproduce-', dir=destination.parent) as temporary:
        first, second = [Path(temporary) / name for name in ('first.tar.gz', 'second.tar.gz')]
        build(checkout, base, first)
        build(checkout, base, second)
        verify_file(first, identity['size_bytes'], identity['sha256'])
        verify_file(second, identity['size_bytes'], identity['sha256'])
        if first.read_bytes() != second.read_bytes():
            raise ValueError('independent engine repacks differ')
        if MODES.verify_archive(first) != 0:
            raise ValueError('engine archive modes failed verification')
        try:
            os.link(first, destination)
        except FileExistsError:
            verify_file(destination, identity['size_bytes'], identity['sha256'])
    return destination


def prepare(output, cache, checkout=None):
    engine = ROOT / 'Engine'
    lock = json.loads((engine / 'source-lock.json').read_text())
    # Packaging must agree with the source lock before using either an existing
    # archive or a newly reproduced one. The tracked helper must match source.
    subprocess.run(['python3', str(ROOT / 'Packaging/read-validation-engine.py')], check=True)
    REBUILD.VERIFY.require_restore_image(engine)
    records = (lock['downstream_overlay']['files'] + lock['build_recipe']
               + [lock['downstream_overlay']['patch'], lock['incremental_build']['base_patch']])
    for record in records:
        REBUILD.VERIFY.require_digest(engine, record, 'engine source input')
    identity = lock['validation_artifact']
    destination = output / identity['filename']
    if destination.exists() or destination.is_symlink():
        verify_file(destination, identity['size_bytes'], identity['sha256'])
        if MODES.verify_archive(destination) != 0:
            raise ValueError('engine archive modes failed verification')
        return destination
    base = cached_base(cache, lock['incremental_build'])
    REBUILD.require_base(base.read_bytes(), lock)
    with tempfile.TemporaryDirectory(prefix='engine-source-') as temporary:
        checkout = checkout or source_checkout(Path(temporary) / 'asahi-installer', lock)
        REBUILD.VERIFY.verify_upstream(engine, lock, checkout)
        return reproduce(checkout, base, destination, identity)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cache', type=Path, default=Path.home() / '.cache/omarchy-engine')
    parser.add_argument('--checkout', type=Path, help='optional existing clean locked Asahi checkout')
    args = parser.parse_args()
    try:
        print(prepare(args.output, args.cache, args.checkout))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
