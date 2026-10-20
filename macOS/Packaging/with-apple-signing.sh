#!/bin/bash
# CI-only, temporary signing identity. Never retain keychains or credentials
# in build artifacts; the called command receives only the identity and team.
set -euo pipefail
fail() { echo "apple-signing: $*" >&2; exit 1; }
[[ $(uname -s) == Darwin && ${GITHUB_ACTIONS:-} == true ]] || fail 'requires an isolated macOS Actions runner'
(( $# > 0 )) || fail 'a command is required'
: "${RUNNER_TEMP:?}" "${APPLE_CERTIFICATE_P12_BASE64:?}" "${APPLE_CERTIFICATE_PASSWORD:?}"
[[ ${APPLE_TEAM_ID:-} =~ ^[A-Z0-9]{10}$ ]] || fail 'invalid team identifier'
[[ ${APPLE_SIGNING_IDENTITY:-} =~ ^[A-Fa-f0-9]{40}$ ]] || fail 'invalid certificate fingerprint'
keychain_timeout=${AURORA_SIGNING_KEYCHAIN_TIMEOUT:-1200}
[[ $keychain_timeout =~ ^[1-9][0-9]{0,3}$ ]] && (( keychain_timeout <= 7200 )) \
  || fail 'invalid signing keychain timeout'
umask 077
original_search_list=$(security list-keychains -d user) || fail 'cannot read the keychain search list'
previous=()
while IFS= read -r line; do
  path=${line#*\"}
  path=${path%\"*}
  [[ $path == /* ]] || fail 'cannot preserve the keychain search list'
  previous+=("$path")
done <<< "$original_search_list"
(( ${#previous[@]} > 0 )) || fail 'the original keychain search list is empty'
scratch=$(mktemp -d "$RUNNER_TEMP/aurora-signing.XXXXXX")
keychain="$scratch/signing.keychain-db"
cleanup() {
  result=$?
  trap - EXIT HUP INT TERM
  cleanup_failed=0
  if ! security list-keychains -d user -s "${previous[@]}" >/dev/null 2>&1; then
    echo 'apple-signing: cannot restore the original keychain search list' >&2
    cleanup_failed=1
  elif ! restored_search_list=$(security list-keychains -d user) || [[ $restored_search_list != "$original_search_list" ]]; then
    echo 'apple-signing: keychain search list restoration did not verify' >&2
    cleanup_failed=1
  fi
  if [[ -e $keychain ]] && ! security delete-keychain "$keychain" >/dev/null 2>&1; then
    echo 'apple-signing: cannot delete the temporary keychain' >&2
    cleanup_failed=1
  fi
  if ! rm -rf -- "$scratch" || [[ -e $scratch ]]; then
    echo 'apple-signing: cannot retire temporary signing files' >&2
    cleanup_failed=1
  fi
  if (( result == 0 && cleanup_failed != 0 )); then
    result=1
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
keychain_password=$(openssl rand -hex 32)
printf '::add-mask::%s\n' "$keychain_password"
printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode > "$scratch/signing.p12"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut "$keychain_timeout" "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$scratch/signing.p12" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" \
  -t cert -f pkcs12 -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "${previous[@]}"
security find-identity -v -p codesigning "$keychain" | grep -Fi "$APPLE_SIGNING_IDENTITY" >/dev/null \
  || fail 'the configured signing identity is unavailable'
export AURORA_SIGNING_KEYCHAIN="$keychain"
export OMARCHY_APP_SIGNING_IDENTITY="$APPLE_SIGNING_IDENTITY"
export OMARCHY_TEAM_ID="$APPLE_TEAM_ID"
unset APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD keychain_password
"$@"
