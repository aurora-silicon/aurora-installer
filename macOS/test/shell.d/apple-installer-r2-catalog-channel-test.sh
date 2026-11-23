#!/bin/bash

source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

require_command python3

PUBLISHER="$ROOT/scripts/publish-m1-release"
[[ -f $PUBLISHER ]] || fail "publish-m1-release exists"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

BUCKET_DIR="$WORK/bucket"
BIN_DIR="$WORK/bin"
CALLS="$WORK/calls.log"
mkdir -p "$BUCKET_DIR" "$BIN_DIR"
: >"$CALLS"

# The tag is pushed; nothing else reaches git.
cat >"$BIN_DIR/git" <<'SHIM'
#!/bin/bash
printf 'git %s\n' "$*" >>"$CALLS"
[[ $1 == "ls-remote" ]] && exit 0
exit 64
SHIM

# A bucket-backed aws shim: object keys become paths under the bucket.
cat >"$BIN_DIR/aws" <<'SHIM'
#!/bin/bash
printf 'aws %s\n' "$*" >>"$CALLS"
if [[ $1 == "s3api" && $2 == "head-object" ]]; then
  key=""
  while (( $# > 0 )); do
    [[ $1 == "--key" ]] && key=$2
    shift
  done
  [[ -f $BUCKET_DIR/$key ]] || exit 254
  wc -c <"$BUCKET_DIR/$key" | tr -d ' '
  exit 0
fi
if [[ $1 == "s3" && $2 == "cp" ]]; then
  key=${4#s3://*/}
  mkdir -p "$BUCKET_DIR/$(dirname "$key")"
  cp "$3" "$BUCKET_DIR/$key"
  exit 0
fi
exit 64
SHIM

# The public base serves the bucket's prefix, so read-back verification runs.
cat >"$BIN_DIR/curl" <<'SHIM'
#!/bin/bash
printf 'curl %s\n' "$*" >>"$CALLS"
url=""
for argument in "$@"; do
  [[ $argument == http* ]] && url=$argument
done
file=$BUCKET_DIR/$PREFIX/${url#"$BASE_URL"/}
[[ -f $file ]] || exit 22
cat "$file"
SHIM

if ! command -v shasum >/dev/null; then
  cat >"$BIN_DIR/shasum" <<'SHIM'
#!/bin/bash
file="-"
while (( $# > 0 )); do
  case $1 in
    -a) shift 2 ;;
    *) file=$1; shift ;;
  esac
done
sha256sum "$file"
SHIM
fi
chmod +x "$BIN_DIR"/*

TAG=os-v4.0.2-mac.1.20260920
BASE_URL=https://downloads.example.test/native/releases/$TAG
PREFIX=native/releases/$TAG
export PATH="$BIN_DIR:$PATH" BUCKET_DIR CALLS BASE_URL PREFIX
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test

RELEASE="$WORK/release"
CATALOGS="$WORK/catalogs"
mkdir -p "$RELEASE" "$CATALOGS"
head -c 128 /dev/zero >"$RELEASE/payload.zip"
(cd "$RELEASE" && shasum -a 256 payload.zip >SHA256SUMS)
printf 'TAG=%s\nBASE_URL=%s\nRELEASE_ASSETS="payload.zip"\n' "$TAG" "$BASE_URL" >"$RELEASE/release-urls.env"

# envelope FILE [CHANNEL]: a catalog envelope whose catalog declares CHANNEL,
# or no channel when CHANNEL is empty. The signature is not checked here.
envelope() {
  python3 - "$1" "${2:-}" <<'PY'
import base64, json, sys
output, channel = sys.argv[1:3]
catalog = {"schemaVersion": 5, "sequence": 1, "issuedAt": "2026-09-20T00:00:00Z", "models": []}
if channel:
    catalog["channel"] = channel
json.dump({"schema_version": 1,
           "catalog": base64.b64encode(json.dumps(catalog).encode()).decode(),
           "signature": base64.b64encode(b"\0" * 64).decode()}, open(output, "w"))
PY
}
printf '{}' >"$CATALOGS/catalog.json"
head -c 64 /dev/zero >"$CATALOGS/catalog.json.sig"
envelope "$CATALOGS/catalog.signed.json" testing

publish() {
  AURORA_PUBLISH_ASSUME_YES=$TAG "$PUBLISHER" publish-r2 --dir "$RELEASE" --tag "$TAG" \
    --bucket test-bucket --endpoint https://example.r2.cloudflarestorage.com \
    --base-url "$BASE_URL" --prefix "$PREFIX" --catalog-dir "$CATALOGS"
}

# --- a per-channel catalog that declares another channel, or none, is not uploaded
for declared in rc "" testing; do
  rm -f "$CATALOGS"/catalog.*.signed.json
  envelope "$CATALOGS/catalog.stable.signed.json" "$declared"
  envelope "$CATALOGS/catalog.rc.signed.json" rc
  if publish >"$WORK/mislabelled.log" 2>&1; then
    fail "catalog.stable.signed.json declaring '${declared:-nothing}' is refused"
  fi
  grep -q "catalog.stable.signed.json declares ${declared:-no channel}; it must be signed with \"channel\": \"stable\"" \
    "$WORK/mislabelled.log" || fail "the refusal names the declared channel" "$(cat "$WORK/mislabelled.log")"
  grep -q '^aws s3 cp ' "$CALLS" && fail "nothing is uploaded before every catalog is checked" "$(cat "$CALLS")"
  [[ -z $(find "$BUCKET_DIR" -type f) ]] || fail "the bucket is untouched"
done
pass "a per-channel catalog that declares another channel or none uploads nothing"

printf 'not an envelope' >"$CATALOGS/catalog.stable.signed.json"
if publish >"$WORK/unreadable.log" 2>&1; then
  fail "an unreadable per-channel catalog is refused"
fi
grep -q "catalog.stable.signed.json is not a readable catalog envelope" "$WORK/unreadable.log" ||
  fail "the refusal names the unreadable catalog" "$(cat "$WORK/unreadable.log")"
grep -q '^aws s3 cp ' "$CALLS" && fail "an unreadable catalog uploads nothing"
pass "an unreadable per-channel catalog uploads nothing"

# --- catalogs that declare their own channels are uploaded and read back -----
envelope "$CATALOGS/catalog.stable.signed.json" stable
publish >"$WORK/publish.log" 2>&1 || fail "a correctly labelled set publishes" "$(cat "$WORK/publish.log")"
for asset in payload.zip catalog.json catalog.json.sig catalog.signed.json \
  catalog.stable.signed.json catalog.rc.signed.json; do
  [[ -f $BUCKET_DIR/$PREFIX/$asset ]] || fail "$asset is uploaded" "$(cat "$WORK/publish.log")"
  grep -q "verified $BASE_URL/$asset" "$WORK/publish.log" || fail "$asset is read back"
done
pass "per-channel catalogs that declare their own channel are uploaded and verified"
