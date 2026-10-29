#!/bin/bash
# Produce the on-demand download from an already notarized native app.
set -euo pipefail

fail() { echo "make-download-dmg: $*" >&2; exit 1; }
packaging_directory=$(cd "$(dirname "$0")" && pwd -P)
source "$packaging_directory/identity.conf"
(( $# == 2 )) || fail "usage: make-download-dmg.sh APP_PATH OUTPUT_DMG"
[[ $(uname -s) == Darwin ]] || fail "requires macOS"
app_path=$1
dmg_path=$2
[[ $app_path == /* && -d $app_path && ! -L $app_path &&
   $(basename "$app_path") == "$INSTALLER_APP_NAME.app" ]] || fail "unsafe application path"
[[ $dmg_path == /*.dmg && ! -e $dmg_path && ! -L $dmg_path &&
   -d ${dmg_path%/*} ]] || fail "output must be a new absolute .dmg path"
: "${AURORA_APP_SIGNING_IDENTITY:?}" "${AURORA_NOTARY_PROFILE:?}" "${AURORA_TEAM_ID:?}"
[[ $AURORA_APP_SIGNING_IDENTITY != - ]] || fail "a release signing identity is required"
[[ $AURORA_TEAM_ID =~ ^[A-Z0-9]{10}$ ]] || fail "invalid release team"
team_requirement="anchor apple generic and certificate leaf[subject.OU] = \"$AURORA_TEAM_ID\""
for directory in Engine Artifacts; do
  [[ ! -e $app_path/Contents/Resources/$directory && ! -L $app_path/Contents/Resources/$directory ]] \
    || fail "the on-demand download must not bundle $directory"
done
bash "$packaging_directory/notarize-app.sh" --verify-only "$app_path"
codesign --verify --strict -R="$team_requirement" "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"

app_kib=$(du -sk "$app_path" | awk '{print $1}')
[[ $app_kib =~ ^[0-9]+$ ]] && (( app_kib <= 32768 )) || fail "the on-demand app exceeds 32 MiB"
free_kib=$(df -Pk "${dmg_path%/*}" | awk 'NR == 2 {print $4}')
[[ $free_kib =~ ^[0-9]+$ ]] && (( free_kib - 3 * app_kib >= 10485760 )) \
  || fail "packaging must leave at least 10 GiB free"
scratch=$(mktemp -d "${dmg_path%/*}/.aurora-dmg.XXXXXX")
cleanup() {
  result=$?
  trap - EXIT HUP INT TERM
  if ! rm -rf -- "$scratch" || [[ -e $scratch ]]; then
    echo 'make-download-dmg: temporary image cleanup failed' >&2
    exit 1
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$scratch/content"
/usr/bin/ditto "$app_path" "$scratch/content/$INSTALLER_APP_NAME.app"
ln -s /Applications "$scratch/content/Applications"
hdiutil create -quiet -fs HFS+ -format UDZO -volname "$INSTALLER_APP_NAME" \
  -srcfolder "$scratch/content" "$scratch/download.dmg"
codesign --sign "$AURORA_APP_SIGNING_IDENTITY" --timestamp \
  --identifier "$INSTALLER_APP_IDENTIFIER.diskimage" "$scratch/download.dmg"
codesign --verify --strict -R="$team_requirement" "$scratch/download.dmg"
notary_arguments=(--keychain-profile "$AURORA_NOTARY_PROFILE")
if [[ -n ${AURORA_NOTARY_KEYCHAIN:-} ]]; then
  notary_arguments+=(--keychain "$AURORA_NOTARY_KEYCHAIN")
fi
xcrun notarytool submit "$scratch/download.dmg" "${notary_arguments[@]}" --wait
xcrun stapler staple "$scratch/download.dmg"
xcrun stapler validate "$scratch/download.dmg"
hdiutil verify -quiet "$scratch/download.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$scratch/download.dmg"
mv -n "$scratch/download.dmg" "$dmg_path"
[[ ! -e $scratch/download.dmg ]] || fail "output appeared during packaging"
echo "$dmg_path"
/usr/bin/shasum -a 256 "$dmg_path"
