#!/bin/bash
# Refuses a Mach-O file (object or executable) whose minimum macOS is newer than
# the Recovery app's deployment target, macOS 13.0 (Package.swift): ld only
# warns when it links such an object, and recoveryOS 13 could then lack what
# it calls. Every architecture slice is checked; a file without a build
# version (LC_BUILD_VERSION or LC_VERSION_MIN_MACOSX) is refused too.
set -euo pipefail
status=0
for file in "$@"; do
  # LC_BUILD_VERSION prints "minos 13.0"; LC_VERSION_MIN_MACOSX a "version" line after its cmd.
  versions=$(xcrun otool -l "$file" | awk '
    $1 == "cmd" { legacy = ($2 == "LC_VERSION_MIN_MACOSX") }
    $1 == "minos" || ($1 == "version" && legacy) { print $2 }')
  if [[ -z $versions ]]; then
    echo "$file: no minimum macOS version" >&2
    status=1
  fi
  for version in $versions; do
    if [[ $(printf '%s\n13.0\n' "$version" | sort -V | tail -n 1) != 13.0 ]]; then
      echo "$file: built for macOS $version, newer than the Recovery app's 13.0" >&2
      status=1
    fi
  done
done
exit "$status"
