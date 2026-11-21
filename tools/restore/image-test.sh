#!/bin/bash
# End-to-end disk-image test of aurora-restore (root, loop devices, network
# for Apple's catalog): a 4096-byte-sector GPT laid out like an Apple silicon
# Mac with macOS and Aurora (synthetic APFS containers, real FAT/ext4/btrfs
# with a 100 GiB sparse root), then the real `plan`, `apply` (btrfs and
# partition shrink), `cancel` and `apply --replace`.
# Usage: sudo tools/restore/image-test.sh <scratch dir> [log dir] [version]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=${1:?scratch directory}
logs=${2:-$work}
version=${3:-27.2.1}
[[ $(id -u) == 0 ]] || { echo 'needs root (loop devices, mkfs, mount)' >&2; exit 1; }
mkdir -p "$work" "$logs"
img=$work/disk.img
loop=
cleanup() {
  set +e
  mountpoint -q "$work/root" && umount "$work/root"
  mountpoint -q "$work/esp" && umount "$work/esp"
  [[ -n $loop ]] && losetup -d "$loop"
  rm -f "$img"
}
trap cleanup EXIT
rm -f "$img"
truncate -s $(( 112640 + 2 ))M "$img"  # the layout below + GPT
loop=$(losetup --find --show --sector-size 4096 --partscan "$img")
tool=(python3 -I "$here/aurora_restore.py" --chosen "$work/chosen" --disk "$loop" --board J314sAP
      --esp "$work/esp" --root "$work/root" --cache "$work/cache")
python3 -I - "$repo/tests" <<'PY' | sfdisk --quiet "$loop"
import sys
sys.path.insert(0, sys.argv[1])
import whole_disk_fixtures as fx
layout = [(n, t, 100 * 1024 if n == "root" else m) for n, t, m in fx.LAYOUT]
print(fx.sfdisk_script(4096, layout), end="")
PY
partx -u "$loop" || true
udevadm settle
python3 -I - "$loop" "$repo/tests" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
import whole_disk_fixtures as fx
for n, name in [(1, "isc"), (2, "macos"), (3, "stub"), (7, "recovery")]:
    with open(f"{sys.argv[1]}p{n}", "r+b") as f:
        f.write(fx.container(fx.CONTENTS[name]))
