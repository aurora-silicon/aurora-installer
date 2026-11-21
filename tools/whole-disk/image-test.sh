#!/bin/bash
# End-to-end disk-image test of aurora-whole-disk (root, loop devices):
# a 4096-byte-sector GPT laid out like an Apple silicon Mac with macOS and
# Aurora (synthetic APFS containers, real FAT/ext4/btrfs), Recovery's removal
# simulated (partition deleted, its record written), then the real `claim`.
# Usage: sudo tools/whole-disk/image-test.sh <scratch dir> [log dir]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=${1:?scratch directory}
logs=${2:-$work}
[[ $(id -u) == 0 ]] || { echo 'needs root (loop devices, mkfs, mount)' >&2; exit 1; }
mkdir -p "$work" "$logs"
img=$work/disk.img
loop=
cleanup() {
  set +e
  mountpoint -q "$work/root" && umount "$work/root"
  mountpoint -q "$work/esp" && umount "$work/esp"
  [[ -n $loop ]] && losetup -d "$loop"
}
trap cleanup EXIT
rm -f "$img"
truncate -s 15G "$img"
loop=$(losetup --find --show --sector-size 4096 --partscan "$img")
tool=(python3 -I "$here/aurora_whole_disk.py" --chosen "$work/chosen" --disk "$loop")
python3 -I -c "import sys; sys.path.insert(0, '$repo/tests'); import whole_disk_fixtures as fx; print(fx.sfdisk_script(4096), end='')" |
  sfdisk --quiet "$loop"
partx -u "$loop" || true
udevadm settle
python3 -I - "$loop" "$repo/tests" <<'EOF'
import sys
sys.path.insert(0, sys.argv[2])
import whole_disk_fixtures as fx
for n, name in [(1, "isc"), (2, "macos"), (3, "stub"), (7, "recovery")]:
    with open(f"{sys.argv[1]}p{n}", "r+b") as f:
        f.write(fx.container(fx.CONTENTS[name]))
EOF
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
head -c 256M /dev/urandom > "$work/root/payload"
sum_before=$(sha256sum < "$work/root/payload")
sfdisk -d "$loop" > "$logs/gpt-before.txt"
{
  echo "== plan before removal (synthetic stub has no Aurora Recovery: must refuse, rc 3)"
  set +e; "${tool[@]}" plan; echo "rc=$?"; set -e
  echo "== claim before removal (nothing to claim)"
  "${tool[@]}" --esp "$work/esp" claim --root "$work/root" --dry-run
} > "$logs/before.txt" 2>&1
# Recovery's `aura remove-macos` (diskutil apfs deleteContainer) leaves the
# partition gone and writes this record on the ESP (MacOSRemoval.claimRecord).
python3 -I - "$loop" "$work/esp" <<'EOF'
import json, os, subprocess, sys
t = json.loads(subprocess.check_output(["sfdisk", "--json", sys.argv[1]]))["partitiontable"]
ss = t["sectorsize"]
p = {int(x["node"].rsplit("p", 1)[1]): x for x in t["partitions"]}
rec = {"schema": 1, "phase": "removed", "removedPartitionUUID": p[2]["uuid"],
       "removedContainerUUID": "22222222-2222-4222-8222-222222222222",
       "removedOffset": p[2]["start"] * ss, "removedSize": p[2]["size"] * ss,
       "freeOffset": (p[1]["start"] + p[1]["size"]) * ss,
       "freeSize": (p[3]["start"] - p[1]["start"] - p[1]["size"]) * ss,
       "installationStoreUUID": p[3]["uuid"], "espUUID": p[4]["uuid"],
       "removedAt": "2026-11-21T00:00:00Z"}
os.makedirs(f"{sys.argv[2]}/aurora/whole-disk", exist_ok=True)
with open(f"{sys.argv[2]}/aurora/whole-disk/removed.json", "w") as f:
    json.dump(rec, f, indent=2)
EOF
sfdisk --quiet --no-reread --no-tell-kernel --delete "$loop" 2
partx -d --nr 2 "$loop" || true
udevadm settle
size_before=$(btrfs filesystem show --raw "$work/root" | awk '/devid/ {s += $4} END {print s}')
{
  echo "== claim --dry-run"
  "${tool[@]}" --esp "$work/esp" claim --root "$work/root" --dry-run
  echo "== claim --yes"
  "${tool[@]}" --esp "$work/esp" claim --root "$work/root" --yes
  echo "== claim again (idempotent)"
  "${tool[@]}" --esp "$work/esp" claim --root "$work/root" --yes
  echo "== btrfs filesystem show"
  btrfs filesystem show "$work/root"
  echo "== fill past the old device (proves the new one takes data)"
  dd if=/dev/zero of="$work/root/fill" bs=1M count=5000 status=none conv=fsync
  btrfs device usage -b "$work/root"
  echo "== claimed.json"
  cat "$work/esp/aurora/whole-disk/claimed.json"
} > "$logs/claim.txt" 2>&1
sfdisk -d "$loop" > "$logs/gpt-after.txt"
size_after=$(btrfs filesystem show --raw "$work/root" | awk '/devid/ {s += $4} END {print s}')
sum_after=$(sha256sum < "$work/root/payload")
ndev=$(btrfs filesystem show "$work/root" | grep -c devid)
kept_before=$(grep -v -E '^(/dev/[a-z0-9]+p2 :|last-lba|label-id|device)' "$logs/gpt-before.txt" | sed 's/^.*: //' | sort)
kept_after=$(grep -v -E 'name="Aurora \(from macOS\)"|^(last-lba|label-id|device)' "$logs/gpt-after.txt" | sed 's/^.*: //' | sort)
result=PASS
[[ $ndev == 2 ]] || result="FAIL devices=$ndev"
(( size_after - size_before > 6000000000 )) || result="FAIL size $size_before -> $size_after"
[[ $sum_before == "$sum_after" ]] || result="FAIL payload changed"
[[ -f $work/esp/aurora/whole-disk/claimed.json && ! -f $work/esp/aurora/whole-disk/removed.json ]] || result="FAIL records"
[[ $kept_before == "$kept_after" ]] || result="FAIL kept partitions changed"
grep -q 'rc=3' "$logs/before.txt" || result="FAIL plan did not refuse without an owner"
grep -q 'already added' "$logs/claim.txt" || result="FAIL second claim not idempotent"
echo "$result: btrfs root $size_before -> $size_after bytes, $ndev devices, payload sha256 unchanged=$([[ $sum_before == "$sum_after" ]] && echo yes || echo no)" | tee "$logs/result.txt"
[[ $result == PASS ]]
