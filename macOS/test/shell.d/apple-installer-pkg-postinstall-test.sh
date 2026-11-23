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

# secure_helper, with chown and stat replaced by stubs: chown records its
# arguments (or fails when the fixture says so), stat reports the owner the
# fixture names and the file's real mode.
grep -Fq 'secure_helper "$HELPER" || exit 1' "$postinstall" ||
  fail "postinstall fails the package when the helper is not secured"
helper_line=$(grep -n 'secure_helper "$HELPER" || exit 1' "$postinstall" | cut -d: -f1)
bootstrap_line=$(grep -n 'launchctl bootstrap system' "$postinstall" | head -1 | cut -d: -f1)
(( helper_line < bootstrap_line )) || fail "the helper is secured before launchd loads it"
sed -n '/^secure_helper() {$/,/^}$/p' "$postinstall" >"$test_tmp/secure.sh"
[[ -s $test_tmp/secure.sh ]] || fail "postinstall defines secure_helper"
cat >"$test_tmp/chown" <<'STUB'
#!/bin/bash
[[ ! -e ${3}.chown-fails ]] || exit 1
printf '%s\n' "$*" >>"$CHOWN_LOG"
STUB
cat >"$test_tmp/stat" <<'STUB'
#!/bin/bash
file=${@: -1}
owner=root:wheel
[[ ! -e $file.owner ]] || owner=$(cat "$file.owner")
mode=$(command stat -c %a "$file" 2>/dev/null || command stat -f %Lp "$file")
printf '%s %s\n' "$owner" "$mode"
STUB
chmod +x "$test_tmp/chown" "$test_tmp/stat"

run_secure() (
  CHOWN=$test_tmp/chown
  CHMOD=chmod
  STAT=$test_tmp/stat
  export CHOWN_LOG=$test_tmp/chown.log
  source "$test_tmp/secure.sh"
  secure_helper "$1"
)

tools=$test_tmp/PrivilegedHelperTools
mkdir -p "$tools"
helper=$tools/$INSTALLER_HELPER_IDENTIFIER
printf '#!/bin/sh\n' >"$helper"
chmod 0777 "$helper"
: >"$test_tmp/chown.log"
run_secure "$helper" 2>"$test_tmp/log" || fail "a regular helper is secured" "$(cat "$test_tmp/log")"
grep -Fxq -e "-h root:wheel $helper" "$test_tmp/chown.log" || fail "the helper is chowned root:wheel, never through a link" "$(cat "$test_tmp/chown.log")"
[[ $(stat -c %a "$helper" 2>/dev/null || stat -f %Lp "$helper") == 755 ]] || fail "the helper is mode 0755"
pass "the installed helper is set to root:wheel 0755"

rm -f "$helper"
printf '#!/bin/sh\n' >"$test_tmp/elsewhere"
ln -s "$test_tmp/elsewhere" "$helper"
: >"$test_tmp/chown.log"
if run_secure "$helper" 2>"$test_tmp/log"; then fail "a symlinked helper fails the package"; fi
[[ ! -s $test_tmp/chown.log ]] || fail "a symlinked helper is never chowned"
rm -f "$helper"
mkdir "$helper"
if run_secure "$helper" 2>"$test_tmp/log"; then fail "a directory in the helper's place fails the package"; fi
rmdir "$helper"
if run_secure "$helper" 2>"$test_tmp/log"; then fail "a missing helper fails the package"; fi
grep -Fq "missing or not a regular file" "$test_tmp/log" || fail "the refusal is logged" "$(cat "$test_tmp/log")"
pass "a missing, linked or directory helper fails the package"

mv "$tools" "$test_tmp/real-tools"
ln -s "$test_tmp/real-tools" "$tools"
printf '#!/bin/sh\n' >"$helper"
if run_secure "$helper" 2>"$test_tmp/log"; then fail "a linked PrivilegedHelperTools fails the package"; fi
rm "$tools"
mv "$test_tmp/real-tools" "$tools"
pass "a linked helper directory fails the package"

printf 'admin:staff' >"$helper.owner"
if run_secure "$helper" 2>"$test_tmp/log"; then fail "a helper left with another owner fails the package"; fi
grep -Fq "not root:wheel 755" "$test_tmp/log" || fail "the owner refusal is logged" "$(cat "$test_tmp/log")"
rm -f "$helper.owner"
touch "$helper.chown-fails"
if run_secure "$helper" 2>"$test_tmp/log"; then fail "a failed chown fails the package"; fi
rm -f "$helper.chown-fails"
pass "a helper that can't be made root:wheel 0755 fails the package"
