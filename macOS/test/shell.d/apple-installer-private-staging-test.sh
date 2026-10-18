#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
OMARCHY_STAGE_SOURCE_ONLY=1 source "$ROOT/Packaging/private-test/Stage assets.command"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077
printf 'fixture' > "$work/source"
digest=$(shasum -a 256 "$work/source"); digest=${digest%% *}
stage_one "$work/source" "$work/destination" 7 "$digest"
stage_one "$work/source" "$work/destination" 7 "$digest"
[[ $(cat "$work/destination") == "fixture" ]]
printf 'changed' > "$work/destination"
if stage_one "$work/source" "$work/destination" 7 "$digest"; then exit 1; fi
[[ $(cat "$work/destination") == "changed" ]]
rm "$work/destination"
ln -s "$work/source" "$work/destination"
if stage_one "$work/source" "$work/destination" 7 "$digest"; then exit 1; fi
mkdir -m700 "$work/parent"
ln -s "$work/parent" "$work/link"
if owned_directory "$work/link"; then exit 1; fi
chmod 777 "$work/parent"
if owned_directory "$work/parent"; then exit 1; fi
rm "$work/destination"
cp() { return 1; }
if stage_one "$work/source" "$work/destination" 7 "$digest"; then exit 1; fi
unset -f cp
[[ ! -e $work/destination ]]
[[ -z $(find "$work" -name '.pending-private.*' -print) ]]
echo 'PASS: verified reuse, tamper/symlink/permissions rejection and failed-copy cleanup'
