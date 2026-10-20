#!/bin/bash
# Real macOS signature checks; builds/expands packages but never installs them.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/Packaging/identity.conf"
source "$root/Packaging/code-identity.sh"
[[ $(uname -s) == "Darwin" ]] || { echo 'macOS code-signing tools are required' >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/aurora-peer-binding.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { echo "peer-binding: $*" >&2; exit 1; }

make_executable() {
  local output=$1 value=$2 identifier=$3
  printf 'int main(void) { return %s; }\n' "$value" > "$work/probe.c"
  xcrun clang -arch arm64 -O1 "$work/probe.c" -o "$output"
  /usr/bin/codesign --force --sign - --timestamp=none --options runtime \
    --identifier "$identifier" "$output"
}

if (( $# == 0 )); then
  app="$work/$INSTALLER_APP_NAME.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchServices" \
    "$app/Contents/Library/LaunchDaemons" "$app/Contents/Resources/Release"
  make_executable "$app/Contents/MacOS/Peer" 0 "$INSTALLER_APP_IDENTIFIER"
  helper="$app/Contents/Library/LaunchServices/$INSTALLER_HELPER_IDENTIFIER"
  make_executable "$helper" 0 "$INSTALLER_HELPER_IDENTIFIER"
  helper_requirement=$(installer_code_requirement "$helper" "$INSTALLER_HELPER_IDENTIFIER")
  python3 - "$app" "$INSTALLER_APP_IDENTIFIER" "$INSTALLER_HELPER_IDENTIFIER" "$helper_requirement" <<'PY'
import json
from pathlib import Path
import plistlib
import sys

app = Path(sys.argv[1])
identifier, helper, requirement = sys.argv[2:]
with (app / "Contents/Info.plist").open("wb") as output:
    plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleExecutable": "Peer",
                   "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "2.1.1",
                   "CFBundleVersion": "42", "OmarchyDeveloperBuild": True}, output)
with (app / "Contents/Library/LaunchDaemons" / (helper + ".plist")).open("wb") as output:
    plistlib.dump({"Label": helper, "BundleProgram": "Contents/Library/LaunchServices/" + helper,
                   "MachServices": {helper: True}, "UserName": "root",
                   "EnvironmentVariables": {"OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT": "never"}}, output)
release = app / "Contents/Resources/Release"
profiles = [distribution + "-" + desktop for distribution in ("fedora", "arch", "nixos")
            for desktop in ("kde", "gnome", "minimal")]
for directory in [release, *[release / "Profiles" / profile for profile in profiles]]:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "release.json").write_text(json.dumps({"helper_code_signing_requirement": requirement}))
PY
  /usr/bin/codesign --force --sign - --timestamp=none --options runtime "$app"
  package="$work/developer.pkg"
  bash "$root/Packaging/build-developer-pkg.sh" "$app" "$package"
