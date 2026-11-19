#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Add a speaker tuning bundle from collect-macos.sh to an existing Aurora
# install (Fedora, Arch Linux ARM, NixOS), without reinstalling.
#
# Usage:
#   tools/speaker-tuning/install-linux.sh [--dry-run] [--esp DIR] BUNDLE.tar.gz
#   tools/speaker-tuning/install-linux.sh --verify     (after the reboot)
#
# The bundle is re-verified against its manifest, the ESP's
# aurora/all_firmware.tar.gz and vendorfw/ are backed up to
# /var/lib/aurora-rollback/, vendorfw/ is rebuilt with this repository's
# aurora_firmware, the rebuild must keep every old file by path and hash, and
# both are swapped in. On any failure the old files stay in place.
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)

case "${1:-}" in
    -h|--help)
        exec sed -n '4,16s/^# \{0,1\}//p' "$0" ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

py=
for c in /usr/bin/python3 /run/current-system/sw/bin/python3; do
    if [ -x "$c" ]; then py=$c; break; fi
done
if [ -z "$py" ]; then
    py=$(command -v python3 || true)
fi
if [ -z "$py" ]; then
    if command -v nix >/dev/null 2>&1 && [ -z "${AURORA_TUNING_NIX_SHELL:-}" ]; then
        # NixOS without a system python3: run under a temporary one.
        export AURORA_TUNING_NIX_SHELL=1
        exec nix --extra-experimental-features 'nix-command flakes' \
            shell nixpkgs#python3 --command "$0" "$@"
    fi
    echo "error: python3 is required" >&2
    exit 1
fi

cmd=install
if [ "${1:-}" = --verify ]; then
    cmd=verify
    shift
fi

exec "$py" -I -B "$here/speaker_tuning.py" "$cmd" "$@"
