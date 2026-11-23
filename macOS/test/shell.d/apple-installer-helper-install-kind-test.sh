#!/bin/bash
# The helper removes the package's app only when SMJobBless installed it. A
# package installs the same helper at the same path, so the install kind is
# carried by the launchd job: only the job linked into the helper for
# SMJobBless marks it, and a package's job never does.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
source "$ROOT/Packaging/identity.conf"
helper_id=$INSTALLER_HELPER_IDENTIFIER
marker=AURORA_HELPER_INSTALLED_BY

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# Run helper-plists with plutil replaced by a stub covering the verbs it uses.
cat >"$test_tmp/plutil.py" <<'PY'
import json, plistlib, sys
args = sys.argv[1:]
verb = args[0]
if verb == "-lint":
    for path in args[1:]:
        plistlib.load(open(path, "rb"))
    sys.exit(0)
if verb == "-create":
    plistlib.dump({}, open(args[2], "wb"))
    sys.exit(0)
if verb != "-insert":
    sys.exit("unsupported plutil verb: %s" % verb)
keypath, kind, path = args[1], args[2], args[-1]
value = args[3]
if kind == "-string":
    pass
elif kind == "-json":
    value = json.loads(value)
elif kind == "-array":
    value = []
    path = args[3]
else:
    sys.exit("unsupported plutil type: %s" % kind)
plist = plistlib.load(open(path, "rb"))
node, parts = plist, keypath.split(".")
for part in parts[:-1]:
    node = node[int(part)] if isinstance(node, list) else node[part]
last = parts[-1]
if isinstance(node, list):
    node.insert(int(last), value)
else:
    if last in node:
        sys.exit("key exists: %s" % keypath)
    node[last] = value
plistlib.dump(plist, open(path, "wb"))
PY
# helper-plists reads identity.conf beside it, so both are copied.
mkdir "$test_tmp/Packaging"
cp "$ROOT/Packaging/identity.conf" "$test_tmp/Packaging/identity.conf"
sed "s|/usr/bin/plutil|python3 \"$test_tmp/plutil.py\"|g" "$ROOT/Packaging/helper-plists" \
  >"$test_tmp/Packaging/helper-plists"

env_of() {
  python3 -c 'import plistlib, sys, json; print(json.dumps(plistlib.load(open(sys.argv[1], "rb")).get("EnvironmentVariables", {}), sort_keys=True))' "$1"
}

blessed=$test_tmp/blessed
mkdir "$blessed"
bash "$test_tmp/Packaging/helper-plists" "$blessed" 7 1.0.0 'identifier "x"' >/dev/null ||
  fail "helper-plists writes the SMJobBless job"
[[ -f $blessed/helper-launchd.plist ]] || fail "a signed build gets an SMJobBless launchd job"
grep -Fq "\"$marker\": \"SMJobBless\"" <<<"$(env_of "$blessed/helper-launchd.plist")" ||
  fail "the SMJobBless job marks the install kind" "$(env_of "$blessed/helper-launchd.plist")"
pass "the job SMJobBless registers marks the helper as SMJobBless-installed"

adhoc=$test_tmp/adhoc
mkdir "$adhoc"
bash "$test_tmp/Packaging/helper-plists" "$adhoc" 7 1.0.0 >/dev/null ||
  fail "helper-plists writes the ad hoc Info.plist"
[[ ! -e $adhoc/helper-launchd.plist ]] || fail "an ad hoc build gets no SMJobBless job"
pass "an ad hoc build carries no SMJobBless job"

# A package's job is derived from the app's embedded plist. Even if that plist
# carried the marker, the derived job must not.
app="$test_tmp/$INSTALLER_APP_NAME.app"
mkdir -p "$app/Contents/Library/LaunchDaemons" "$app/Contents/Library/LaunchServices"
printf '#!/bin/sh\n' >"$app/Contents/Library/LaunchServices/$helper_id"
python3 - "$app/Contents/Library/LaunchDaemons/$helper_id.plist" "$helper_id" "$marker" <<'PY'
import plistlib, sys
plistlib.dump({
    "Label": sys.argv[2],
    "BundleProgram": "Contents/Library/LaunchServices/" + sys.argv[2],
    "MachServices": {sys.argv[2]: True},
    "UserName": "root",
    "EnvironmentVariables": {
        "OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT": "anchor apple generic",
        sys.argv[3]: "SMJobBless",
    },
}, open(sys.argv[1], "wb"))
PY
"$ROOT/Packaging/pkg/derive-daemon-plist" "$app" "$test_tmp/package.plist" "$test_tmp/helper-copy" >/dev/null ||
  fail "derive-daemon-plist derives the package's job"
derived=$(env_of "$test_tmp/package.plist")
! grep -Fq "$marker" <<<"$derived" || fail "a package's job never marks an SMJobBless install" "$derived"
grep -Fq OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT <<<"$derived" ||
  fail "a package's job keeps its client requirement" "$derived"
for builder in "$ROOT/Packaging/pkg/build-pkg.sh" "$ROOT/Packaging/build-developer-pkg.sh" \
  "$ROOT/Packaging/private-test/build-review-pkg.sh" "$ROOT/Packaging/private-test/build-tester-pkg.sh"; do
  ! grep -Fq "$marker" "$builder" || fail "$(basename "$builder") does not set the install-kind marker"
done
pass "no package's job claims an SMJobBless install"

# The helper reads the same name and value, and defaults to the install kind,
# not to where it runs.
identity=$ROOT/Sources/AuroraAppleInstaller/InstallerProductIdentity.swift
server=$ROOT/Sources/AuroraAppleInstaller/ClosedEngineHelperServer.swift
grep -Fq "helperInstallKindEnvironmentVariable = \"$marker\"" "$identity" ||
  fail "the helper reads the marker the SMJobBless job sets"
grep -Fq 'smJobBlessInstallKind = "SMJobBless"' "$identity" ||
  fail "the helper expects the value the SMJobBless job sets"
grep -Fq 'mayRetirePackageApps: Bool = ClosedEngineXPCServiceEndpoint.installedBySMJobBless()' "$server" ||
  fail "the helper's default comes from the install kind"
pass "the helper decides from the install kind"
