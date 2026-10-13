#!/bin/bash
# Exercise profile admission with fixture plists; no signing or registration.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$root" <<'PYTEST'
from pathlib import Path
import os
import plistlib
import subprocess
import sys
import tempfile
source = (Path(sys.argv[1]) / 'Packaging/private-test/code-identity.sh').read_text()
with tempfile.TemporaryDirectory() as work:
    work = Path(work)
    app = work / 'app'
    release = app / 'Contents/Resources/Release'
    release.mkdir(parents=True)
    stub = work / 'plutil.py'
    stub.write_text('import plistlib,sys\nd=plistlib.load(open(sys.argv[-1],"rb")); v=d.get(sys.argv[2]); print(str(v).lower() if isinstance(v,bool) else "")\n')
    helper = work / 'profile.sh'
    helper.write_text(source.replace('/usr/bin/plutil', f'python3 "{stub}"') + '\nprivate_bundle_profile "$1"\n')
    def check(flags, expected):
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(flags))
        result = subprocess.run(['bash', str(helper), str(app)], capture_output=True, text=True)
        assert (result.returncode == 0) == (expected is not None), (flags, result.stderr)
        if expected is not None:
            assert result.stdout.strip() == expected
    check({}, None)
    check({'OmarchyPrivatePlainTest': True}, 'plain')
    check({'OmarchyPrivateLimineTest': True}, None)
    (release / 'catalog.json').write_text('{}')
    check({'OmarchyPrivateLimineTest': True}, None)
    (release / 'catalog.json.sig').write_bytes(b'x' * 64)
    check({'OmarchyPrivateLimineTest': True}, 'limine')
    check({'OmarchyPrivatePlainTest': True, 'OmarchyPrivateLimineTest': True}, None)
    (release / 'catalog.json.sig').unlink()
    (release / 'catalog.json.sig').symlink_to(release / 'catalog.json')
    check({'OmarchyPrivateLimineTest': True}, None)
print('PASS: separate plain/Limine package admission, conflicting flags and absent/unsafe sealed catalog rejection')
PYTEST
