#!/bin/bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
icon="$ROOT/Packaging/AuroraInstaller.icns"
[[ -f $icon && ! -L $icon ]] || fail "Aurora icon is a regular file"
python3 - "$icon" "$ROOT/Packaging/Info.plist" <<'PYTEST'
import plistlib, struct, sys
from pathlib import Path
icon = Path(sys.argv[1]).read_bytes()
assert icon[:4] == b"icns" and struct.unpack(">I", icon[4:8])[0] == len(icon)
assert plistlib.loads(Path(sys.argv[2]).read_bytes())["CFBundleIconFile"] == "AuroraInstaller"
PYTEST
[[ -s "$ROOT/Resources/AuroraLogo.png" ]] || fail "Aurora mark is bundled"
grep -Fq '"$script_directory/AuroraInstaller.icns"' "$ROOT/Packaging/build-app.sh" || fail "packaging selects Aurora's icon"
pass "native installer binds the Aurora mark and application icon"
