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
#   v2-j473  v2 on the real J473 table shape (first-lba 6, unnamed entries,
#     unaligned starts, the J473 sizes: 6.0 GB stub, 141 GB freed, 96 GB
#     root; 251 GB sparse image, about 8 GB written).
#   v2-j473-stop:<point>  v2-stop on the J473 shape.
#   gpt-cut  the J473 table; one partition-table edit cut after each of its
#     writes in turn; a fresh `losetup -P` must still show every partition
#     (Linux reads only the primary GPT).
#   v2-remove-fails  btrfs device remove fails twice: the first claim stops
#     with an error, the next ends with the root on two devices.
# Every mode sets attribute bits sfdisk can't print (3-47) on Apple's and
# Aurora's entries and checks, raw, that both GPT copies keep every byte of
# every entry except the planned start/end.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=${1:?scratch directory}
logs=${2:-$work}
mode=${3:-fresh}
stop=
layout=fixture
case $mode in
  fresh | interrupted | v2 | v2-refuse | v2-interrupted | v2-remove-fails) ;;
  gpt-cut) layout=j473 ;;
  v2-j473) layout=j473 ;;
  v2-stop:*) stop=${mode#v2-stop:} ;;
  v2-j473-stop:*) stop=${mode#v2-j473-stop:}; layout=j473 ;;
  *) echo "mode: fresh, interrupted, v2, v2-stop:<point>, v2-interrupted, v2-refuse, v2-j473, v2-j473-stop:<point> or v2-remove-fails" >&2; exit 1 ;;
esac
# SIGKILL points, then fail-sync-*: the kernel doesn't follow a table write
# (move exits 3 and asks for a restart).
STOP_POINTS=(copied-stub table-stub moved-stub copied-esp table-esp moved-esp copied-boot
  table-boot moved-boot root-appended root-added root-removed root-merged grown
  fail-sync-stub fail-sync-esp fail-sync-boot)
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
if [[ $layout == j473 ]]; then
  # The J473's table after its reinstall with a 27.2 stub (rows/1508-gpt-
  # lba1-5.bin): 4096-byte sectors, first-lba 6, last-lba 61279338, odd
  # starts, unnamed entries but Apple's, all attributes 0 (set below).
  truncate -s $(( (61279338 + 6) * 4096 )) "$img"
else
  truncate -s 15G "$img"
fi
loop=$(losetup --find --show --sector-size 4096 --partscan "$img")
tool=(python3 -I "$here/aurora_whole_disk.py" --chosen "$work/chosen" --disk "$loop")
if [[ $layout == j473 ]]; then
  sfdisk --quiet "$loop" <<'J473'
label: gpt
first-lba: 6
last-lba: 61279338
start=6, size=128000, type=69646961-6700-11AA-AA11-00306543ECAC, name="iBootSystemContainer"
start=128006, size=34459760, type=7C3457EF-0000-11AA-AA11-00306543ECAC, name="Container"
start=34587766, size=1464832, type=7C3457EF-0000-11AA-AA11-00306543ECAC
start=36052598, size=128000, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
start=36180598, size=262144, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
start=36442742, size=23525888, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
start=59968630, size=1310709, type=52637672-7900-11AA-AA11-00306543ECAC, name="RecoveryOSContainer"
J473
else
  python3 -I -c "import sys; sys.path.insert(0, '$repo/tests'); import whole_disk_fixtures as fx; print(fx.sfdisk_script(4096), end='')" |
    sfdisk --quiet "$loop"
