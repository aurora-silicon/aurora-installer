#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

postinstall=$ROOT/Packaging/pkg/scripts/postinstall
source "$ROOT/Packaging/identity.conf"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

grep -Fq 'remove_legacy_app "/Applications/$INSTALLER_LEGACY_APP_NAME.app"' "$postinstall" ||
  fail "postinstall removes the app installed under the legacy name"

# Run the real function against disposable bundles, with PlistBuddy and pgrep
# replaced by stubs: PlistBuddy prints the fixture's identifier file and pgrep
# reports a running app when the fixture carries a running marker.
sed -n '/^remove_legacy_app() {$/,/^}$/p' "$postinstall" >"$test_tmp/function.sh"
[[ -s $test_tmp/function.sh ]] || fail "postinstall defines remove_legacy_app"
cat >"$test_tmp/plistbuddy" <<'STUB'
#!/bin/bash
cat "$3"
STUB
cat >"$test_tmp/pgrep" <<'STUB'
#!/bin/bash
[[ ! -e ${2%/Contents/}/pgrep-fails ]] || exit 3
[[ -e ${2%/Contents/}/running ]]
STUB
chmod +x "$test_tmp/plistbuddy" "$test_tmp/pgrep"

make_bundle() {
  mkdir -p "$1/Contents"
  printf '%s\n' "$2" >"$1/Contents/Info.plist"
}

run_removal() (
  PLIST_BUDDY=$test_tmp/plistbuddy
  PGREP=$test_tmp/pgrep
  source "$test_tmp/function.sh"
  remove_legacy_app "$1"
)

legacy=$test_tmp/Applications/$INSTALLER_LEGACY_APP_NAME.app

make_bundle "$legacy" "$INSTALLER_APP_IDENTIFIER"
run_removal "$legacy" 2>"$test_tmp/log" || fail "removal succeeds" "$(cat "$test_tmp/log")"
[[ ! -e $legacy ]] || fail "a legacy bundle with this app's identifier is removed"
pass "the legacy installer app is removed"

make_bundle "$legacy" "org.example.other"
run_removal "$legacy" 2>"$test_tmp/log" || fail "a refusal still succeeds"
[[ -d $legacy ]] || fail "a bundle with another identifier is kept"
grep -Fq "bundle identifier is 'org.example.other'" "$test_tmp/log" || fail "the refusal is logged" "$(cat "$test_tmp/log")"
rm -rf "$legacy"
pass "a bundle with another identifier is kept"

make_bundle "$legacy" "$INSTALLER_APP_IDENTIFIER"
touch "$legacy/running"
run_removal "$legacy" 2>"$test_tmp/log" || fail "a refusal still succeeds"
[[ -d $legacy ]] || fail "a running legacy app is kept"
grep -Fq "it is running" "$test_tmp/log" || fail "the refusal is logged" "$(cat "$test_tmp/log")"
rm -rf "$legacy"
pass "a running legacy app is kept"

make_bundle "$legacy" "$INSTALLER_APP_IDENTIFIER"
touch "$legacy/pgrep-fails"
run_removal "$legacy" 2>"$test_tmp/log" || fail "a refusal still succeeds"
[[ -d $legacy ]] || fail "a legacy app is kept when pgrep cannot tell whether it runs"
grep -Fq "could not tell whether it is running" "$test_tmp/log" || fail "the refusal is logged" "$(cat "$test_tmp/log")"
rm -rf "$legacy"
pass "a legacy app is kept when pgrep fails"

make_bundle "$test_tmp/target.app" "$INSTALLER_APP_IDENTIFIER"
ln -s "$test_tmp/target.app" "$legacy"
run_removal "$legacy" 2>"$test_tmp/log" || fail "a symlink is ignored without failing"
[[ -L $legacy && -d $test_tmp/target.app/Contents ]] || fail "a symlinked legacy path and its target are kept"
rm -f "$legacy"
pass "a symlinked legacy path is left alone"

run_removal "$legacy" 2>"$test_tmp/log" || fail "an absent legacy app is not an error"
[[ ! -s $test_tmp/log ]] || fail "an absent legacy app logs nothing" "$(cat "$test_tmp/log")"
pass "an absent legacy app is a no-op"
