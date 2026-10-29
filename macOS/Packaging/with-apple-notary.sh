#!/bin/bash
# Credentials live only in the enclosing signing wrapper's temporary keychain.
set -euo pipefail
fail() { echo "apple-notary: $*" >&2; exit 1; }
[[ $(uname -s) == Darwin && ${GITHUB_ACTIONS:-} == true ]] || fail "requires an isolated macOS Actions runner"
(( $# > 0 )) || fail "a command is required"
: "${RUNNER_TEMP:?}" "${AURORA_SIGNING_KEYCHAIN:?}" "${APPLE_NOTARY_KEY_BASE64:?}"
[[ -f $AURORA_SIGNING_KEYCHAIN && ! -L $AURORA_SIGNING_KEYCHAIN ]] || fail "temporary signing keychain is unavailable"
[[ ${APPLE_NOTARY_KEY_ID:-} =~ ^[A-Z0-9]{10}$ ]] || fail "invalid key identifier"
[[ ${APPLE_NOTARY_ISSUER_ID:-} =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "invalid issuer"
umask 077
scratch=$(mktemp -d "$RUNNER_TEMP/aurora-notary.XXXXXX")
cleanup() {
  result=$?
  trap - EXIT HUP INT TERM
  if ! rm -rf -- "$scratch" || [[ -e $scratch ]]; then
    echo 'apple-notary: credential cleanup failed' >&2
    exit 1
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s' "$APPLE_NOTARY_KEY_BASE64" | base64 --decode > "$scratch/key.p8"
export AURORA_NOTARY_PROFILE=aurora-release
export AURORA_NOTARY_KEYCHAIN="$AURORA_SIGNING_KEYCHAIN"
xcrun notarytool store-credentials "$AURORA_NOTARY_PROFILE" \
  --keychain "$AURORA_NOTARY_KEYCHAIN" --key "$scratch/key.p8" \
  --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID"
rm "$scratch/key.p8"
unset APPLE_NOTARY_KEY_BASE64 APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID
"$@"