fi
# Raw GPT helper: set-attrs, dump, compare (both copies, every entry byte).
gptraw() {
  python3 -I - "$here" "$@" <<'EOF'
import json, os, struct, sys
sys.path[:0] = [sys.argv[1], os.path.join(sys.argv[1], "..", "wifi-firmware")]
import aurora_whole_disk as wd
cmd, disk = sys.argv[2], sys.argv[3]
if cmd == "set-attrs":
    # Bits sfdisk can't show: iSC, stub, ESP, root, System Recovery.
    want = {1: 0x1000000000000021, 3: 0x20, 4: 0x0000400000000000, 6: 0x0001000000000008,
            7: 0x8000000000000004}
    io = wd.disk_io(disk)
    t = wd.gpt_load(io, 4096, os.lseek(io.fd, 0, os.SEEK_END))
    ents = [bytearray(e) for e in t["entries"]]
    for n, v in want.items():
        struct.pack_into("<Q", ents[n - 1], 48, v)
    wd.gpt_store(io, t, [bytes(e) for e in ents])
    io.close()
elif cmd in ("delete", "add"):
    # Recovery's deleteContainer (entry emptied) / an earlier claim's append.
    io = wd.disk_io(disk)
    t = wd.gpt_load(io, 4096, os.lseek(io.fd, 0, os.SEEK_END))
    ents = list(t["entries"])
    if cmd == "delete":
        ents[int(sys.argv[4]) - 1] = bytes(wd.ENTRY)
    else:
        live = t["primary"]
        ents = wd.gpt_apply(ents, 4096, [("add", int(sys.argv[4]), int(sys.argv[5]), wd.LINUX,
                                          wd.CLAIM_NAME, str(__import__("uuid").uuid4()))],
                            live["first"], live["last"])
    wd.gpt_store(io, t, ents)
    io.close()
elif cmd == "dump":
    json.dump(wd.gpt_raw_entries(disk, 4096), open(sys.argv[4], "w"), indent=1)
elif cmd == "compare":
    # before, after, the old root's GPT UUID or "-" (v1: nothing moved).
    before, after = json.load(open(sys.argv[3])), json.load(open(sys.argv[4]))
    root, bad = sys.argv[5], []
    for uid, c in after.items():
        if c.get("primary") != c.get("backup"):
            bad.append(f"{uid}: primary and backup differ")
    for uid, c in before.items():
        if uid not in after:
            bad.append(f"{uid}: gone")
            continue
        b, a = bytes.fromhex(c["primary"][1]), bytes.fromhex(after[uid]["primary"][1])
        keep = [(0, 32), (48, 128)] if uid != root else [(0, 32), (40, 128)]
        if any(a[x:y] != b[x:y] for x, y in keep):
            bad.append(f"{uid}: {b.hex()} -> {a.hex()}")
    attrs = {uid: hex(wd.entry_info(bytes.fromhex(c["primary"][1]))["attrs"])
             for uid, c in after.items()}
    print("attrs after:", json.dumps(attrs, sort_keys=True))
    print("RAW OK" if not bad else "RAW BAD\n" + "\n".join(bad))
EOF
}
gptraw set-attrs "$loop"
if [[ $mode == gpt-cut ]]; then
  cp_tab() { dd if="$loop" of="$1" bs=4096 count=6 status=none; dd if="$loop" of="$1.b" bs=4096 skip=61279339 count=5 status=none; }
  put_tab() { dd if="$1" of="$loop" bs=4096 conv=notrunc,fsync status=none; dd if="$1.b" of="$loop" bs=4096 seek=61279339 conv=notrunc,fsync status=none; }
  cp_tab "$work/tab"
  want=$(ls /sys/class/block/"$(basename "$loop")" | grep -c "^$(basename "$loop")p")
  result=PASS; : > "$logs/gpt-cut.txt"
  for after in 0 1 2 3; do
    put_tab "$work/tab"
    python3 -I - "$here" "$loop" "$after" >> "$logs/gpt-cut.txt" 2>&1 <<'EOF2' || true
import os, sys
sys.path[:0] = [sys.argv[1], os.path.join(sys.argv[1], "..", "wifi-firmware")]
import aurora_whole_disk as wd
after, n = int(sys.argv[3]), [0]
real = wd.Direct.write
def cut(self, off, data):
    if n[0] == after:
        raise SystemExit(f"cut after {after} writes")
    n[0] += 1
    real(self, off, data)
wd.Direct.write = cut
g = wd.read_gpt(sys.argv[2])
stub = next(p for p in g["parts"] if p["node"].endswith("p3"))
try:
    wd.gpt_edit(sys.argv[2], g, [("move", stub["uuid"], 524288000)])
    print(f"cut point {after}: store finished after {n[0]} writes")
