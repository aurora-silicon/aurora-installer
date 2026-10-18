#!/bin/bash
# Stage only verified public artifacts in the private user's cache. Never sudo.
set -euo pipefail

fail() { echo "stage-private-assets: $*" >&2; return 1; }
file_mode() {
  if [[ $(uname -s) == "Darwin" ]]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}
file_owner() {
  if [[ $(uname -s) == "Darwin" ]]; then stat -f %u "$1"; else stat -c %u "$1"; fi
}
file_size() {
  if [[ $(uname -s) == "Darwin" ]]; then stat -f %z "$1"; else stat -c %s "$1"; fi
}
verify_file() {
  local path=$1 size=$2 expected=$3 actual
  [[ -f $path && ! -L $path ]] || { fail "missing or unsafe file: $path"; return 1; }
  [[ $(file_size "$path") == "$size" ]] || { fail "wrong size: $path"; return 1; }
  actual=$(shasum -a 256 "$path")
  [[ ${actual%% *} == "$expected" ]] || { fail "wrong checksum: $path"; return 1; }
}
owned_directory() {
  local path=$1 mode
  if [[ ! -e $path && ! -L $path ]]; then mkdir -m 700 "$path" || return 1; fi
  [[ -d $path && ! -L $path && $(file_owner "$path") == "$UID" ]] || {
    fail "unsafe cache directory: $path"; return 1;
  }
  mode=$(file_mode "$path")
  [[ $mode =~ ^[0-7]+$ ]] && (( (8#$mode & 022) == 0 )) || {
    fail "cache directory is writable by another user: $path"; return 1;
  }
}
stage_one() {
  local source=$1 destination=$2 size=$3 digest=$4 pending
  verify_file "$source" "$size" "$digest" || return 1
  if [[ -e $destination || -L $destination ]]; then
    verify_file "$destination" "$size" "$digest"
    return
  fi
  pending=$(mktemp "${destination%/*}/.pending-private.XXXXXX") || return 1
  if ! cp "$source" "$pending" || ! verify_file "$pending" "$size" "$digest"; then
    rm -f "$pending"
    return 1
  fi
  # link(2) publishes without overwriting a raced destination. Perl ships with
  # the supported macOS versions; no Python, Xcode or package manager is needed.
  if ! /usr/bin/perl -e 'link($ARGV[0], $ARGV[1]) or exit 1' "$pending" "$destination"; then
    rm -f "$pending"
    verify_file "$destination" "$size" "$digest"
    return
  fi
  rm -f "$pending"
  verify_file "$destination" "$size" "$digest"
}
stage_bundle() {
  local bundle=$1 user_home=$2 path destination name size digest
  owned_directory "$user_home" || return 1
  path=$user_home
  for name in Library 'Application Support' @APP_IDENTIFIER@.private-m3-20260922 staging quattro-private-m3-family-1c595bb6030c-20260922; do
    path=$path/$name
    owned_directory "$path" || return 1
  done
  destination=$path
  while read -r digest size name; do
    stage_one "$bundle/baseline-assets/$name" "$destination/$name" "$size" "$digest" || return 1
  done <<'PINS'
ecb61645a9c75ba733425fb300b8b53b09f9dbc297a86acce1e0ee41f36e32e5 17838045 installer-v0.9.2-omarchy.17.tar.gz
ea9fe5c5b0eed141354ac2f9b8f88d06570a74372be90ccf046ff7f545a7b467 1001 installer_data.json
161e4273e0885986210b64eb7a9e14756e6bcb3c7a8383f3f58cb43248cdf595 4189468939 omarchy-quattro-1c595bb6030c-development.zip
PINS
  echo "All three private-test assets verified and staged. No app or helper was installed or launched."
}
if [[ ${OMARCHY_STAGE_SOURCE_ONLY:-0} != "1" ]]; then
  [[ $(uname -s) == "Darwin" ]] || { fail "macOS is required"; exit 64; }
  (( EUID != 0 )) || { fail "run as your normal macOS user, not with sudo"; exit 64; }
  umask 077
  stage_bundle "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" "$HOME"
fi
