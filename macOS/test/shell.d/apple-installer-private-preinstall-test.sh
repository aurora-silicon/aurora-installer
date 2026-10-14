#!/bin/bash
# Exercise the packaged guard with fixture hardware and installation paths.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$root/Packaging/identity.conf"
export INSTALLER_APP_NAME INSTALLER_LEGACY_APP_NAME INSTALLER_APP_IDENTIFIER INSTALLER_HELPER_IDENTIFIER
python3 - "$root" <<'PY'
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
app_name, legacy_name, app_id, helper_id = (os.environ[name] for name in ('INSTALLER_APP_NAME', 'INSTALLER_LEGACY_APP_NAME', 'INSTALLER_APP_IDENTIFIER', 'INSTALLER_HELPER_IDENTIFIER'))
with tempfile.TemporaryDirectory() as work:
    work = Path(work)
    subprocess.run(['bash', str(root / 'Packaging/private-test/render-identity.sh'), str(root / 'Packaging/private-test/scripts/preinstall'), str(work / 'rendered')], check=True)
    source = (work / 'rendered').read_text()
    assert '@APP_' not in source and '@LEGACY_' not in source and '@HELPER_' not in source
    # The read-only preflight refuses the same installer state, the pre-rename app included.
    subprocess.run(['bash', str(root / 'Packaging/private-test/render-identity.sh'), str(root / 'Packaging/private-test/Preflight.command'), str(work / 'preflight')], check=True)
    preflight = (work / 'preflight').read_text()
    assert '@LEGACY_' not in preflight and f'/Applications/{legacy_name}.app' in preflight
    paths = [work / name for name in ('app', 'legacy', 'daemon', 'helper', 'state')]
    for original, fixture in zip((f'/Applications/{app_name}.app', f'/Applications/{legacy_name}.app', f'/Library/LaunchDaemons/{helper_id}.plist', f'/Library/PrivilegedHelperTools/{helper_id}', f'/var/db/{app_id}'), paths):
        assert original in source, original
        source = source.replace(original, str(fixture))
    source = source.replace('/Library/PrivilegedHelperTools', str(work / 'privileged'))
    source = source.replace('/usr/sbin/sysctl -n hw.targettype', 'printf "%s\\n" "$TEST_BOARD"')
    source = source.replace('/usr/bin/sw_vers -productVersion', 'printf "%s\\n" "$TEST_MACOS"')
    assert f'/bin/launchctl print "system/{helper_id}"' in source
    source = source.replace(f'/bin/launchctl print "system/{helper_id}"', 'test "$TEST_LOADED" = 1')
    script = work / 'preinstall'
    script.write_text(source)

    def check(board, accepted, volume='/', macos='26.6.2', loaded='0'):
        result = subprocess.run(['bash', str(script), 'fixture.pkg', '/', volume], env=dict(os.environ, TEST_BOARD=board, TEST_MACOS=macos, TEST_LOADED=loaded), capture_output=True, text=True)
        assert (result.returncode == 0) == accepted, (board, volume, result.stderr)

    for board in ('j433', 'j434', 'j504', 'j613', 'j615', 'j514s', 'j514c', 'j514m', 'j516s', 'j516c', 'j516m'):
        check(board, True)
        check(board.upper() + 'AP', True)
    for board in ('j614s', 'j616s', 'j604', 'j773g', 'j313', 'j575d', 'unknown', ''):
        check(board, False)
        check(board + 'AP', False)
    check('j516s', False, '/Volumes/Other')
    check('j516s', False, macos='14.8.3')
    check('j516s', False, macos='invalid')
    check('j516s', True, macos='15.0')
    check('j516s', False, loaded='1')
    privileged = work / 'privileged'
    privileged.symlink_to(work / 'missing')
    check('j516s', False)
    privileged.unlink()
    for path in paths:
        path.write_text('preserve me')
        check('j516s', False)
        assert path.read_text() == 'preserve me'
        path.unlink()
        path.symlink_to(work / 'missing')
        check('j516s', False)
        assert path.is_symlink()
        path.unlink()
print('PASS: all 11 M3 boards, AP normalization, other hardware/volume rejection and existing-state preservation, pre-rename app included')
PY