PY
mkfs.vfat -F 32 -S 4096 "${loop}p4" >/dev/null
mkfs.ext4 -q -F "${loop}p5"
mkfs.btrfs -q -f "${loop}p6"
mkdir -p "$work/root" "$work/esp" "$work/chosen"
mount "${loop}p6" "$work/root"
mount "${loop}p4" "$work/esp"
esp_uuid=$(sfdisk --part-uuid "$loop" 4)
printf '%s\0' "${esp_uuid,,}" > "$work/chosen/asahi,efi-system-partition"
printf '0E3F2FC4-18DE-42ED-955F-2CF407EB27E2\0' > "$work/chosen/apfs-preboot-uuid"
printf '26.6.2\0' > "$work/chosen/asahi,system-fw-version"
printf '13.5\0' > "$work/chosen/asahi,os-fw-version"
printf 'mBoot-18000.161.10\0' > "$work/chosen/asahi,iboot1-version"
head -c 1G /dev/urandom > "$work/root/payload"
sync
sum_before=$(sha256sum < "$work/root/payload")
sfdisk -d "$loop" > "$logs/gpt-before.txt"
{
  echo "== list"
  "${tool[@]}" list
  echo "== plan $version --show-script"
  "${tool[@]}" plan "$version" --show-script
  echo "== apply --dry-run"
  "${tool[@]}" apply "$version" --dry-run
} > "$logs/plan.txt" 2>&1
sfdisk -d "$loop" > "$logs/gpt-after-dryrun.txt"
cmp -s <(grep -v '^device' "$logs/gpt-before.txt") <(grep -v '^device' "$logs/gpt-after-dryrun.txt") \
  || { echo "FAIL: dry run changed the disk" | tee "$logs/result.txt"; exit 1; }
{
  echo "== apply (wrong phrase: must change nothing)"
  set +e; echo "yes" | "${tool[@]}" apply "$version"; echo "rc=$?"; set -e
  echo "== apply --yes"
  "${tool[@]}" apply "$version" --yes
  echo "== btrfs filesystem show"
  btrfs filesystem show --raw "$work/root"
  echo "== free space"
  sfdisk -F "$loop"
  echo "== request.json"
  cat "$work/esp/aurora/restore/request.json"
  echo
  echo "== plan again (the gap is there now: no shrink)"
  "${tool[@]}" plan "$version" --no-check
} > "$logs/apply.txt" 2>&1
sfdisk -d "$loop" > "$logs/gpt-after-apply.txt"
sum_after=$(sha256sum < "$work/root/payload")
part=$(blockdev --getsize64 "${loop}p6")
dev=$(btrfs filesystem show --raw "$work/root" | awk '/devid/ {print $4}')
gapline=$(sfdisk -F "$loop" | awk '/^ *[0-9]+ +[0-9]+ +[0-9]+/ {print $4; exit}')
sh -n "$work/esp/aurora/restore/restore.sh"
{
  echo "== cancel"
  "${tool[@]}" cancel
  echo "== apply --replace --yes"
  "${tool[@]}" apply "$version" --replace --yes --no-check
  echo "== request.json (replace)"
  cat "$work/esp/aurora/restore/request.json"
} > "$logs/replace.txt" 2>&1
sfdisk -d "$loop" > "$logs/gpt-after-replace.txt"
cp "$work/esp/aurora/restore/request.json" "$logs/request-replace.json"
{
  echo "== cancel --regrow --dry-run"
  "${tool[@]}" cancel --regrow --dry-run
  echo "== cancel --regrow"
  "${tool[@]}" cancel --regrow
  btrfs filesystem show --raw "$work/root"
  sfdisk -F "$loop"
} > "$logs/regrow.txt" 2>&1
sfdisk -d "$loop" > "$logs/gpt-after-regrow.txt"
sum_regrow=$(sha256sum < "$work/root/payload")
part_regrow=$(blockdev --getsize64 "${loop}p6")
dev_regrow=$(btrfs filesystem show --raw "$work/root" | awk '/devid/ {print $4}')
result=PASS
grep -q 'rc=1' "$logs/apply.txt" || result="FAIL wrong phrase was accepted"
[[ $sum_before == "$sum_after" ]] || result="FAIL payload changed"
(( dev <= part )) || result="FAIL btrfs device $dev > partition $part"
python3 -I - "$logs" "$logs/request-replace.json" <<'PY' || result="FAIL request/partition table mismatch"
import json, sys
logs, req = sys.argv[1:]
r = json.load(open(req))
assert r["mode"] == "replace" and [d["node"][-2:] for d in r["delete"]] == ["p4", "p5", "p6"], r["delete"]
assert r["shrink"] is None
PY
cmp -s <(grep -v '^device' "$logs/gpt-after-apply.txt") <(grep -v '^device' "$logs/gpt-after-replace.txt") \
  || result="FAIL replace changed the partition table in Linux"
[[ $sum_before == "$sum_regrow" ]] || result="FAIL payload changed by regrow"
(( part_regrow == 100 * 1073741824 && dev_regrow == part_regrow )) || result="FAIL regrow: partition $part_regrow btrfs $dev_regrow"
[[ ! -e $work/esp/aurora/restore/request.json ]] || result="FAIL request still there after cancel"
cmp -s <(grep -v '^device' "$logs/gpt-before.txt") <(grep -v '^device' "$logs/gpt-after-regrow.txt") \
  || result="FAIL partition table after regrow differs from the start"
echo "$result: root partition $(( part / 1048576 )) MiB after shrink (btrfs $(( dev / 1048576 )) MiB), first free gap $gapline, payload sha256 unchanged=$([[ $sum_before == "$sum_after" && $sum_before == "$sum_regrow" ]] && echo yes || echo no), regrown to $(( part_regrow / 1048576 )) MiB" | tee "$logs/result.txt"
[[ $result == PASS ]]
