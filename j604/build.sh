#!/bin/bash
# Package the standalone installer. No GitHub credentials or private sources included.
set -euo pipefail
INSTALLER="$(cd "$(dirname "$0")" && pwd)"
python3 "$INSTALLER/launcher.py" --check
python3 -m unittest discover -s "$INSTALLER/tests"
mkdir -p "$INSTALLER/dist/j604-installer"
for asset in install.sh build.sh launcher.py installer.lock.json README.md; do
 cp "$INSTALLER/$asset" "$INSTALLER/dist/j604-installer/$asset"
done
mkdir -p "$INSTALLER/dist/j604-installer/tests"
for test in "$INSTALLER"/tests/test_*.py; do
 cp "$test" "$INSTALLER/dist/j604-installer/tests/"
done
python3 - "$INSTALLER/dist" <<'PY'
from pathlib import Path
import sys
from zipfile import ZipFile, ZIP_DEFLATED
dist = Path(sys.argv[1])
with ZipFile(dist / 'j604-installer.zip', 'w', compression=ZIP_DEFLATED) as archive:
 for path in sorted((dist / 'j604-installer').rglob('*')):
  if path.is_file() and not any(p in ('__pycache__', '.cache', '.tools', 'dist')
                               for p in path.relative_to(dist / 'j604-installer').parts):
   if path.name != 'integration.patch':
    archive.write(path, path.relative_to(dist))
PY
echo "Built $INSTALLER/dist/j604-installer"
echo "Run: bash \"$INSTALLER/dist/j604-installer/install.sh\""
