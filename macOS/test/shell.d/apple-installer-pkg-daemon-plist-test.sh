#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/Packaging/identity.conf"
source "$ROOT/Packaging/client-requirement.sh"
helper_id=$INSTALLER_HELPER_IDENTIFIER
app_id=$INSTALLER_APP_IDENTIFIER
team=ABCDE12345
anchored="anchor apple generic and identifier \"$app_id\""
markers=" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"
developer_id="$anchored$markers and certificate leaf[subject.OU] = \"$team\""

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

pkg_dir=$ROOT/Packaging/pkg
derive=$pkg_dir/derive-daemon-plist

make_app() {
  local app=$1 bundle_program=$2 helper=${3:-Contents/Library/LaunchServices/$helper_id}
  mkdir -p "$app/Contents/Library/LaunchDaemons" "$app/$(dirname "$helper")"
  printf '#!/bin/sh\n' >"$app/$helper"
  python3 - "$app/Contents/Library/LaunchDaemons/$helper_id.plist" "$bundle_program" "$helper_id" "$developer_id" <<'PY'
import plistlib, sys
plistlib.dump({
    "Label": sys.argv[3],
    "BundleProgram": sys.argv[2],
    "MachServices": {sys.argv[3]: True},
    "UserName": "root",
    "KeepAlive": False,
    "EnvironmentVariables": {"OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT": sys.argv[4]},
}, open(sys.argv[1], "wb"))
PY
}

read_plist() {
  python3 -c 'import plistlib, sys, json; print(json.dumps(plistlib.load(open(sys.argv[1], "rb")), sort_keys=True))' "$1"
}

app="$test_tmp/$INSTALLER_APP_NAME.app"
make_app "$app" Contents/Library/LaunchServices/$helper_id
out=$test_tmp/daemon.plist
program=$("$derive" "$app" "$out" /Applications)
[[ $program == "/Applications/$INSTALLER_APP_NAME.app/Contents/Library/LaunchServices/$helper_id" ]] ||
  fail "the derived daemon Program is the helper's absolute path under /Applications"
derived=$(read_plist "$out")
grep -Fq "\"Program\": \"/Applications/$INSTALLER_APP_NAME.app/Contents/Library/LaunchServices/$helper_id\"" <<<"$derived" ||
  fail "the derived plist records the absolute Program"
! grep -Fq '"BundleProgram"' <<<"$derived" || fail "the derived plist drops the bundle-relative BundleProgram"
grep -Fq "\"Label\": \"$helper_id\"" <<<"$derived" || fail "the derived plist keeps the Label"
grep -Fq "\"$helper_id\": true" <<<"$derived" || fail "the derived plist keeps the Mach service"
grep -Fq '"UserName": "root"' <<<"$derived" || fail "the derived plist keeps the root UserName"
grep -Fq 'OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT' <<<"$derived" || fail "the derived plist keeps the client requirement"
installer_client_requirement_form "$(python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["EnvironmentVariables"]["OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT"])' "$out")" "$app_id" >/dev/null ||
  fail "the derived plist keeps a client requirement the helper accepts"
pass "the system daemon plist is derived with an absolute Program inside the installed app"

app_missing="$test_tmp/Missing.app"
make_app "$app_missing" Contents/Library/LaunchServices/$helper_id
rm "$app_missing/Contents/Library/LaunchServices/$helper_id"
if "$derive" "$app_missing" "$test_tmp/missing.plist" /Applications >/dev/null 2>&1; then
  fail "derivation rejects a helper that is missing inside the app"
fi
app_escape="$test_tmp/Escape.app"
make_app "$app_escape" ../../../usr/bin/true
if "$derive" "$app_escape" "$test_tmp/escape.plist" /Applications >/dev/null 2>&1; then
  fail "derivation rejects a BundleProgram that escapes the bundle"
fi
app_absolute="$test_tmp/Absolute.app"
make_app "$app_absolute" /usr/bin/true
if "$derive" "$app_absolute" "$test_tmp/absolute.plist" /Applications >/dev/null 2>&1; then
  fail "derivation rejects an absolute BundleProgram"
fi
pass "derivation fails closed on missing, escaping, or absolute helper paths"

