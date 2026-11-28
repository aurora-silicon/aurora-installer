#!/bin/bash
# aurora-restore-key's command line on Fixtures/RestoreImageKey/cli-archive.bin
# (cli.py): key-url, unwrap to a new 0600 file holding exactly the archive key,
# and no file at all when the output exists, is a symlink, or the archive or
# release key is refused. Usage: Tests/RestoreImageKeyTool.sh PATH_TO_TOOL
set -uo pipefail
tool=$1
fixtures="$(cd "$(dirname "$0")" && pwd)/Fixtures/RestoreImageKey"
archive="$fixtures/cli-archive.bin"
pem="$fixtures/cli-release-key.pem"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
failures=0
# check WHAT EXPECTED_RC REASON CMD...: the exit status must be EXPECTED_RC
# (the tool exits 1 for every refusal, 64 for usage; a signal or trap is a
# failure) and, unless REASON is empty, stderr must match the ERE REASON.
check() {
  local what=$1 expected=$2 reason=$3 rc=0
  shift 3
  "$@" >"$scratch/out" 2>"$scratch/err" || rc=$?
  if [[ $rc == "$expected" ]] && { [[ -z $reason ]] || grep -Eq "$reason" "$scratch/err"; }; then
    return 0
  fi
  echo "FAIL: $what: exit $rc, wanted $expected${reason:+ and /$reason/}: $(cat "$scratch/err")"
  failures=$((failures + 1))
}
absent() { [[ ! -e $1 && ! -L $1 ]] || { echo "FAIL: $2: $1 was created"; failures=$((failures + 1)); }; }
# A copy of FILE with byte OFFSET's low bit flipped.
flip() {
  local byte
  cp "$1" "$3"
  byte=$(od -An -tu1 -j "$2" -N1 "$1" | tr -d ' ')
  printf "\\$(printf '%03o' $((byte ^ 1)))" | dd of="$3" bs=1 seek="$2" conv=notrunc 2>/dev/null
}

check "no arguments" 64 usage "$tool"
check "unknown command" 64 usage "$tool" decrypt "$archive"
check "unwrap without OUTPUT" 64 usage "$tool" unwrap "$archive" "$pem"

check "key-url" 0 "" "$tool" key-url "$archive"
[[ $(cat "$scratch/out") == "https://wkms-public.apple.com/fcs-keys/$(printf 'A%.0s' {1..43})=" ]] ||
  { echo "FAIL: key-url printed $(cat "$scratch/out")"; failures=$((failures + 1)); }

key="$scratch/key"
check "unwrap" 0 "" "$tool" unwrap "$archive" "$pem" "$key"
# The Go fixtures' archive key is 32 bytes of 42 ('*').
printf '%.0s*' {1..32} >"$scratch/expected"
cmp -s "$key" "$scratch/expected" || { echo "FAIL: unwrap wrote another key"; failures=$((failures + 1)); }
[[ $(ls -l "$key" | cut -c1-10) == "-rw-------" ]] ||
  { echo "FAIL: key mode $(ls -l "$key" | cut -c1-10)"; failures=$((failures + 1)); }

# An existing OUTPUT is neither replaced nor changed.
printf 'keep' >"$scratch/existing"
check "unwrap over an existing file" 1 "File exists" "$tool" unwrap "$archive" "$pem" "$scratch/existing"
[[ $(cat "$scratch/existing") == keep ]] || { echo "FAIL: existing OUTPUT changed"; failures=$((failures + 1)); }
ln -s "$scratch/target" "$scratch/link"
check "unwrap through a symlink" 1 "File exists|symbolic link" "$tool" unwrap "$archive" "$pem" "$scratch/link"
absent "$scratch/target" "symlinked OUTPUT"
[[ -L $scratch/link ]] || { echo "FAIL: the symlink OUTPUT was replaced"; failures=$((failures + 1)); }

# Metadata length 0x150: salt at 348, root MAC at 380, encrypted root header
# at 412, cluster 0 header MAC at 460. Bytes 20 (the key URL entry's name)
# and 300 (the wrapped key's base64) are metadata, which the root MAC covers;
# the Swift check changes the HPKE ciphertext itself.
for at in 348 380 412 460 20 300; do
  flip "$archive" "$at" "$scratch/bent-$at"
  check "archive byte $at changed" 1 "authentication|invalidResponse" "$tool" unwrap "$scratch/bent-$at" "$pem" "$scratch/out-$at"
  absent "$scratch/out-$at" "archive byte $at changed"
done
head -c 300 "$archive" >"$scratch/short"
check "short archive" 1 invalidArchive "$tool" unwrap "$scratch/short" "$pem" "$scratch/out-short"
absent "$scratch/out-short" "short archive"
check "archive is a directory" 1 "can.t read|invalidArchive" "$tool" unwrap "$scratch" "$pem" "$scratch/out-dir"
absent "$scratch/out-dir" "archive is a directory"
check "missing archive" 1 "can.t read" "$tool" key-url "$scratch/none"

# A release key over 16 KiB is refused before it is parsed, even if it is a
# valid PEM followed by padding.
{ cat "$pem"; head -c 16384 /dev/zero | tr '\0' '\n'; } >"$scratch/big.pem"
check "release key over 16 KiB" 1 "16 KiB" "$tool" unwrap "$archive" "$scratch/big.pem" "$scratch/out-big"
absent "$scratch/out-big" "release key over 16 KiB"
# One base64 character in the key's scalar changed, so the scalar no longer
# matches the embedded public key.
awk 'NR == 2 { c = substr($0, 56, 1); $0 = substr($0, 1, 55) (c == "A" ? "B" : "A") substr($0, 57) } 1' \
  "$pem" >"$scratch/bent.pem"
check "damaged release key" 1 invalidPrivateKey "$tool" unwrap "$archive" "$scratch/bent.pem" "$scratch/out-pem"
absent "$scratch/out-pem" "damaged release key"

if ((failures > 0)); then exit 1; fi
echo "aurora-restore-key: all command line checks passed"