elif (( $# == 2 )); then
  app=$1
  package=$2
else
  fail 'usage: macos-developer-peer-binding.sh [EXACT_APP DEVELOPER.pkg]'
fi

/usr/bin/codesign --verify --deep --strict "$app"
[[ $(/usr/bin/plutil -extract OmarchyDeveloperBuild raw -o - "$app/Contents/Info.plist") == "true" ]] \
  || fail 'app is not a developer build'
if /usr/bin/plutil -extract SMPrivilegedExecutables raw -o - "$app/Contents/Info.plist" >/dev/null 2>&1; then
  fail 'ad-hoc app must remain package-only'
fi
embedded="$app/Contents/Library/LaunchDaemons/$INSTALLER_HELPER_IDENTIFIER.plist"
[[ $(/usr/bin/plutil -extract EnvironmentVariables.OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT raw -o - "$embedded") == "never" ]] \
  || fail 'embedded ad-hoc daemon must deny clients'
app_requirement=$(installer_code_requirement "$app" "$INSTALLER_APP_IDENTIFIER")
helper="$app/Contents/Library/LaunchServices/$INSTALLER_HELPER_IDENTIFIER"
helper_requirement=$(installer_code_requirement "$helper" "$INSTALLER_HELPER_IDENTIFIER")
/usr/bin/codesign --verify --strict -R="$helper_requirement" "$helper"
make_executable "$work/OtherClient" 1 "$INSTALLER_APP_IDENTIFIER"
make_executable "$work/OtherHelper" 1 "$INSTALLER_HELPER_IDENTIFIER"
/usr/bin/codesign --verify --strict "$work/OtherClient"
/usr/bin/codesign --verify --strict -R="identifier \"$INSTALLER_APP_IDENTIFIER\"" "$work/OtherClient"
if /usr/bin/codesign --verify --strict -R="$app_requirement" "$work/OtherClient" >/dev/null 2>&1; then
  fail 'unrelated same-identifier client satisfied the exact app requirement'
fi
if /usr/bin/codesign --verify --strict -R="$helper_requirement" "$work/OtherHelper" >/dev/null 2>&1; then
  fail 'unrelated same-identifier helper satisfied the exact helper requirement'
fi
python3 - "$app/Contents/Resources/Release" "$helper_requirement" <<'PY'
import json
from pathlib import Path
import sys

release = Path(sys.argv[1])
profiles = {distribution + "-" + desktop for distribution in ("fedora", "arch", "nixos")
            for desktop in ("kde", "gnome", "minimal")}
assert {path.name for path in (release / "Profiles").iterdir()} == profiles
for path in [release, *release.rglob("*")]:
    mode = path.stat().st_mode
    assert mode & 0o004, (path, "not readable by the installed desktop user")
    if path.is_dir():
        assert mode & 0o001, (path, "not searchable by the installed desktop user")
for descriptor in [release / "release.json", *[release / "Profiles" / profile / "release.json" for profile in sorted(profiles)]]:
    assert json.loads(descriptor.read_text())["helper_code_signing_requirement"] == sys.argv[2], descriptor
print("Root and all nine profile descriptors pin the exact signed helper")
PY
/usr/sbin/pkgutil --expand-full "$package" "$work/expanded"
plist=$(python3 - "$work/expanded" "$INSTALLER_HELPER_IDENTIFIER" <<'PY'
from pathlib import Path
import sys

matches = [path for path in Path(sys.argv[1]).rglob(sys.argv[2] + ".plist")
           if path.parent.name == "LaunchDaemons" and not any(part.endswith(".app") for part in path.parts)]
assert len(matches) == 1, matches
print(matches[0])
PY
)
installed_requirement=$(/usr/bin/plutil -extract EnvironmentVariables.OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT raw -o - "$plist")
[[ $(/usr/bin/plutil -extract Program raw -o - "$plist") == "/Applications/$INSTALLER_APP_NAME.app/Contents/Library/LaunchServices/$INSTALLER_HELPER_IDENTIFIER" ]] \
  || fail 'developer daemon path differs from its installed app'
[[ $installed_requirement == "$app_requirement" ]] || fail 'package does not pin the final app cdhash'
/usr/bin/codesign --verify --strict -R="$installed_requirement" "$app"
if /usr/bin/codesign --verify --strict -R="$installed_requirement" "$work/OtherClient" >/dev/null 2>&1; then
  fail 'package daemon accepts unrelated same-identifier client'
fi
packaged_app=$(python3 - "$work/expanded" "$INSTALLER_APP_NAME.app" <<'PY'
from pathlib import Path
import sys

matches = [path for path in Path(sys.argv[1]).rglob(sys.argv[2]) if path.parent.name == "Applications"]
assert len(matches) == 1, matches
print(matches[0])
PY
)
/usr/bin/codesign --verify --deep --strict "$packaged_app"
[[ $(installer_code_requirement "$packaged_app" "$INSTALLER_APP_IDENTIFIER") == "$app_requirement" ]] \
  || fail 'package changed the signed app'

# A signed but permissive old developer bundle is not admitted by the builder.
/usr/bin/ditto "$app" "$work/Permissive.app"
/usr/bin/plutil -replace EnvironmentVariables.OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT \
  -string "identifier \"$INSTALLER_APP_IDENTIFIER\"" \
  "$work/Permissive.app/Contents/Library/LaunchDaemons/$INSTALLER_HELPER_IDENTIFIER.plist"
/usr/bin/codesign --force --sign - --timestamp=none --options runtime "$work/Permissive.app"
if bash "$root/Packaging/build-developer-pkg.sh" "$work/Permissive.app" "$work/refused.pkg" >/dev/null 2>&1; then
  fail 'permissive embedded developer daemon was accepted'
fi

# The older private review path also installs an external root daemon.
/usr/bin/ditto "$app" "$work/Private.app"
/usr/bin/plutil -remove OmarchyDeveloperBuild "$work/Private.app/Contents/Info.plist"
/usr/bin/plutil -insert OmarchyPrivatePlainTest -bool true "$work/Private.app/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none --options runtime "$work/Private.app"
bash "$root/Packaging/private-test/build-review-pkg.sh" "$work/Private.app" "$work/private-review.pkg"
/usr/sbin/pkgutil --expand-full "$work/private-review.pkg" "$work/private-expanded"
private_plist=$(python3 - "$work/private-expanded" "$INSTALLER_HELPER_IDENTIFIER" <<'PY'
from pathlib import Path
import sys

matches = [path for path in Path(sys.argv[1]).rglob(sys.argv[2] + ".plist")
           if path.parent.name == "LaunchDaemons" and not any(part.endswith(".app") for part in path.parts)]
assert len(matches) == 1, matches
print(matches[0])
PY
)
[[ $(/usr/bin/plutil -extract Program raw -o - "$private_plist") == "/Applications/$INSTALLER_APP_NAME.app/Contents/Library/LaunchServices/$INSTALLER_HELPER_IDENTIFIER" ]] \
  || fail 'private daemon path differs from its installed app'
[[ $(/usr/bin/plutil -extract EnvironmentVariables.OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT raw -o - "$private_plist") == "$(installer_code_requirement "$work/Private.app" "$INSTALLER_APP_IDENTIFIER")" ]] \
  || fail 'private review package does not pin the final app cdhash'
printf 'Developer peer binding: exact app/helper accepted; same-identifier impostors rejected; package-only behavior preserved\n'
