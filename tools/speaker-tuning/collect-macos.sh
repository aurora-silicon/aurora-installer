#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Collect this Mac's speaker tuning on its own macOS, for an existing Aurora
# install. Uses only the system /usr/bin/python3 and this repository's
# asahi_firmware, read only. Writes a tarball to copy to Linux on the same
# Mac, where install-linux.sh adds it to the ESP firmware.
#
# Usage: tools/speaker-tuning/collect-macos.sh [-o OUTPUT.tar.gz] [--lsm2-fill-readback]
# Short lsm2 presets read their missing records from this Mac's running AU.
# --lsm2-fill-readback also records full presets for private dry-run checks.
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)

if [ "$(uname -s)" != Darwin ]; then
    echo "error: run this on the Mac's own macOS" >&2
    exit 1
fi
if [ ! -x /usr/bin/python3 ]; then
    echo "error: /usr/bin/python3 is missing (install the Command Line Tools: xcode-select --install)" >&2
    exit 1
fi

# -I: no user site, environment or current directory on sys.path.
# -B: no bytecode written into the repository.
exec /usr/bin/python3 -I -B "$here/speaker_tuning.py" collect "$@"
