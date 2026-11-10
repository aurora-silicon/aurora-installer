#!/bin/bash
# Shared, unchanged download size limit; run before notarization as well.
set -euo pipefail
fail() { echo "check-download-size: $*" >&2; exit 1; }
(( $# == 1 )) || fail "usage: check-download-size.sh APP_PATH"
app_path=$1
[[ -d $app_path && ! -L $app_path ]] || fail "application must be a real directory"
app_kib=$(du -sk "$app_path" | awk '{print $1}')
[[ $app_kib =~ ^[0-9]+$ ]] || fail "cannot measure the application"
printf 'On-demand app allocated size: %s KiB; limit: 32768 KiB\n' "$app_kib"
# Retain component sizes even when the guard rejects a bundle.
du -ak "$app_path" | sort -nr | awk 'NR <= 30 {print}'
(( app_kib <= 32768 )) || fail "the on-demand app exceeds 32 MiB"
