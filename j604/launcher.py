#!/usr/bin/env python3
"""Authenticate, prepare the pinned private J604 kit, and run its macOS installer."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import time
import zipfile

ROOT = Path(__file__).resolve().parent


def run(*command, **kwargs):
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def output(*command):
    return subprocess.check_output(list(map(str, command)), text=True).strip()


def sha256(path):
    with path.open('rb') as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            digest.update(block)
        return digest.hexdigest()


def ensure_python(lock, root=ROOT):
    if sys.version_info >= (3, 11):
        os.environ['PATH'] = str(Path(sys.executable).parent) + os.pathsep + os.environ['PATH']
        return
    asset = lock['python']
    archive = root / '.cache/python-runtime.tar.gz'
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.is_file() or sha256(archive) != asset['sha256']:
        partial = archive.with_suffix('.gz.part')
        print('Preparing the pinned macOS Python runtime...', flush=True)
        run('curl', '--fail', '--location', '--retry', '4', '--retry-all-errors',
            '--proto', '=https', '--proto-redir', '=https', '--output', partial, asset['url'])
        if sha256(partial) != asset['sha256']:
            partial.unlink(missing_ok=True)
            raise ValueError('Python runtime download checksum mismatch')
        partial.replace(archive)
    runtime = root / '.tools/runtime'
    runtime.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as package:
        for member in package.getmembers():
            path = Path(member.name)
            if path.is_absolute() or '..' in path.parts or path.parts[0] != 'python':
                raise ValueError('unexpected pinned Python archive path')
    # macOS bsdtar preserves the verified runtime's relative symlinks.
    run('tar', '-xzf', archive, '-C', runtime)
    python = runtime / 'python/bin/python3'
    os.execv(str(python), [str(python), str(root / 'launcher.py'), *sys.argv[1:]])


def verify_inputs(root=ROOT):
    lock = json.loads((root / 'installer.lock.json').read_text())
    for field in ('revision', 'tree'):
        if not re.fullmatch('[0-9a-f]{40}', lock['kit'][field]):
            raise ValueError(f'invalid pinned kit {field}')
    if lock['kit']['repository'] != 'shirty445/j604-remix':
        raise ValueError('unexpected private hardware kit repository')
    asset = lock['github_cli']
    if not asset['url'].startswith('https://github.com/cli/cli/releases/download/') or not re.fullmatch(
            '[0-9a-f]{64}', asset['sha256']):
        raise ValueError('GitHub CLI must use a pinned official release')
    asset = lock['python']
    if not asset['url'].startswith('https://github.com/astral-sh/python-build-standalone/releases/download/') or not re.fullmatch(
            '[0-9a-f]{64}', asset['sha256']):
        raise ValueError('Python must use a pinned official standalone release')
    return lock


def github_cli(lock, root=ROOT):
    existing = shutil.which('gh')
    if existing:
        return Path(existing)
    tool = root / '.tools/gh/bin/gh'
    archive = root / '.cache/github-cli.zip'
    asset = lock['github_cli']
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.is_file() or sha256(archive) != asset['sha256']:
        partial = archive.with_suffix('.zip.part')
        print('Downloading the pinned GitHub CLI...', flush=True)
        run('curl', '--fail', '--location', '--retry', '4', '--retry-all-errors',
            '--proto', '=https', '--proto-redir', '=https', '--output', partial, asset['url'])
        if sha256(partial) != asset['sha256']:
            partial.unlink(missing_ok=True)
            raise ValueError('GitHub CLI download checksum mismatch')
        partial.replace(archive)
    # Only extract the executable; no archive paths are written to the filesystem.
    with zipfile.ZipFile(archive) as package:
        binaries = [n for n in package.namelist() if Path(n).parts[-2:] == ('bin', 'gh')]
        if len(binaries) != 1:
            raise ValueError('unexpected GitHub CLI archive layout')
        tool.parent.mkdir(parents=True, exist_ok=True)
        with package.open(binaries[0]) as src, tool.open('wb') as dst:
            shutil.copyfileobj(src, dst)
    tool.chmod(0o755)
    return tool


def authenticate(gh):
    status = subprocess.run([str(gh), 'auth', 'status', '--hostname', 'github.com'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if status.returncode:
        print('Sign in to a GitHub account with access to shirty445/j604-remix.', flush=True)
        run(gh, 'auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--web')
    # Check private access before creating a VM or starting a build. No token is printed.
    run(gh, 'api', 'repos/shirty445/j604-remix', '--silent')


def kit_path(lock, root=ROOT):
    return root / '.cache' / ('j604-kit-' + lock['kit']['revision'][:12])


def builder_name(kit):
    return 'j604-' + hashlib.sha256(str(kit).encode()).hexdigest()[:12]


def owns_builder(instance, kit):
    mounts = instance.get('config', {}).get('mounts', [])
    return (instance.get('name') == builder_name(kit) and len(mounts) == 1
            and Path(mounts[0].get('location', '')).resolve() == kit.resolve())


def reset_build_state(lock, root=ROOT):
    kit = kit_path(lock, root)
    if not kit.exists():
        return
    if (root / '.cache').is_symlink() or kit.is_symlink() or kit.resolve().parent != (root / '.cache').resolve():
        raise ValueError('refusing to reset a checkout outside the installer cache')
    # Preserve edits even in a generated checkout: --fresh clears build state,
    # not user-authored work.
    if output('git', '-C', kit, 'status', '--porcelain', '--untracked-files=normal'):
        raise ValueError('cached private kit has local edits; preserve them before using --fresh')
    head = subprocess.run(['git', '-C', str(kit), 'rev-parse', '--verify', 'HEAD'],
                          capture_output=True, text=True)
    if head.returncode == 0 and head.stdout.strip() != lock['kit']['revision']:
        raise ValueError('cached checkout contains another revision; it will not be deleted')
    lima = shutil.which('limactl')
    local = kit / '.tools/lima/bin/limactl'
    if not lima and local.is_file():
        lima = str(local)
    name = builder_name(kit)
    if lima:
        raw = output(lima, 'list', '--json', name)
        if raw:
            instance = json.loads(raw)
            if not owns_builder(instance, kit):
                raise ValueError('the build VM belongs to another checkout; it will not be deleted')
            if instance['status'] == 'Running':
                run(lima, 'stop', '--tty=false', name)
            run(lima, 'delete', '--tty=false', name)
    elif (Path(os.environ.get('LIMA_HOME', str(Path.home() / '.lima'))) / name).exists():
        raise ValueError('Lima is missing while its VM remains; restore Lima before resetting the build')
    shutil.rmtree(kit)
    print('Cleared this installer’s private checkout, build outputs and disposable VM.', flush=True)


def prepare_kit(lock, gh, root=ROOT):
    pin = lock['kit']
    destination = kit_path(lock, root)
    helper = '!' + shlex.quote(str(gh)) + ' auth git-credential'
    git = ['git', '-c', 'credential.helper=',
           '-c', 'credential.https://github.com.helper=' + helper,
           '-c', 'http.version=HTTP/1.1']
    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        run(*git, 'init', '-q', destination)
        run(*git, '-C', destination, 'remote', 'add', 'origin',
            'https://github.com/' + pin['repository'] + '.git')
    has_head = subprocess.run(git + ['-C', str(destination), 'rev-parse', '--verify', 'HEAD'],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if has_head:
        if output(*git, '-C', destination, 'rev-parse', 'HEAD') != pin['revision']:
            raise ValueError('cached private kit is at a different revision; keep it and use a fresh installer folder')
        if subprocess.run(git + ['-C', str(destination), 'diff', '--quiet', 'HEAD', '--']).returncode:
            raise ValueError('cached private kit has local edits; preserve those before retrying')
    else:
        for attempt in range(4):
            result = subprocess.run(git + ['-C', str(destination), 'fetch', '--depth=1', '--no-tags',
                                           'origin', pin['revision']])
            if result.returncode == 0:
                break
            if attempt == 3:
                result.check_returncode()
            time.sleep(2 ** attempt)
        run(*git, '-C', destination, 'checkout', '--detach', pin['revision'])
    if output(*git, '-C', destination, 'rev-parse', 'HEAD^{tree}') != pin['tree']:
        raise ValueError('private hardware kit does not match the pinned source tree')
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--desktop', choices=('gnome', 'kde'), default='gnome')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--build-only', action='store_true')
    mode.add_argument('--install-only', action='store_true')
    parser.add_argument('--no-apps', action='store_true')
    parser.add_argument('--fresh', action='store_true',
                        help='remove only this installer’s build VM and cached private checkout before rebuilding')
    parser.add_argument('--check', action='store_true', help='check this installer bundle without authentication or a build')
    args = parser.parse_args()
    if args.fresh and args.install_only:
        parser.error('--fresh and --install-only cannot be combined')
    lock = verify_inputs()
    if args.check:
        print('Installer commit, source-tree and tool pins verified. No authentication, build or disk changes.')
        return
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('run from a native Apple Silicon macOS terminal')
    if os.geteuid() == 0:
        parser.error('run as your normal macOS user; the disk installer requests sudo later')
    if output('sysctl', '-n', 'hw.model') != 'Mac16,1':
        parser.error('this installer supports only J604 / Mac16,1')
    if subprocess.run(['xcode-select', '-p'], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL).returncode:
        parser.error('install Apple Command Line Tools with xcode-select --install and retry')
    ensure_python(lock)
    gh = github_cli(lock)
    authenticate(gh)
    if args.fresh:
        reset_build_state(lock)
    kit = prepare_kit(lock, gh)
    os.environ['J604_LIMA_INSTANCE'] = builder_name(kit)
    command = ['bash', str(kit / 'install.sh'), '--desktop', args.desktop]
    if args.build_only:
        command.append('--build-only')
    if args.install_only:
        command.append('--install-only')
    if args.no_apps:
        command.append('--no-apps')
    print('Preparing Fedora and the patched J604 kernel, Aura and U-Boot. This can take a while.', flush=True)
    run(*command)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f'Installer stopped: {error}\nCorrect the reported problem and rerun the same command; completed downloads/builds are retained.',
              file=sys.stderr)
        sys.exit(1)
