#!/bin/bash
# Exact code-directory requirements for ad-hoc developer packaging.
installer_code_hash() {
  local details digest
  /usr/bin/codesign --verify --strict "$1" || return 1
  details=$(/usr/bin/codesign --display --verbose=4 "$1" 2>&1) || return 1
  digest=$(printf '%s\n' "$details" | /usr/bin/sed -n 's/^CDHash=//p')
  [[ $digest =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$digest"
}

installer_code_requirement() {
  local digest
  [[ $2 =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  digest=$(installer_code_hash "$1") || return 1
  printf 'identifier "%s" and cdhash H"%s"\n' "$2" "$digest"
}
