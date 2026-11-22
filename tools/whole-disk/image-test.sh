#!/bin/bash
# End-to-end disk-image test of aurora-whole-disk (root, loop devices):
# a 4096-byte-sector GPT laid out like an Apple silicon Mac with macOS and
# Aurora (synthetic APFS containers, real FAT/ext4/btrfs), Recovery's removal
# simulated (partition deleted, its record written), then the real `claim`.
# Usage: sudo tools/whole-disk/image-test.sh <scratch dir> [log dir] [mode]
# Modes:
#   fresh, interrupted  claim without `move` (the space becomes a second btrfs
#     device). interrupted: the partition is already added (a claim that
#     stopped right after `sfdisk --append`); claim must finish on it. Both
#     also restore removed.json after the claim (a stop between writing
#     claimed.json and removing removed.json) and check the next claim only
#     tidies up.
#   v2  `move` (ESP and /boot unmounted, as at start) then `claim`: the
#     normal layout again, one root partition.
#   v2-stop:<point>  the same, killed (SIGKILL) at <point>, then a simulated
#     restart (move, mounts, claim) must end the same.
#   v2-interrupted  v2-stop at every point, each on a fresh image.
#   v2-refuse  the root partition is named by PARTUUID in fstab: `move`
#     refuses and changes nothing, then the fresh-mode claim runs.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=${1:?scratch directory}
logs=${2:-$work}
mode=${3:-fresh}
stop=
case $mode in
  fresh | interrupted | v2 | v2-refuse | v2-interrupted) ;;
  v2-stop:*) stop=${mode#v2-stop:} ;;
  *) echo "mode: fresh, interrupted, v2, v2-stop:<point>, v2-interrupted or v2-refuse" >&2; exit 1 ;;
esac
STOP_POINTS=(copied-stub table-stub moved-stub copied-esp table-esp moved-esp copied-boot
  table-boot moved-boot root-appended root-added root-removed root-merged grown)
if [[ $mode == v2-interrupted ]]; then
  mkdir -p "$logs"
  : > "$logs/result.txt"
  rc=0
  for point in "${STOP_POINTS[@]}"; do
    timeout 900 "$0" "$work" "$logs/stop-$point" "v2-stop:$point" > "$logs/stop-$point.out" 2>&1 || rc=1
    tail -n 1 "$logs/stop-$point.out" | tee -a "$logs/result.txt"
  done
  echo "v2-interrupted: $( ((rc == 0)) && echo PASS || echo FAIL) (${#STOP_POINTS[@]} stop points)" |
    tee -a "$logs/result.txt"
  exit $rc
