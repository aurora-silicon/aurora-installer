#!/bin/bash
# Exercise the real postinstall with disposable paths and inert system commands.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$root/Packaging/identity.conf"
export INSTALLER_APP_NAME INSTALLER_APP_IDENTIFIER INSTALLER_HELPER_IDENTIFIER
python3 - "$root" <<'PY'
from pathlib import Path
import os
import subprocess
import sys
import tempfile
root = Path(sys.argv[1])
app_name, helper_id = os.environ['INSTALLER_APP_NAME'], os.environ['INSTALLER_HELPER_IDENTIFIER']
with tempfile.TemporaryDirectory() as work:
    work = Path(work)
    subprocess.run(['bash', str(root / 'Packaging/private-test/render-identity.sh'), str(root / 'Packaging/private-test/scripts/postinstall'), str(work / 'rendered')], check=True)
    source = (work / 'rendered').read_text()
    assert '@APP_NAME@' not in source and '@APP_IDENTIFIER@' not in source and '@HELPER_IDENTIFIER@' not in source
    source = source.replace('(( EUID == 0 )) || exit 1', '# Unprivileged fixture only')
    source = source.replace('/Library', str(work / 'Library')).replace('/Applications', str(work / 'Applications'))
    helper = work / 'Library/PrivilegedHelperTools' / helper_id
    plist = work / 'Library/LaunchDaemons' / f'{helper_id}.plist'
    app = work / 'Applications' / f'{app_name}.app'
    for path in (helper.parent, plist.parent, app):
        path.mkdir(parents=True, exist_ok=True)
    helper.write_text('fixture helper')
    plist.write_text('fixture plist')
    stub = work / 'system-stub.py'
    stub.write_text('''#!/usr/bin/python3
import os, sys
kind, *args = sys.argv[1:]
case = os.environ['TEST_CASE']
if kind == 'stat':
    print(('1000' if case == 'owner' else '0') if args[1] == '%u' else ('777' if case == 'mode' else '755'))
elif kind == 'codesign':
    sys.exit(1 if case == 'signature' else 0)
elif kind == 'shasum':
    print(('wrong' if case == 'plist-hash' else '@PLIST_SHA256@') + '  plist')
elif kind == 'plutil':
    key = args[1]
    values = {'Program': os.environ['TEST_HELPER'], 'EnvironmentVariables.OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT': 'identifier "%s" and cdhash H"@APP_HASH@"' % os.environ['INSTALLER_APP_IDENTIFIER'], 'Label': os.environ['INSTALLER_HELPER_IDENTIFIER'], 'UserName': 'root'}
    print('wrong' if case == key else values[key])
elif kind == 'launchctl':
    with open(os.environ['TEST_TRACE'], 'a') as out:
        out.write(' '.join(args) + '\\n')
    sys.exit(1 if case == 'bootstrap' and args[0] == 'bootstrap' else 0)
''')
    for command in ('stat', 'codesign', 'plutil', 'launchctl', 'shasum'):
        original = ('/bin/' if command == 'launchctl' else '/usr/bin/') + command
        source = source.replace(original, f'python3 "{stub}" {command}')
    script = work / 'postinstall'
    script.write_text(source)
    trace = work / 'trace'
    for case in ('ok', 'owner', 'mode', 'signature', 'plist-hash', 'Program', 'EnvironmentVariables.OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT', 'Label', 'UserName', 'bootstrap', 'symlink'):
        trace.write_text('')
        if case == 'symlink':
            helper.unlink()
            helper.symlink_to(plist)
        result = subprocess.run(['bash', str(script)], env=dict(os.environ, TEST_CASE=case, TEST_HELPER=str(helper), TEST_TRACE=str(trace)), capture_output=True, text=True)
        assert (result.returncode == 0) == (case == 'ok'), (case, result.stderr)
        events = trace.read_text().splitlines()
        if case == 'ok':
            assert len(events) == 2 and events[0].startswith('bootstrap') and events[1].startswith('print')
        elif case == 'bootstrap':
            assert len(events) == 1 and events[0].startswith('bootstrap')
        else:
            assert not events, (case, events)
print('PASS: invalid owner/mode/signature/plist/symlink never reaches bootstrap; registration failure propagates')
PY
