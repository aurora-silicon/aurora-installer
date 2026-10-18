#!/bin/bash
# Read-only integrity/model check; no app/helper installation or partition changes.
set -euo pipefail
[[ $(uname -s) == "Darwin" ]] || { echo 'Run this preflight on the target Mac.' >&2; exit 64; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd "$root"
/usr/bin/shasum -a 256 -c SHA256SUMS
version=$(/usr/bin/sw_vers -productVersion)
major=${version%%.*}
[[ $major =~ ^[0-9]+$ ]] && (( major >= 15 )) || { echo 'macOS 15 or later is required.' >&2; exit 1; }
target=$(/usr/sbin/sysctl -n hw.targettype | /usr/bin/tr '[:upper:]' '[:lower:]')
target=${target%ap}
case "$target" in
  j433|j434|j504|j613|j615|j514s|j514c|j514m|j516s|j516c|j516m) ;;
  *) echo "Unsupported private-test hardware: $target. Stop here." >&2; exit 1 ;;
esac
for path in "/Applications/@APP_NAME@.app" "/Applications/@LEGACY_APP_NAME@.app" "/Library/LaunchDaemons/@HELPER_IDENTIFIER@.plist" "/Library/PrivilegedHelperTools/@HELPER_IDENTIFIER@" "/var/db/@APP_IDENTIFIER@"; do
  if [[ -e $path || -L $path ]]; then
    echo "Existing installer state needs review: $path" >&2; exit 1
  fi
done
printf '\nMac model: '
/usr/sbin/sysctl -n hw.model
printf 'Chip: '
/usr/sbin/sysctl -n machdep.cpu.brand_string
printf 'macOS: %s\nHardware target: %s\n' "$version" "$target"
/bin/df -h "$HOME"
echo 'PASS: bundle integrity and private M3 eligibility checks. This is not physical boot qualification.'
echo 'Next: follow README.md to stage the assets and approve the unsigned package.'
