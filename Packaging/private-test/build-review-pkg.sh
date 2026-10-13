#!/bin/bash
# Assemble an unsigned review package. Does not install, register or launch anything.
set -euo pipefail
[[ $# == 2 ]] || { echo 'usage: build-review-pkg.sh APP OUTPUT.pkg' >&2; exit 64; }
APP=$(cd "$1" && pwd -P)
OUT=$2
[[ $OUT == /* && ! -e $OUT ]] || { echo 'Use a new absolute output path.' >&2; exit 64; }
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/Packaging/identity.conf"
[[ $(/usr/bin/plutil -extract OmarchyPrivatePlainTest raw -o - "$APP/Contents/Info.plist") == "true" ]] || exit 1
app_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
app_build=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")
/usr/bin/codesign --verify --deep --strict "$APP"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root/Applications" "$work/root/Library/LaunchDaemons" "$work/scripts"
/usr/bin/ditto "$APP" "$work/root/Applications/$INSTALLER_APP_NAME.app"
/bin/bash "$ROOT/Packaging/pkg/derive-daemon-plist" "$APP" "$work/root/Library/LaunchDaemons/$INSTALLER_HELPER_IDENTIFIER.plist" /Applications
/bin/bash "$ROOT/Packaging/private-test/render-identity.sh" "$ROOT/Packaging/private-test/scripts/preinstall" "$work/scripts/preinstall"
cp "$ROOT/Packaging/pkg/scripts/postinstall" "$work/scripts/postinstall"
chmod 755 "$work/scripts/"*
# The generic postinstall reads the helper label from the identity beside it.
install -m 0644 "$ROOT/Packaging/identity.conf" "$work/scripts/identity.conf"
/usr/bin/pkgbuild --analyze --root "$work/root" "$work/components.plist"
/usr/bin/plutil -replace 0.BundleIsRelocatable -bool false "$work/components.plist"
/usr/bin/pkgbuild --root "$work/root" --component-plist "$work/components.plist" \
  --scripts "$work/scripts" --identifier "$INSTALLER_APP_IDENTIFIER.private-m3-test.pkg" \
  --version "$app_version.$app_build" --install-location / --ownership recommended "$OUT"
echo 'Unsigned review package built. Not notarized and not approved for tester distribution.'
