#!/bin/bash
# Build the explicitly opted-in private ad-hoc package; never install it.
set -euo pipefail
(( $# == 2 )) || { echo 'usage: build-tester-pkg.sh EXACT_PRIVATE_APP NEW_OUTPUT.pkg' >&2; exit 64; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$root/Packaging/identity.conf"
source "$root/Packaging/private-test/code-identity.sh"
app=$(cd "$1" && pwd -P)
output=$2
[[ $output == /* && ! -e $output && ! -L $output ]] || exit 64
profile=$(private_bundle_profile "$app")
package_identifier=$INSTALLER_APP_IDENTIFIER.private-m3-test.pkg
if [[ $profile == "limine" ]]; then
  package_identifier=$INSTALLER_APP_IDENTIFIER.private-limine-test.pkg
  python3 "$root/Packaging/private-test/prepare-limine-assets.py" --verify-release "$app/Contents/Resources/Release" >/dev/null
fi
[[ $(/usr/bin/plutil -extract OmarchyPrivateExactBuild raw -o - "$app/Contents/Info.plist") == "true" ]] || exit 1
/usr/bin/codesign --verify --deep --strict "$app"
app_requirement=$(private_code_requirement "$app" "$INSTALLER_APP_IDENTIFIER")
helper="$app/Contents/Library/LaunchServices/$INSTALLER_HELPER_IDENTIFIER"
[[ $(/usr/bin/lipo -archs "$helper") == "arm64" ]] || exit 1
[[ $(/usr/bin/lipo -archs "$app/Contents/MacOS/OmarchyAppleInstallerApp") == "arm64" ]] || exit 1
helper_requirement=$(private_code_requirement "$helper" "$INSTALLER_HELPER_IDENTIFIER")
[[ $(/usr/bin/plutil -extract helper_code_signing_requirement raw -o - "$app/Contents/Resources/Release/release.json") == "$helper_requirement" ]] || exit 1
[[ $(/usr/bin/plutil -extract EnvironmentVariables.OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT raw -o - "$app/Contents/Library/LaunchDaemons/$INSTALLER_HELPER_IDENTIFIER.plist") == "never" ]] || exit 1
/usr/bin/codesign --verify --strict -R="$app_requirement" "$app"
/usr/bin/codesign --verify --strict -R="$helper_requirement" "$helper"
version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")
build=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root/Applications" "$work/root/Library/LaunchDaemons" "$work/root/Library/PrivilegedHelperTools" "$work/scripts"
/usr/bin/ditto "$app" "$work/root/Applications/$INSTALLER_APP_NAME.app"
/usr/bin/install -m 755 "$helper" "$work/root/Library/PrivilegedHelperTools/$INSTALLER_HELPER_IDENTIFIER"
plist="$work/root/Library/LaunchDaemons/$INSTALLER_HELPER_IDENTIFIER.plist"
python3 - "$plist" "$app_requirement" "$INSTALLER_HELPER_IDENTIFIER" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({
        'Label': sys.argv[3],
        'Program': '/Library/PrivilegedHelperTools/' + sys.argv[3],
        'MachServices': {sys.argv[3]: True},
        'UserName': 'root',
        'EnvironmentVariables': {'OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT': sys.argv[2]},
    }, output)
PY
/bin/bash "$root/Packaging/private-test/render-identity.sh" "$root/Packaging/private-test/scripts/preinstall" "$work/scripts/preinstall"
/bin/bash "$root/Packaging/private-test/render-identity.sh" "$root/Packaging/private-test/scripts/postinstall" "$work/postinstall.template"
plist_digest=$(/usr/bin/shasum -a 256 "$plist")
plist_digest=${plist_digest%% *}
/usr/bin/sed \
  -e "s/@APP_HASH@/$(private_code_hash "$app")/g" \
  -e "s/@HELPER_HASH@/$(private_code_hash "$helper")/g" \
  -e "s/@PLIST_SHA256@/$plist_digest/g" \
  "$work/postinstall.template" > "$work/scripts/postinstall"
chmod 755 "$work/scripts/"*
chmod 755 "$work/root/Library/PrivilegedHelperTools"
chmod 644 "$plist"
/usr/bin/pkgbuild --analyze --root "$work/root" "$work/components.plist"
/usr/bin/plutil -replace 0.BundleIsRelocatable -bool false "$work/components.plist"
/usr/bin/pkgbuild --root "$work/root" --component-plist "$work/components.plist" \
  --scripts "$work/scripts" --identifier "$package_identifier" \
  --version "$version.$build" --install-location / --ownership recommended "$output"
echo "Private unsigned package: $output"
