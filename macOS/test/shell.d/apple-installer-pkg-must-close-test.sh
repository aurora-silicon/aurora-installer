#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

source "$ROOT/Packaging/identity.conf"
add_must_close=$ROOT/Packaging/pkg/add-must-close
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

grep -Fq '"$PKG_DIR/add-must-close" "$distribution" "$PKG_IDENTIFIER" "$INSTALLER_APP_IDENTIFIER"' \
  "$ROOT/Packaging/pkg/build-pkg.sh" ||
  fail "build-pkg.sh asks for the installer app to be closed"
grep -Fq -- '--distribution "$distribution"' "$ROOT/Packaging/pkg/build-pkg.sh" ||
  fail "build-pkg.sh builds from the edited distribution"

# The shape productbuild --synthesize writes for a single component package.
write_distribution() {
  cat >"$1" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <pkg-ref id="$INSTALLER_PKG_IDENTIFIER"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <choices-outline>
        <line choice="default">
            <line choice="$INSTALLER_PKG_IDENTIFIER"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$INSTALLER_PKG_IDENTIFIER" visible="false">
        <pkg-ref id="$INSTALLER_PKG_IDENTIFIER"/>
    </choice>
    <pkg-ref id="$INSTALLER_PKG_IDENTIFIER" version="2.0.0" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
XML
}

distribution=$test_tmp/distribution.xml
write_distribution "$distribution"
bash "$add_must_close" "$distribution" "$INSTALLER_PKG_IDENTIFIER" "$INSTALLER_APP_IDENTIFIER" ||
  fail "add-must-close accepts a synthesized distribution"
python3 - "$distribution" "$INSTALLER_PKG_IDENTIFIER" "$INSTALLER_APP_IDENTIFIER" <<'PY' ||
import sys
import xml.etree.ElementTree as ET
path, package_identifier, app_identifier = sys.argv[1:4]
root = ET.parse(path).getroot()
closing = [ref for ref in root.findall("pkg-ref") if ref.find("must-close") is not None]
assert len(closing) == 1, closing
assert closing[0].get("id") == package_identifier
apps = [app.get("id") for app in closing[0].find("must-close").findall("app")]
assert apps == [app_identifier], apps
assert root.find("choice[@id='%s']/pkg-ref" % package_identifier) is not None
PY
  fail "the distribution asks for the installer app, by bundle identifier, to be closed" "$(cat "$distribution")"
pass "the package asks Installer to close a running installer app first"

if bash "$add_must_close" "$distribution" "$INSTALLER_PKG_IDENTIFIER" "$INSTALLER_APP_IDENTIFIER" 2>"$test_tmp/log"; then
  fail "add-must-close refuses a distribution that already lists apps to close"
fi
write_distribution "$distribution"
if bash "$add_must_close" "$distribution" "invalid.omarchy.other.pkg" "$INSTALLER_APP_IDENTIFIER" 2>"$test_tmp/log"; then
  fail "add-must-close refuses a distribution without the named package"
fi
printf '<plist/>\n' >"$test_tmp/other.xml"
if bash "$add_must_close" "$test_tmp/other.xml" "$INSTALLER_PKG_IDENTIFIER" "$INSTALLER_APP_IDENTIFIER" 2>"$test_tmp/log"; then
  fail "add-must-close refuses a file that is not a distribution"
fi
pass "add-must-close refuses repeated, mismatched or foreign input"
