#!/bin/bash
set -euo pipefail
INSTALLER="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null || {
 echo 'Install Apple Command Line Tools with xcode-select --install, then run this again.' >&2
 exit 1
}
exec python3 "$INSTALLER/launcher.py" "$@"
