#!/bin/bash
# Build a signed + notarized macOS installer package for the Aurora Apple
# Silicon installer. The package installs the notarized app to /Applications and
# its privileged helper to /Library/PrivilegedHelperTools and a system
# LaunchDaemon to /Library/LaunchDaemons, then loads the daemon in its
# postinstall — so the recipient enters one admin password (the macOS installer
# prompt) and never touches Login Items.
#
# Usage: build-pkg.sh --app <signed .app> --version <x.y.z> --out <output.pkg> \
#          [--plist <daemon plist>]
#
# The system daemon plist is derived from the plist the app embeds
# (Contents/Library/LaunchDaemons), rewriting its bundle-relative BundleProgram
# into the absolute Program /Library/PrivilegedHelperTools/<helper identifier>,
# where the package installs a copy of the app's helper. The daemon runs as
# root, so it never starts a program from /Applications. Pass --plist only to
# supply a daemon plist that already carries that Program; it is validated the
# same way.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../identity.conf
source "$PKG_DIR/../identity.conf"
APP="" PLIST="" VERSION="" OUT=""
INSTALLER_ID="$INSTALLER_PKG_SIGNING_IDENTITY"
PKG_IDENTIFIER="$INSTALLER_PKG_IDENTIFIER"
SCRIPTS="$PKG_DIR/scripts"
DAEMON_PLIST_NAME="$INSTALLER_HELPER_IDENTIFIER.plist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --plist) PLIST="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --installer-identity) INSTALLER_ID="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
[[ -d "$APP" && -n "$VERSION" && -n "$OUT" ]] || {
  echo "usage: build-pkg.sh --app <app> --version <v> --out <pkg> [--plist <plist>]" >&2
  exit 64
}
[[ -z "$PLIST" || -f "$PLIST" ]] || { echo "build-pkg.sh: --plist is not a file: $PLIST" >&2; exit 64; }

work="$(mktemp -d /tmp/aurora-pkg.XXXXXX)"
trap 'rm -rf "$work"' EXIT
root="$work/root"
mkdir -p "$root/Applications" "$root/Library/LaunchDaemons" "$root/Library/PrivilegedHelperTools"
chmod 755 "$root/Library/PrivilegedHelperTools"

# Payload: the notarized app, its helper and the system daemon plist.
/usr/bin/ditto "$APP" "$root/Applications/$(basename "$APP")"

# Derive the daemon plist from the app's embedded copy (absolute Program in
# /Library/PrivilegedHelperTools) and stage the helper there, or validate a
# supplied plist the same way. A daemon whose Program is anything else, or
# points at nothing in the payload, is a build failure, not a warning.
daemon_plist="$work/$DAEMON_PLIST_NAME"
helper_program="/Library/PrivilegedHelperTools/$INSTALLER_HELPER_IDENTIFIER"
"$PKG_DIR/derive-daemon-plist" "$APP" "$daemon_plist" "$root$helper_program" >/dev/null
if [[ -n "$PLIST" ]]; then
  /bin/cp "$PLIST" "$daemon_plist"
fi
prog="$(/usr/bin/plutil -extract Program raw -o - "$daemon_plist" 2>/dev/null || true)"
[[ $prog == "$helper_program" ]] || {
  echo "build-pkg.sh: daemon Program must be $helper_program (got '${prog:-<missing>}')" >&2
  exit 65
}
[[ -f "$root$prog" && ! -L "$root$prog" ]] || {
  echo "build-pkg.sh: daemon Program is not in the payload: $prog" >&2
  exit 65
}
# The helper compiles this requirement at launch and exits EX_CONFIG when it
# cannot, and launchd then respawns it forever while the app waits on a reply
# that never comes. The repo template carries a placeholder that build-app.sh
# replaces in the app's embedded copy; a pkg built from the template itself
# shipped exactly that failure once, so refuse anything but a real requirement.
requirement="$(/usr/bin/plutil -extract EnvironmentVariables.OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT raw -o - "$daemon_plist" 2>/dev/null || true)"
case "$requirement" in
  "never")
    echo "build-pkg.sh: ad-hoc bundles require build-developer-pkg.sh to pin the final app identity" >&2
    exit 65
    ;;
  "" | *REPLACED_DURING_PACKAGING*)
    echo "build-pkg.sh: daemon plist has no client code-signing requirement (got '${requirement:-<missing>}'); use the app's embedded plist, not the repo template" >&2
    exit 65
    ;;
esac
/usr/bin/install -m 0644 "$daemon_plist" "$root/Library/LaunchDaemons/$DAEMON_PLIST_NAME"
echo "daemon client requirement: $requirement"
echo "daemon Program: $prog"

# Pin the app to /Applications. Without this, PackageKit "relocates" the
# install onto any existing copy of the bundle it can find anywhere on disk
# (it did exactly that onto a stale test copy in /Users/Shared), leaving
# /Applications empty and the daemon pointing at nothing.
component_plist="$work/component.plist"
/usr/bin/pkgbuild --analyze --root "$root" "$component_plist"
/usr/bin/plutil -replace 0.BundleIsRelocatable -bool false "$component_plist"

# postinstall reads the helper label and app name from the identity it ships with.
scripts="$work/scripts"
/usr/bin/ditto "$SCRIPTS" "$scripts"
/usr/bin/install -m 0644 "$PKG_DIR/../identity.conf" "$scripts/identity.conf"

echo "=== pkgbuild (component) ==="
comp="$work/component.pkg"
/usr/bin/pkgbuild \
  --root "$root" \
  --component-plist "$component_plist" \
  --scripts "$scripts" \
  --identifier "$PKG_IDENTIFIER" \
  --version "$VERSION" \
  --install-location / \
  --ownership recommended \
  "$comp"

echo "=== productbuild (signed distribution) ==="
# Installer asks for a running installer app, under either name, to be closed
# before it installs; otherwise the old app keeps running, postinstall has to
# leave it in place and the new app can't take the single-instance lease.
distribution="$work/distribution.xml"
/usr/bin/productbuild --synthesize --package "$comp" "$distribution"
"$PKG_DIR/add-must-close" "$distribution" "$PKG_IDENTIFIER" "$INSTALLER_APP_IDENTIFIER"
/usr/bin/productbuild \
  --distribution "$distribution" \
  --package-path "$work" \
  --identifier "$PKG_IDENTIFIER" \
  --version "$VERSION" \
  --sign "$INSTALLER_ID" \
  "$OUT"

echo "=== verify signature ==="
/usr/sbin/pkgutil --check-signature "$OUT" | head -6

echo "PKG_BUILT: $OUT"
echo "sha256: $(/usr/bin/shasum -a 256 "$OUT" | awk '{print $1}')"