fi
[[ $(id -u) == 0 ]] || { echo 'needs root (loop devices, mkfs, mount)' >&2; exit 1; }
mkdir -p "$work" "$logs"
img=$work/disk.img
loop=
cleanup() {
  set +e
  for m in root esp boot run/esp; do mountpoint -q "$work/$m" && umount "$work/$m"; done
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
# Real-ish contents: random bytes in the stub after its container blocks,
# files on the ESP, /boot and root, root's fstab by file-system UUID.
dd if=/dev/urandom of="${loop}p3" bs=1M seek=1 count=64 conv=notrunc,fsync status=none
mkdir -p "$work/esp/EFI/BOOT" "$work/esp/m1n1" "$work/esp/vendorfw" "$work/boot"
head -c 2M /dev/urandom > "$work/esp/EFI/BOOT/BOOTAA64.EFI"
head -c 1M /dev/urandom > "$work/esp/m1n1/boot.bin"
head -c 8M /dev/urandom > "$work/esp/vendorfw/firmware.cpio"
mount "${loop}p5" "$work/boot"
mkdir -p "$work/boot/loader/entries"
head -c 16M /dev/urandom > "$work/boot/vmlinuz-test"
head -c 32M /dev/urandom > "$work/boot/initramfs-test.img"
root_fs=$(findmnt -n -o UUID --mountpoint "$work/root")
echo "options root=UUID=$root_fs rootflags=subvol=/ rw" > "$work/boot/loader/entries/test.conf"
umount "$work/boot"
mkdir -p "$work/root/etc" "$work/root/data"
cat > "$work/root/etc/fstab" <<FSTAB
UUID=$root_fs / btrfs defaults 0 0
UUID=$(blkid -p -o value -s UUID "${loop}p5") /boot ext4 defaults 1 2
UUID=$(blkid -p -o value -s UUID "${loop}p4") /boot/efi vfat umask=0077 0 2
FSTAB
for i in 1 2 3 4 5 6 7 8; do head -c 4M /dev/urandom > "$work/root/data/f$i"; done
(cd "$work/root" && sha256sum payload data/* etc/fstab > "$work/root-sums.txt")
sync
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
cp "$work/esp/aurora/whole-disk/removed.json" "$work/removed.json.copy"
move=("${tool[@]}" --run-dir "$work/run" move --root "$work/root")
if [[ $mode == v2* ]]; then
  # Before: what must survive the moves, read with nothing mounted but root.
  (cd "$work/esp" && find . -path ./aurora -prune -o -type f -print0 | sort -z | xargs -0 sha256sum) \
    > "$work/esp-sums.txt"
  umount "$work/esp"
  declare -A sha_before
  for n in 3 5; do sha_before[$n]=$(timeout 300 sha256sum < "${loop}p$n"); done
  ids_before=$(sfdisk --json "$loop" | python3 -I -c '
import json, sys
t = json.load(sys.stdin)["partitiontable"]
for p in t["partitions"]:
    print(p.get("name", ""), p["uuid"], p["type"], p.get("attrs", ""))' | sort)
  old_root=$(sfdisk --json "$loop" | python3 -I -c '
import json, sys
p = {x["node"]: x for x in json.load(sys.stdin)["partitiontable"]["partitions"]}
print(p[sys.argv[1]]["size"] * 4096)' "${loop}p6")
  hole=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["freeSize"])' \
    "$work/removed.json.copy")
  if [[ $mode == v2-refuse ]]; then
    echo "PARTUUID=$(sfdisk --part-uuid "$loop" 6) / btrfs defaults 0 0" >> "$work/root/etc/fstab"
    sfdisk -d "$loop" > "$work/gpt-pre-move.txt"
    {
      echo "== move with the root partition named by PARTUUID in fstab (must refuse, change nothing)"
      timeout 600 "${move[@]}" --yes; echo "rc=$?"
    } > "$logs/move-refuse.txt" 2>&1
    sfdisk -d "$loop" | cmp -s - "$work/gpt-pre-move.txt" && echo "gpt unchanged" >> "$logs/move-refuse.txt"
    mount "${loop}p4" "$work/esp"
    mode=fresh  # then the space is added as a second device, the v1 way
  fi
fi
if [[ $mode == v2* ]]; then
  # One start: move (ESP and /boot not mounted), then the system mounts
  # them, then claim. $1: stop point or empty.
  boot_once() {
    local at=$1 rc
    echo "== move --yes${at:+ (stop at $at)}"
    set +e
    AURORA_WHOLE_DISK_TEST_STOP=$at timeout 900 "${move[@]}" --yes; rc=$?
    set -e
    echo "rc=$rc"
    if [[ -n $at && $rc == 137 ]]; then return 137; fi
    ((rc == 0)) || return $rc
    mount "${loop}p4" "$work/esp"
    mount -o ro,noload "${loop}p5" "$work/boot"
    echo "== claim --dry-run"
    timeout 300 "${tool[@]}" --esp "$work/esp" claim --root "$work/root" --dry-run
    echo "== claim --yes${at:+ (stop at $at)}"
    set +e
    AURORA_WHOLE_DISK_TEST_STOP=$at timeout 1800 "${tool[@]}" --esp "$work/esp" claim --root "$work/root" --yes
    rc=$?
    set -e
    echo "rc=$rc"
    return $rc
  }
  restart() {
    # What a restart does to mounts; the kernel's partitions stay as the
    # tool left them (it re-reads what differs from the GPT itself).
    for m in esp boot; do mountpoint -q "$work/$m" && umount "$work/$m"; done
    return 0
  }
  {
    echo "== mode $mode"
    echo "== move --dry-run"
    timeout 300 "${move[@]}" --dry-run
    boot_once "$stop"; rc=$?
    if [[ -n $stop ]]; then
      [[ $rc == 137 ]] && echo "killed at $stop" || echo "NOT killed at $stop (rc=$rc)"
      restart
      echo "== restart after the stop"
      boot_once "" || echo "STEP FAILED: restart rc=$?"
    elif ((rc != 0)); then
      echo "STEP FAILED: start rc=$rc"
    fi
    echo "== claim again (idempotent)"
    timeout 300 "${tool[@]}" --esp "$work/esp" claim --root "$work/root" --yes || echo "STEP FAILED: claim again"
    restart
    echo "== move at the next start (nothing to do)"
    timeout 300 "${move[@]}" --yes || echo "STEP FAILED: move again"
    mount "${loop}p4" "$work/esp"
    echo "== claimed.json"
    cat "$work/esp/aurora/whole-disk/claimed.json"
    echo "== btrfs filesystem show"
    btrfs filesystem show --raw "$work/root"
    echo "== btrfs scrub"
    timeout 600 btrfs scrub start -B "$work/root"
  } > "$logs/claim.txt" 2>&1 || { echo "FAIL ($mode): see $logs/claim.txt" | tee "$logs/result.txt"; exit 1; }
  sfdisk -d "$loop" > "$logs/gpt-after.txt"
  result=PASS
  layout=$(sfdisk --json "$loop" | python3 -I -c '
import json, sys
t = json.load(sys.stdin)["partitiontable"]
ps = sorted(t["partitions"], key=lambda p: p["start"])
print(" ".join(p.get("name", "?") for p in ps))
gaps = [b["start"] - a["start"] - a["size"] for a, b in zip(ps, ps[1:])]
print(max(gaps) * t["sectorsize"])
root = next(p for p in ps if p.get("name") == "root")
print(root["node"], root["size"] * t["sectorsize"])')
  order=$(sed -n 1p <<< "$layout"); maxgap=$(sed -n 2p <<< "$layout")
  root_node=$(sed -n 3p <<< "$layout" | cut -d' ' -f1); root_size=$(sed -n 3p <<< "$layout" | cut -d' ' -f2)
  [[ $order == "isc stub esp boot root recovery" ]] || result="FAIL order: $order"
  (( maxgap < 1048576 )) || result="FAIL gap of $maxgap bytes"
  ids_after=$(sfdisk --json "$loop" | python3 -I -c '
import json, sys
t = json.load(sys.stdin)["partitiontable"]
for p in t["partitions"]:
    print(p.get("name", ""), p["uuid"], p["type"], p.get("attrs", ""))' | sort)
  [[ $ids_after == "$(grep -v '^macos ' <<< "$ids_before")" ]] || result="FAIL GPT UUIDs/types/names changed"
  umount "$work/esp"
  for n in 3 5; do
    [[ $(timeout 300 sha256sum < "${loop}p$n") == "${sha_before[$n]}" ]] || result="FAIL p$n bytes changed"
  done
  fsck.vfat -n "${loop}p4" > "$logs/fsck-esp.txt" 2>&1 || result="FAIL fsck.vfat"
  e2fsck -fn "${loop}p5" > "$logs/fsck-boot.txt" 2>&1 || result="FAIL e2fsck /boot"
  mount -o ro "${loop}p4" "$work/esp"
  (cd "$work/esp" && sha256sum -c --quiet "$work/esp-sums.txt") > "$logs/esp-sums-check.txt" 2>&1 ||
    result="FAIL ESP files"
  [[ -f $work/esp/aurora/whole-disk/claimed.json && ! -f $work/esp/aurora/whole-disk/removed.json ]] ||
    result="FAIL records"
  grep -q '"layout": "one-root"' "$work/esp/aurora/whole-disk/claimed.json" || result="FAIL layout record"
  umount "$work/esp"
  ndev=$(btrfs filesystem show "$work/root" | grep -c devid)
  size_after=$(btrfs filesystem show --raw "$work/root" | awk '/devid/ {s += $4} END {print s}')
  [[ $ndev == 1 ]] || result="FAIL devices=$ndev"
  (( size_after == root_size )) || result="FAIL btrfs $size_after != partition $root_size"
  (( root_size == old_root + hole )) || result="FAIL root $root_size != $old_root + $hole"
  [[ $(btrfs filesystem show "$work/root" | awk '/devid/ {print $NF}') == "$root_node" ]] ||
    result="FAIL root device"
  ! grep -q 'STEP FAILED' "$logs/claim.txt" || result="FAIL $(grep -m1 'STEP FAILED' "$logs/claim.txt")"
  grep -q 'already added' "$logs/claim.txt" || result="FAIL second claim not idempotent"
  grep -q 'Nothing to move' "$logs/claim.txt" || result="FAIL move after the claim"
  grep -q 'no errors found' "$logs/claim.txt" || result="FAIL scrub"
  if [[ -n $stop ]]; then
    grep -q "killed at $stop" "$logs/claim.txt" || result="FAIL not killed at $stop"
  fi
  # A real restart: detach, attach again, mount root from the table alone.
  umount "$work/root"
  losetup -d "$loop"; loop=
  loop=$(losetup --find --show --sector-size 4096 --partscan "$img")
  udevadm settle
  sfdisk -d "$loop" > "$logs/gpt-reattached.txt"
  rnode=$(sfdisk --json "$loop" | python3 -I -c '
import json, sys
print(next(p["node"] for p in json.load(sys.stdin)["partitiontable"]["partitions"] if p.get("name") == "root"))')
  btrfs device scan "$rnode" > /dev/null
  mount "$rnode" "$work/root"
  (cd "$work/root" && sha256sum -c --quiet "$work/root-sums.txt") > "$logs/root-sums-check.txt" 2>&1 ||
    result="FAIL root data after reattach"
  [[ $(btrfs filesystem show "$work/root" | grep -c devid) == 1 ]] || result="FAIL devices after reattach"
  echo "$result ($mode): btrfs root $size_before -> $size_after bytes (+$((size_after - size_before)), freed $hole), $ndev device, layout '$order', max gap $maxgap, stub/boot sha256 unchanged, ESP files unchanged, root data sha256 OK after reattach" | tee "$logs/result.txt"
  [[ $result == PASS ]]
  exit
fi
if [[ $mode == interrupted ]]; then
  # What the claim's own sfdisk --append writes (1 MiB aligned extent),
  # then a stop before btrfs device add.
  python3 -I - "$loop" "$work/esp" <<'EOF' | sfdisk --quiet --append --no-reread --no-tell-kernel "$loop"
import json, sys
rec = json.load(open(f"{sys.argv[2]}/aurora/whole-disk/removed.json"))
mib, ss = 1 << 20, 4096
start = -(-rec["freeOffset"] // mib) * mib
end = (rec["freeOffset"] + rec["freeSize"]) // mib * mib
print(f'start={start // ss}, size={(end - start) // ss}, '
      'type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="Aurora (from macOS)"')
EOF
fi
{
  echo "== mode $mode"
  echo "== claim --dry-run"
  "${tool[@]}" --esp "$work/esp" claim --root "$work/root" --dry-run
  echo "== claim --yes"
  "${tool[@]}" --esp "$work/esp" claim --root "$work/root" --yes
  echo "== claim again (idempotent)"
  "${tool[@]}" --esp "$work/esp" claim --root "$work/root" --yes
  echo "== removed.json back beside claimed.json (stop before its unlink): claim tidies up"
  cp "$work/removed.json.copy" "$work/esp/aurora/whole-disk/removed.json"
  "${tool[@]}" --esp "$work/esp" claim --root "$work/root" --yes
  [[ ! -f $work/esp/aurora/whole-disk/removed.json ]] && echo "removed.json tidied"
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
grep -q 'removed.json tidied' "$logs/claim.txt" || result="FAIL leftover removed.json not tidied"
if [[ $mode == interrupted ]]; then
  grep -q 'Finishes an earlier claim' "$logs/claim.txt" || result="FAIL interrupted claim not resumed"
fi
if [[ ${3:-} == v2-refuse ]]; then
  mode=v2-refuse
  grep -q 'stay where they are.*named in' "$logs/move-refuse.txt" || result="FAIL move did not refuse"
  grep -q 'gpt unchanged' "$logs/move-refuse.txt" || result="FAIL move changed the GPT"
  grep -q 'second device' "$logs/claim.txt" || result="FAIL claim did not say why"
fi
echo "$result ($mode): btrfs root $size_before -> $size_after bytes, $ndev devices, payload sha256 unchanged=$([[ $sum_before == "$sum_after" ]] && echo yes || echo no)" | tee "$logs/result.txt"
[[ $result == PASS ]]
