#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/Packaging/identity.conf"
helper_id=$INSTALLER_HELPER_IDENTIFIER

if [[ $(uname) != Darwin ]]; then
  pass "app download checks need macOS tools; skipped"
  exit 0
fi

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

plist_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

# helper-plists: a named-identity build declares the app and the launchd job.
named=$test_tmp/named
mkdir "$named"
"$ROOT/Packaging/helper-plists" "$named" 42 2.1.0 'identifier "client.probe"' >/dev/null
[[ $(plist_value "$named/helper-info.plist" CFBundleIdentifier) == "$helper_id" ]] ||
  fail "the helper Info.plist names the helper"
[[ $(plist_value "$named/helper-info.plist" CFBundleVersion) == 42 ]] ||
  fail "the helper Info.plist carries the build number"
[[ $(plist_value "$named/helper-info.plist" SMAuthorizedClients.0) == 'identifier "client.probe"' ]] ||
  fail "the helper authorizes exactly the app's requirement"
[[ $(plist_value "$named/helper-launchd.plist" Label) == "$helper_id" ]] ||
  fail "the launchd job is labelled by the helper"
[[ $(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["MachServices"].get(sys.argv[2]))' "$named/helper-launchd.plist" "$helper_id") == True ]] ||
  fail "the launchd job publishes the helper's Mach service"
[[ $(plist_value "$named/helper-launchd.plist" UserName) == root ]] ||
  fail "the launchd job runs as root"
[[ $(plist_value "$named/helper-launchd.plist" EnvironmentVariables.OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT) == 'identifier "client.probe"' ]] ||
  fail "the launchd job gives the helper the client requirement"
! /usr/bin/plutil -extract Program raw -o - "$named/helper-launchd.plist" >/dev/null 2>&1 ||
  fail "the launchd job leaves Program to SMJobBless"
pass "helper plists declare the helper for SMJobBless"

# An ad hoc build gets only the version: no authorized clients, no job.
adhoc=$test_tmp/adhoc
mkdir "$adhoc"
"$ROOT/Packaging/helper-plists" "$adhoc" 42 2.1.0 >/dev/null
[[ $(plist_value "$adhoc/helper-info.plist" CFBundleVersion) == 42 ]] ||
  fail "an ad hoc helper still carries its build number"
! plist_value "$adhoc/helper-info.plist" SMAuthorizedClients >/dev/null ||
  fail "an ad hoc helper authorizes no client"
[[ ! -e $adhoc/helper-launchd.plist ]] || fail "an ad hoc helper has no SMJobBless job"
pass "ad hoc helper plists leave no SMJobBless registration"

# make-download-zip: exactly the app, and only a stapled one unless told.
app="$test_tmp/$INSTALLER_APP_NAME.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchServices"
printf 'app\n' >"$app/Contents/MacOS/app"
printf 'helper\n' >"$app/Contents/Library/LaunchServices/$helper_id"
if "$ROOT/Packaging/make-download-zip.sh" "$app" "$test_tmp/unstapled.zip" >/dev/null 2>&1; then
  fail "an app without a stapled ticket is not packaged"
fi
[[ ! -e $test_tmp/unstapled.zip ]] || fail "no zip is left behind for an unstapled app"
OMARCHY_DOWNLOAD_ZIP_UNSTAPLED=1 "$ROOT/Packaging/make-download-zip.sh" "$app" "$test_tmp/download.zip" >/dev/null ||
  fail "a structural zip is built"
entries=$(/usr/bin/zipinfo -1 "$test_tmp/download.zip" | awk -F/ '{print $1}' | sort -u)
[[ $entries == "$INSTALLER_APP_NAME.app" ]] || fail "the zip holds only the app" "$entries"
/usr/bin/zipinfo -1 "$test_tmp/download.zip" | grep -Fxq "$INSTALLER_APP_NAME.app/Contents/Library/LaunchServices/$helper_id" ||
  fail "the zip keeps the helper where SMJobBless looks"
if OMARCHY_DOWNLOAD_ZIP_UNSTAPLED=1 "$ROOT/Packaging/make-download-zip.sh" "$app" "$test_tmp/download.zip" >/dev/null 2>&1; then
  fail "an existing zip is never overwritten"
fi
other="$test_tmp/Other.app"
mkdir -p "$other/Contents"
if OMARCHY_DOWNLOAD_ZIP_UNSTAPLED=1 "$ROOT/Packaging/make-download-zip.sh" "$other" "$test_tmp/other.zip" >/dev/null 2>&1; then
  fail "only the installer app is packaged"
fi
pass "the download zip holds exactly the installer app"
