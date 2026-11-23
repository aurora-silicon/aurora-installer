#!/bin/bash
# Fresh whole-disk installation, proven on disk images without a Mac:
# the Recovery planner's checks, then the planner and the disk stage
# (aurora-fresh-install built for tests) replayed on the J473's factory table.
#   fresh-test.sh OUT [GPT]   (GPT: j473, the default, or a file with LBA 1-5)
# Needs docker (swift:6.2), python3, sfdisk and mkfs.vfat. OUT holds the
# binaries and the sparse images (251 GB apparent each, a few MB used).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
rec=$here/../../macOS/Recovery
out=$(mkdir -p "$1" && cd "$1" && pwd)
gpt=${2:-j473}
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$rec":/src:ro -v "$out":/out -w /src swift:6.2 bash -c '
set -e
s="Sources/MacOSRemoval.swift Sources/FreshWholeDisk.swift"
swiftc $s Tests/FreshWholeDiskCheck.swift -o /out/fresh-check && /out/fresh-check
swiftc $s Tests/MacOSRemovalCheck.swift -o /out/removal-check && /out/removal-check
swiftc -O -parse-as-library -static-stdlib $s Tools/FreshWholeDiskTool.swift -o /out/fresh-whole-disk-tool
swiftc -O -parse-as-library -static-stdlib -D FRESH_WHOLE_DISK_TEST $s Sources/FreshWholeDiskInstall.swift Tools/FreshWholeDiskInstallTool.swift -o /out/aurora-fresh-install-test'
python3 -I "$here/fresh-image-test.py" "$out/fresh-whole-disk-tool" "$gpt" "$out/img"
python3 -I "$here/fresh-install-test.py" "$out/aurora-fresh-install-test" "$gpt" "$out/inst"
rm -rf "$out/img" "$out/inst"