except SystemExit as e:
    print(f"cut point {after}: {e}")
EOF2
    losetup -d "$loop"; loop=$(losetup --find --show --sector-size 4096 --partscan "$img"); udevadm settle
    seen=$(ls /sys/class/block/"$(basename "$loop")" | grep -c "^$(basename "$loop")p")
    stub_start=$(cat /sys/class/block/"$(basename "$loop")"p3/start)
    echo "cut point $after: fresh attach sees $seen partitions, stub at 512-byte sector $stub_start" >> "$logs/gpt-cut.txt"
    [[ $seen == "$want" ]] || result="FAIL cut point $after: $seen of $want partitions"
  done
  cat "$logs/gpt-cut.txt"
  echo "$result (gpt-cut): every cut of a table write leaves a primary GPT Linux reads ($want of $want partitions each time; old table before the primary write, new after)" | tee "$logs/result.txt"
  [[ $result == PASS ]]
  exit
fi
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
gptraw delete "$loop" 2
partx -d --nr 2 "$loop" || true
udevadm settle
size_before=$(btrfs filesystem show --raw "$work/root" | awk '/devid/ {s += $4} END {print s}')
cp "$work/esp/aurora/whole-disk/removed.json" "$work/removed.json.copy"
gptraw dump "$loop" "$work/raw-before.json"
declare -A role_of
for n in 1 3 4 5 6 7; do
  role_of[$(sfdisk --part-uuid "$loop" $n)]=$(case $n in 1) echo isc ;; 3) echo stub ;; 4) echo esp ;;
    5) echo boot ;; 6) echo root ;; 7) echo recovery ;; esac)