! grep -Eq 'launchctl bootstrap system "\$PLIST" 2>/dev/null \|\|' "$pkg_dir/scripts/postinstall" ||
  fail "postinstall no longer hides launchctl bootstrap failures"
grep -Fq 'exit 1' "$pkg_dir/scripts/postinstall" || fail "postinstall fails the package when the daemon cannot load"
grep -Fq 'derive-daemon-plist' "$pkg_dir/build-pkg.sh" || fail "build-pkg.sh derives the daemon plist"
grep -Fq 'daemon Program must be an absolute path' "$pkg_dir/build-pkg.sh" || fail "build-pkg.sh fails on a non-absolute daemon Program"
pass "the package builder and postinstall fail closed on an unloadable daemon"

# The packagers hold the daemon's client requirement to the forms the helper
# accepts (HelperClientRequirement.enforced); any other text, even one that
# compiles, stops the helper at launch and launchd respawns it forever.
hash=$(printf 'a%.0s' {1..40})
form_of() { installer_client_requirement_form "$1" "$app_id"; }
[[ $(form_of "$developer_id") == developer-id ]] || fail "the Developer ID form is accepted"
[[ $(form_of "$anchored and certificate leaf[subject.OU] = \"$team\"") == legacy-team ]] ||
  fail "the team-only form earlier releases wrote is accepted"
for pin in "$hash" "$(printf '0%.0s' {1..40})"; do
  [[ $(form_of "identifier \"$app_id\" and cdhash H\"$pin\"") == cdhash ]] ||
    fail "an exact cdhash pin is accepted: $pin"
done
[[ $(form_of never) == never ]] || fail "the deny-all requirement is accepted"
refused=(
  ""
  "always"
  "anchor apple"
  "anchor apple generic"
  "anchor trusted"
  "identifier \"$app_id\""
  "$anchored"
  "anchor apple generic and certificate leaf[subject.OU] = \"$team\""
  "${developer_id/$app_id/other.app}"
  "anchor apple generic and identifier \"other.app\" and certificate leaf[subject.OU] = \"$team\""
  "identifier \"other.app\" and cdhash H\"$hash\""
  "identifier \"$app_id\" and cdhash H\"$(printf '0%.0s' {1..64})\""
  "$anchored and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"$team\""
  "$anchored and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[subject.OU] = \"$team\""
  "${developer_id/$team/abcde12345}"
  "${developer_id/$team/ABCDE1234}"
  "${developer_id/$team/ABCDE12345\" or \"ABCDE12345}"
  "$developer_id or anchor apple"
  "$developer_id or always"
  "always or $developer_id"
  " $developer_id"
  "$developer_id"$'\n'
  "identifier \"$app_id\" and cdhash H\"$hash\" or always"
  "identifier \"$app_id\" and cdhash H\"${hash:1}\""
  "identifier \"$app_id\" and cdhash H\"${hash^^}\""
  "cdhash H\"$hash\""
  "never or always"
)
for requirement in "${refused[@]}"; do
  if form_of "$requirement" >/dev/null; then
    fail "a requirement the helper refuses is refused at package time: '$requirement'"
  fi
done
swift_source=$ROOT/Sources/AuroraAppleInstaller/HelperClientRequirement.swift
for text in 'certificate 1[field.1.2.840.113635.100.6.2.6]' 'certificate leaf[field.1.2.840.113635.100.6.1.13]' \
  'certificate leaf[subject.OU] = \"' 'and cdhash H\"[0-9a-f]{40}\"' '[A-Z0-9]{10}' 'denyAll = "never"'; do
  grep -Fq -- "$text" "$swift_source" || fail "the package check mirrors the helper's accepted forms: $text"
done
grep -Fq 'installer_client_requirement_form "$requirement"' "$pkg_dir/build-pkg.sh" ||
  fail "build-pkg.sh refuses a client requirement the helper refuses"
grep -Fq 'installer_client_requirement_form "$requirement"' "$ROOT/Packaging/build-developer-pkg.sh" ||
  fail "build-developer-pkg.sh checks the exact pin it writes"
pass "packaging accepts exactly the client requirements the helper accepts"
