#!/bin/bash

set -euo pipefail

fail() {
  echo "notarize-app: $*" >&2
  exit 1
}

source "$(cd "$(dirname "$0")" && pwd -P)/identity.conf"
packaging_directory="$(cd "$(dirname "$0")" && pwd -P)"

verify_only=false
if [[ ${1:-} == --verify-only ]]; then
  verify_only=true
  shift
fi
(( $# == 1 )) \
  || fail "usage: notarize-app.sh [--verify-only] '/absolute/path/$INSTALLER_APP_NAME.app'"

app_path="$1"
notary_profile="${OMARCHY_NOTARY_PROFILE:-}"

[[ $app_path == /* && -d $app_path && ! -L $app_path ]] \
  || fail "application must be an absolute path to a real bundle"
[[ $verify_only == true || -n $notary_profile ]] \
  || fail "OMARCHY_NOTARY_PROFILE is required"
[[ $app_path == *.app ]] \
  || fail "application path must end in .app"

codesign --verify --deep --strict --verbose=2 "$app_path"
signing_details="$(codesign --display --verbose=4 "$app_path" 2>&1)"
release_team=$(printf '%s\n' "$signing_details" | sed -n 's/^TeamIdentifier=//p')
[[ $release_team =~ ^[A-Z0-9]{10}$ ]] || fail "application has no release signing team"

verify_release_code() {
  local code_path="$1" code_identifier="$2" details actual_team code_flags timestamp requirement
  [[ $code_identifier =~ ^[A-Za-z0-9.-]+$ ]] || fail "invalid release code identifier"
  requirement="anchor apple generic and identifier \"$code_identifier\" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"$release_team\""
  codesign --verify --strict -R="$requirement" "$code_path"
  details=$(codesign --display --verbose=4 "$code_path" 2>&1)
  [[ $details == *"Authority=Developer ID Application:"* ]] \
    || fail "release code is not signed with Developer ID Application: $code_path"
  actual_team=$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=//p')
  [[ $actual_team == "$release_team" ]] || fail "release code has a different signing team: $code_path"
  timestamp=$(printf '%s\n' "$details" | sed -n 's/^Timestamp=//p')
  [[ -n $timestamp && $timestamp != none && $timestamp != 'not set' ]] \
    || fail "release code has no secure timestamp: $code_path"
  [[ $details =~ flags=(0x[0-9a-fA-F]+) ]] || fail "release code has no signature flags: $code_path"
  code_flags="${BASH_REMATCH[1]}"
  (( (code_flags & 0x10000) != 0 )) || fail "release code lacks hardened runtime: $code_path"
}

verify_release_code "$app_path" "$INSTALLER_APP_IDENTIFIER"
verify_release_code "$app_path/Contents/Library/LaunchServices/$INSTALLER_HELPER_IDENTIFIER" "$INSTALLER_HELPER_IDENTIFIER"
unexpected_engine=$(/usr/bin/find "$app_path" \( -name '*.py' -o -name '*.pyc' -o -name 'Python.framework' \
  -o -name 'python3*' -o -name 'installer-*.tar.gz' -o -path "$app_path/Contents/Resources/Engine" \) \
  -print -quit)
[[ -z $unexpected_engine ]] || fail "release app contains Python or an engine archive: $unexpected_engine"
decoder="$app_path/Contents/Helpers/omarchy-restore-image"
verify_release_code "$decoder" "$INSTALLER_RESTORE_IMAGE_IDENTIFIER"
recovery="$app_path/Contents/Resources/RecoveryTemplate/$INSTALLER_APP_NAME.app"
recovery_identifier=$(plutil -extract CFBundleIdentifier raw -o - "$recovery/Contents/Info.plist")
verify_release_code "$recovery" "$recovery_identifier"

if [[ $verify_only == true ]]; then
  echo "Release signatures verified (preflight only)."
  exit 0
fi

archive_root="$(mktemp -d "${TMPDIR:-/private/tmp}/aurora-notary.XXXXXX")"
trap 'rm -rf "$archive_root"' EXIT
archive_path="$archive_root/$INSTALLER_FILE_STEM.zip"

ditto -c -k --keepParent "$app_path" "$archive_path"
notary_arguments=(--keychain-profile "$notary_profile")
if [[ -n ${OMARCHY_NOTARY_KEYCHAIN:-} ]]; then
  notary_arguments+=(--keychain "$OMARCHY_NOTARY_KEYCHAIN")
fi
xcrun notarytool submit "$archive_path" "${notary_arguments[@]}" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"
