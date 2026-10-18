#!/bin/bash
set -euo pipefail

if (( $# != 1 )) || [[ $(uname -s) != "Darwin" || $(uname -m) != "arm64" ]]; then
  echo "Usage (Apple Silicon macOS): build.sh OUTPUT_DIRECTORY" >&2
  exit 1
fi
package=$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)
# The bundled executable is reproduced in CI. Refuse a different compiler/SDK
# before building rather than pinning bytes no other producer can reproduce.
python3 - "$package/build-record.json" <<'PYTOOLS'
import json
import subprocess
import sys
from pathlib import Path
record = json.loads(Path(sys.argv[1]).read_text())
swift = subprocess.check_output(['xcrun', 'swift', '--version'], text=True).strip()
sdk = subprocess.check_output(['xcrun', '--show-sdk-version'], text=True).strip()
if (swift.splitlines()[0] != record['swift'].splitlines()[0]
        or sdk != record['sdk']):
    raise SystemExit('RestoreImage toolchain differs from build-record.json; '
                     'select the recorded Swift compiler and SDK with DEVELOPER_DIR')
print(swift.splitlines()[0] + '; SDK ' + sdk)
PYTOOLS
mkdir -p "$1"
output=$(cd "$1" && pwd -P)
jobs=${OMARCHY_BUILD_JOBS:-10}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo "Invalid OMARCHY_BUILD_JOBS" >&2; exit 1; }
stage=$(mktemp -d "$output/.restore-image-build.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
export ZERO_AR_DATE=1
for variant in first second; do
  xcrun swift build --build-system native --package-path "$package" --scratch-path "$stage/$variant" \
    --configuration release --jobs "$jobs" --triple arm64-apple-macosx14.0 \
    -Xswiftc -file-prefix-map -Xswiftc "$package=/Sources/RestoreImage" \
    -Xswiftc -gnone -Xswiftc -Xfrontend -Xswiftc -no-serialize-debugging-options \
    -Xlinker -oso_prefix -Xlinker "$stage/$variant/"
  binary_directory=$(xcrun swift build --build-system native --package-path "$package" \
    --scratch-path "$stage/$variant" --configuration release \
    --triple arm64-apple-macosx14.0 --show-bin-path)
  cp "$binary_directory/omarchy-restore-image" "$stage/$variant.bin"
done
if ! cmp "$stage/first.bin" "$stage/second.bin"; then
  cp "$stage/first.bin" "$output/first-unqualified.bin"
  cp "$stage/second.bin" "$output/second-unqualified.bin"
  otool -l "$stage/first.bin" > "$output/first-load-commands.txt"
  otool -l "$stage/second.bin" > "$output/second-load-commands.txt"
  echo "Release builds differ; both candidates retained for diagnosis" >&2
  exit 1
fi
cp "$stage/first.bin" "$output/omarchy-restore-image"
chmod 755 "$output/omarchy-restore-image"
"$output/omarchy-restore-image" capabilities
python3 - "$package" "$output" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys
root, output = map(Path, sys.argv[1:])
paths = [root / 'Package.swift', root / 'build.sh', *sorted((root / 'Sources').rglob('*.swift'))]
binary = output / 'omarchy-restore-image'
record = {
    'schema': 1,
    'reference_repository': 'https://github.com/erykwieliczko/macos-firmware-extract',
    'reference_commit': '71b413af680edec1808a709cb7addfbde5c21cfc',
    'swift': subprocess.check_output(['xcrun', 'swift', '--version'], text=True).strip(),
    'sdk': subprocess.check_output(['xcrun', '--show-sdk-version'], text=True).strip(),
    'target': 'arm64-apple-macosx14.0',
    'reproducibility': 'two-identical-clean-builds-same-host-pinned-toolchain',
    'sources': [{'path': str(p.relative_to(root)), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in paths],
    'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
    'binary_size': binary.stat().st_size,
}
(output / 'restore-image-build.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps({'sha256': record['binary_sha256'], 'size': record['binary_size']}))
PY