done
root_uuid=$(sfdisk --part-uuid "$loop" 6)
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
    local at=$1 rc claim_at=$1
    [[ $mode == v2-remove-fails ]] && claim_at=fail-remove
    echo "== move --yes${at:+ (stop at $at)}"
    set +e
    AURORA_WHOLE_DISK_TEST_STOP=$at timeout 900 "${move[@]}" --yes; rc=$?
    set -e
    echo "rc=$rc"
    if [[ -n $at && ($rc == 137 || ($rc == 3 && $at == fail-sync-*)) ]]; then return $rc; fi
    ((rc == 0)) || return $rc
    mount "${loop}p4" "$work/esp"
    mount -o ro,noload "${loop}p5" "$work/boot"
    echo "== claim --dry-run"
    timeout 300 "${tool[@]}" --esp "$work/esp" claim --root "$work/root" --dry-run
    echo "== claim --yes${claim_at:+ (test: $claim_at)}"
    set +e
    AURORA_WHOLE_DISK_TEST_STOP=$claim_at timeout 1800 "${tool[@]}" --esp "$work/esp" claim --root "$work/root" --yes
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
      [[ $rc == 137 || $rc == 3 ]] && echo "killed at $stop (rc=$rc)" || echo "NOT killed at $stop (rc=$rc)"
      restart
      echo "== restart after the stop"
      boot_once "" || echo "STEP FAILED: restart rc=$?"
    elif [[ $mode == v2-remove-fails ]]; then
      [[ $rc == 2 ]] && echo "first claim failed as it should (rc=2)" || echo "STEP FAILED: first claim rc=$rc"
      restart
      echo "== restart: device remove fails again"
      boot_once "" || echo "STEP FAILED: second start rc=$?"
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
    timeout 1200 btrfs scrub start -B "$work/root"
  } > "$logs/claim.txt" 2>&1 || { echo "FAIL ($mode): see $logs/claim.txt" | tee "$logs/result.txt"; exit 1; }
  sfdisk -d "$loop" > "$logs/gpt-after.txt"
  result=PASS
  two=no; [[ $mode == v2-remove-fails ]] && two=yes
  roles=$(for u in "${!role_of[@]}"; do echo "$u ${role_of[$u]}"; done)
  shape=$(sfdisk --json "$loop" | python3 -I -c '
import json, sys
t = json.load(sys.stdin)["partitiontable"]
roles = dict(line.split() for line in sys.argv[1].splitlines())
ps = sorted(t["partitions"], key=lambda p: p["start"])
print(" ".join(roles.get(p["uuid"].upper(), "new") for p in ps))
gaps = [b["start"] - a["start"] - a["size"] for a, b in zip(ps, ps[1:])]
print(max(gaps) * t["sectorsize"])
want = "new" if sys.argv[2] == "yes" else "root"
r = next(p for p in ps if roles.get(p["uuid"].upper(), "new") == want)
print(r["node"], r["size"] * t["sectorsize"])' "$roles" "$two")
  order=$(sed -n 1p <<< "$shape"); maxgap=$(sed -n 2p <<< "$shape")
  root_node=$(sed -n 3p <<< "$shape" | cut -d' ' -f1); root_size=$(sed -n 3p <<< "$shape" | cut -d' ' -f2)
  if [[ $two == yes ]]; then
    [[ $order == "isc stub esp boot new root recovery" ]] || result="FAIL order: $order"
  else
    [[ $order == "isc stub esp boot root recovery" ]] || result="FAIL order: $order"
  fi
  (( maxgap < 1048576 )) || result="FAIL gap of $maxgap bytes"
  gptraw compare "$work/raw-before.json" <(gptraw dump "$loop" /dev/stdout) \
    "$([[ $two == yes ]] && echo - || echo "$root_uuid")" > "$logs/gpt-raw-check.txt"
  gptraw dump "$loop" "$logs/gpt-raw-after.json"
  cp "$work/raw-before.json" "$logs/gpt-raw-before.json"
  grep -q '^RAW OK' "$logs/gpt-raw-check.txt" || result="FAIL raw GPT entries changed"
  umount "$work/esp"
  for n in 3 5; do
    [[ $(timeout 600 sha256sum < "${loop}p$n") == "${sha_before[$n]}" ]] || result="FAIL p$n bytes changed"
  done
  fsck.vfat -n "${loop}p4" > "$logs/fsck-esp.txt" 2>&1 || result="FAIL fsck.vfat"
  e2fsck -fn "${loop}p5" > "$logs/fsck-boot.txt" 2>&1 || result="FAIL e2fsck /boot"
  mount -o ro "${loop}p4" "$work/esp"
  (cd "$work/esp" && sha256sum -c --quiet "$work/esp-sums.txt") > "$logs/esp-sums-check.txt" 2>&1 ||
    result="FAIL ESP files"
  [[ -f $work/esp/aurora/whole-disk/claimed.json && ! -f $work/esp/aurora/whole-disk/removed.json ]] ||
    result="FAIL records"
  grep -q "\"layout\": \"$([[ $two == yes ]] && echo two-devices || echo one-root)\"" \
    "$work/esp/aurora/whole-disk/claimed.json" || result="FAIL layout record"
  umount "$work/esp"
  ndev=$(btrfs filesystem show "$work/root" | grep -c devid)
  size_after=$(btrfs filesystem show --raw "$work/root" | awk '/devid/ {s += $4} END {print s}')
  waste=$(( hole - (size_after - size_before) ))
  # Each moved partition lands 1 MiB aligned: at most 1 MiB lost per move.
  (( waste >= 0 && waste < 3 * 1048576 )) || result="FAIL grew $((size_after - size_before)) of $hole"
  if [[ $two == yes ]]; then
    [[ $ndev == 2 ]] || result="FAIL devices=$ndev"
    grep -q 'stays on two partitions' "$logs/claim.txt" || result="FAIL no two-device message"
    grep -q 'first claim failed as it should' "$logs/claim.txt" || result="FAIL first claim"
  else
    [[ $ndev == 1 ]] || result="FAIL devices=$ndev"
    (( size_after == root_size )) || result="FAIL btrfs $size_after != partition $root_size"
    [[ $(btrfs filesystem show "$work/root" | awk '/devid/ {print $NF}') == "$root_node" ]] ||
      result="FAIL root device"
  fi
  ! grep -q 'STEP FAILED' "$logs/claim.txt" || result="FAIL $(grep -m1 'STEP FAILED' "$logs/claim.txt")"
  grep -q 'already added' "$logs/claim.txt" || result="FAIL second claim not idempotent"
  grep -q 'Nothing to move' "$logs/claim.txt" || result="FAIL move after the claim"
  grep -q 'no errors found' "$logs/claim.txt" || result="FAIL scrub"
  if [[ -n $stop ]]; then
    grep -q "killed at $stop" "$logs/claim.txt" || result="FAIL not killed at $stop"
    if [[ $stop == fail-sync-* ]]; then
      grep -q 'Restart now, before mounting' "$logs/claim.txt" || result="FAIL no restart request"
    fi
  fi
  # A real restart: detach, attach again, mount root from the table alone.
  umount "$work/root"
  losetup -d "$loop"; loop=
  loop=$(losetup --find --show --sector-size 4096 --partscan "$img")
  udevadm settle
  sfdisk -d "$loop" > "$logs/gpt-reattached.txt"
  rnode=$(sfdisk --json "$loop" | python3 -I -c '
import json, sys
print(next(p["node"] for p in json.load(sys.stdin)["partitiontable"]["partitions"]
           if p["uuid"].upper() == sys.argv[1]))' "$root_uuid")
  btrfs device scan > /dev/null
  mount "$rnode" "$work/root"
  (cd "$work/root" && sha256sum -c --quiet "$work/root-sums.txt") > "$logs/root-sums-check.txt" 2>&1 ||
    result="FAIL root data after reattach"
  [[ $(btrfs filesystem show "$work/root" | grep -c devid) == "$ndev" ]] || result="FAIL devices after reattach"
  echo "$result ($mode, $layout layout): btrfs root $size_before -> $size_after bytes (+$((size_after - size_before)) of $hole freed, $waste to alignment), $ndev device(s), layout '$order', max gap $maxgap, raw GPT entries kept (attrs incl. bits 3-47, both copies), stub/boot sha256 unchanged, ESP files unchanged, root data sha256 OK after reattach" | tee "$logs/result.txt"
  [[ $result == PASS ]]
  exit
fi
if [[ $mode == interrupted ]]; then
  # What the claim's own table write adds (1 MiB aligned extent), then a
  # stop before btrfs device add.
  read -r start size < <(python3 -I - "$work/esp" <<'EOF'
import json, sys
rec = json.load(open(f"{sys.argv[1]}/aurora/whole-disk/removed.json"))
mib = 1 << 20
start = -(-rec["freeOffset"] // mib) * mib
end = (rec["freeOffset"] + rec["freeSize"]) // mib * mib
print(start, end - start)
EOF
)
  gptraw add "$loop" "$start" "$size"
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
gptraw compare "$work/raw-before.json" <(gptraw dump "$loop" /dev/stdout) - > "$logs/gpt-raw-check.txt"
grep -q '^RAW OK' "$logs/gpt-raw-check.txt" || result="FAIL raw GPT entries changed"
if [[ $mode == interrupted ]]; then
  grep -q 'Finishes an earlier claim' "$logs/claim.txt" || result="FAIL interrupted claim not resumed"
fi
if [[ ${3:-} == v2-refuse ]]; then
  mode=v2-refuse
  grep -q 'stay where they are.*named in' "$logs/move-refuse.txt" || result="FAIL move did not refuse"
  grep -q 'gpt unchanged' "$logs/move-refuse.txt" || result="FAIL move changed the GPT"
  grep -q 'second device' "$logs/claim.txt" || result="FAIL claim did not say why"
fi
echo "$result ($mode): btrfs root $size_before -> $size_after bytes, $ndev devices, payload sha256 unchanged=$([[ $sum_before == "$sum_after" ]] && echo yes || echo no), raw GPT entries kept (attrs incl. bits 3-47, both copies)" | tee "$logs/result.txt"
[[ $result == PASS ]]
