#!/bin/bash
# Package the notarized, stapled app as the download: a zip holding exactly
# the app bundle. Safari unpacks it in Downloads and the app runs from there.
#
# Usage: make-download-zip.sh /absolute/path/<app name>.app /absolute/path/out.zip
#
# The app must already carry a stapled notarization ticket (see
# notarize-app.sh). OMARCHY_DOWNLOAD_ZIP_UNSTAPLED=1 skips that check for
# local structural tests only; such a zip must never be published.
set -euo pipefail

fail() {
  echo "make-download-zip: $*" >&2
  exit 1
}

source "$(cd "$(dirname "$0")" && pwd -P)/identity.conf"

(( $# == 2 )) \
  || fail "usage: make-download-zip.sh '/absolute/path/$INSTALLER_APP_NAME.app' /absolute/path/out.zip"
app_path=$1
zip_path=$2

[[ $app_path == /* && -d $app_path && ! -L $app_path ]] \
  || fail "application must be an absolute path to a real bundle"
[[ $(basename "$app_path") == "$INSTALLER_APP_NAME.app" ]] \
  || fail "application must be named $INSTALLER_APP_NAME.app"
[[ $zip_path == /*.zip && ! -e $zip_path && ! -L $zip_path ]] \
  || fail "output must be a new absolute .zip path"

if [[ ${OMARCHY_DOWNLOAD_ZIP_UNSTAPLED:-0} != "1" ]]; then
  xcrun stapler validate "$app_path" >/dev/null \
    || fail "application has no stapled notarization ticket"
  codesign --verify --deep --strict "$app_path" \
    || fail "application signature does not verify"
fi

/usr/bin/ditto -c -k --keepParent "$app_path" "$zip_path"

# The archive must hold the app and nothing beside it.
entries=$(/usr/bin/zipinfo -1 "$zip_path" | awk -F/ '{print $1}' | sort -u)
[[ $entries == "$INSTALLER_APP_NAME.app" ]] || {
  rm -f "$zip_path"
  fail "archive must contain only $INSTALLER_APP_NAME.app (found: ${entries//$'\n'/, })"
}
echo "$zip_path"
echo "sha256: $(/usr/bin/shasum -a 256 "$zip_path" | awk '{print $1}')"
