#!/usr/bin/python3 -I
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 The Aurora Silicon Contributors
"""aurora-whole-disk: let Aurora use the space macOS had.

The deletion of macOS itself happens in this installation's paired Recovery
(`aura remove-macos`), where the installation's own owner is checked first:
with macOS gone, that owner is the only one who can change this Mac's startup
security. This tool is the Linux half:

    aurora-whole-disk plan          what Recovery would delete and keep, and
                                    what Linux would do with the space (dry run)
    aurora-whole-disk claim [--dry-run] [--yes]
                                    after Recovery removed macOS: add the freed
                                    space to the root file system

It decides from the disk itself and the device tree the boot firmware hands
over (chosen/asahi,efi-system-partition, chosen/apfs-preboot-uuid), never from
the Mac model. It never writes anything in `plan` or with --dry-run.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import uuid

_here = os.path.dirname(os.path.abspath(__file__))
# Installed: apfs_ro.py sits beside this file. In the repository it is
# tools/wifi-firmware/apfs_ro.py.
sys.path[:0] = [_here, os.path.join(_here, "..", "wifi-firmware")]
import apfs_ro  # noqa: E402

ISC = "69646961-6700-11AA-AA11-00306543ECAC"
APFS = "7C3457EF-0000-11AA-AA11-00306543ECAC"
RECOVERY = "52637672-7900-11AA-AA11-00306543ECAC"
EFI = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
LINUX = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
MIB = 1 << 20
MIN_CLAIM = 1 << 30
RECORD = "aurora/whole-disk/removed.json"
DONE = "aurora/whole-disk/claimed.json"
ROLE_UPDATE = 0xC0


class Refusal(Exception):
    pass


def run(argv, input=None, check=True):
    p = subprocess.run(argv, input=input, capture_output=True, text=True)
    if check and p.returncode:
        raise Refusal(f"{' '.join(argv)} failed: {(p.stderr or p.stdout).strip()[-300:]}")
    return p.stdout


def norm(u):
    return str(uuid.UUID(u)).upper()


def read_chosen(path):
    def prop(name):
        try:
            with open(os.path.join(path, name), "rb") as f:
                return f.read().rstrip(b"\0").decode("ascii", "replace").strip()
        except OSError:
            return None
    esp, group = prop("asahi,efi-system-partition"), prop("apfs-preboot-uuid")
    if not esp or not group:
        raise Refusal("The boot firmware didn't name this installation's EFI partition and startup "
                      "container (device tree /chosen). This only runs on an Apple silicon Mac "
                      "started by Aurora.")
    return {"esp": norm(esp), "group": norm(group),
            "system_fw": prop("asahi,system-fw-version"), "os_fw": prop("asahi,os-fw-version"),
            "iboot1": prop("asahi,iboot1-version")}


def read_gpt(disk):
    t = json.loads(run(["sfdisk", "--json", disk]))["partitiontable"]
    if t.get("label") != "gpt":
        raise Refusal(f"{disk} has no GUID partition table.")
    ss = t.get("sectorsize", 512)
    parts = []
    for p in t.get("partitions", []):
        parts.append({"node": p["node"], "start": p["start"] * ss, "size": p["size"] * ss,
                      "type": p["type"].upper(), "uuid": p["uuid"].upper(),
                      "name": p.get("name", "")})
    parts.sort(key=lambda p: p["start"])
    return {"disk": disk, "sector": ss, "first": t["firstlba"] * ss,
            "last": (t["lastlba"] + 1) * ss, "parts": parts}


def container_info(node):
    """Volumes of the APFS container on `node`: (name, role, group, encrypted)."""
    c = apfs_ro.Container(node)
    return [{"name": v.name, "role": v.role, "group": v.group.upper(), "encrypted": v.encrypted}
            for v in c.volumes()]


def holds_macos(vols):
    groups = {v["group"] for v in vols if v["role"] == apfs_ro.ROLE_SYSTEM}
    data = {v["group"] for v in vols if v["role"] == apfs_ro.ROLE_DATA}
    return any(v["role"] == ROLE_UPDATE for v in vols) and bool(groups & data)


def classify(gpt, chosen, inspect=None):
    """The same rule as Recovery's MacOSRemoval: Apple's iSC first, System
    Recovery last, this installation's container found by its volume group,
    exactly one other container with a full macOS."""
    inspect = inspect or container_info
    parts = gpt["parts"]
    if len(parts) < 4 or parts[0]["type"] != ISC or parts[-1]["type"] != RECOVERY:
        raise Refusal("This disk doesn't have the layout of an Apple silicon Mac with Aurora "
                      "(Apple's iSC container first, System Recovery last).")
    for a, b in zip(parts, parts[1:]):
        if a["start"] + a["size"] > b["start"]:
            raise Refusal(f"Partitions {a['node']} and {b['node']} overlap.")
    if not any(p["uuid"] == chosen["esp"] and p["type"] == EFI for p in parts):
        raise Refusal("This installation's EFI partition isn't on this disk.")
    own, macos, others = None, [], []
    for p in parts[1:-1]:
        if p["type"] != APFS:
            continue
        try:
            vols = inspect(p["node"])
        except (apfs_ro.ApfsError, OSError) as e:
            raise Refusal(f"{p['node']} couldn't be read as an APFS container ({e}); "
                          "its contents can't be reviewed.")
        p = dict(p, volumes=vols)
        if any(v["role"] == apfs_ro.ROLE_SYSTEM and v["group"] == chosen["group"] for v in vols):
            if own:
                raise Refusal("Two containers claim this installation's volume group.")
            own = p
        elif holds_macos(vols):
            macos.append(p)
        elif any(v["role"] == apfs_ro.ROLE_SYSTEM for v in vols):
            others.append(p)
    if not own:
        raise Refusal("This installation's startup container isn't on this disk.")
    if len(macos) > 1:
        raise Refusal(f"This disk has {len(macos)} macOS installations; remove the extra ones "
                      "with Aurora Installer's Erase first.")
    return {"own": own, "macos": macos[0] if macos else None, "others": others}


def owner_state(node):
    """What this installation's startup container says about its own owner:
    Aurora Recovery's receipt and the recovery account it records. Recovery
    checks the account itself (APFS volume owner, password) before removing
    anything; this only tells whether that can succeed."""
    def read(vol, path):
        try:
            ino, _ = vol.resolve(path)
            return vol.read_file(ino)
        except (apfs_ro.ApfsError, OSError, KeyError):
            return None
    try:
        vol = apfs_ro.Container(node).volume(role=apfs_ro.ROLE_SYSTEM)
    except (apfs_ro.ApfsError, OSError) as e:
        return {"recovery": False, "account": None, "problem": f"unreadable ({e})"}
    receipt = read(vol, "/Aurora/Recovery/State/installation.json")
    pointer = read(vol, "/Aurora/Recovery/account-target.json")
    state = {"recovery": receipt is not None and read(vol, "/aura") is not None,
             "account": None, "phase": None, "problem": None}
    if pointer:
        try:
            rec = json.loads(pointer)
            state["account"], state["phase"] = rec.get("username"), rec.get("phase")
        except ValueError:
            state["problem"] = "the recovery account record is unreadable"
    if not state["recovery"]:
        state["problem"] = ("this installation has no Aurora Recovery yet (it was installed by an "
                            "older installer). Update it with Aurora Installer (Partitions → ⋯ → "
                            "Update Boot Loader, which installs Aurora Recovery) or reinstall")
    elif not state["account"]:
        state["problem"] = ("this installation has no recovery account of its own yet. Create it in "
                            "its Recovery (Aurora Installer → Utilities → Create Recovery Account…) "
                            "and authorize it in Startup Disk")
    return state


def system_name(c):
    return next((v["name"] for v in c["volumes"] if v["role"] == apfs_ro.ROLE_SYSTEM), "?")


def gb(n):
    return f"{n / 1e9:.1f} GB"


def free_extents(gpt):
    out, at = [], gpt["first"]
    for p in gpt["parts"]:
        if p["start"] > at:
            out.append((at, p["start"] - at))
        at = max(at, p["start"] + p["size"])
    if gpt["last"] > at:
        out.append((at, gpt["last"] - at))
    return out


def root_devices(root):
    """The block devices of the btrfs file system mounted at `root`."""
    fstype = run(["findmnt", "-n", "-o", "FSTYPE", "--mountpoint", root]).strip()
    if fstype != "btrfs":
        raise Refusal(f"The root file system is {fstype or 'unknown'}, not btrfs: Aurora can only "
                      "add space to a btrfs root. The freed space stays free.")
    devs = []
    for line in run(["btrfs", "filesystem", "show", root]).splitlines():
        line = line.strip()
        if line.startswith("devid") and " path " in line:
            devs.append(line.split(" path ", 1)[1].strip())
    if not devs:
        raise Refusal("Couldn't list the root file system's devices.")
    for d in devs:
        kind = run(["lsblk", "-dn", "-o", "TYPE", d]).strip()
        if kind != "part":
            raise Refusal(f"The root file system sits on {d} ({kind}), e.g. an encrypted volume. "
                          "Adding a plain partition would store data unencrypted, so the freed "
                          "space stays free.")
    return devs


def plan_text(gpt, chosen, layout):
    m = layout["macos"]
    lines = [f"Disk {gpt['disk']} ({gb(gpt['last'])})."]
    if not m:
        lines.append("There is no macOS on this disk.")
    else:
        lines.append("RECOVERY WOULD DELETE (with all its data):")
        lines.append(f"  {m['node']}  {gb(m['size'])}  macOS container “{system_name(m)}” "
                     f"(partition {m['uuid']})")
    lines.append("KEPT, unchanged:")
    for p in gpt["parts"]:
        if m and p["uuid"] == m["uuid"]:
            continue
        what = {ISC: "Apple system container (iSC: LocalPolicy, xART, Hardware)",
                RECOVERY: "Apple System Recovery", EFI: "EFI partition"}.get(p["type"], p["name"]
                                                                              or p["type"])
        if p["uuid"] == layout["own"]["uuid"]:
            what = f"Aurora startup container “{system_name(layout['own'])}” and its Recovery"
        elif any(o["uuid"] == p["uuid"] for o in layout["others"]):
            what = "another startup container"
        elif p["uuid"] == chosen["esp"]:
            what = "Aurora EFI partition"
        if p["type"] == LINUX:
            mounts = run(["findmnt", "-n", "-o", "TARGET", "--source", p["node"]],
                         check=False).split()
            what = "Linux " + (", ".join(sorted(set(mounts))) if mounts else "partition")
        lines.append(f"  {p['node']}  {gb(p['size'])}  {what}")
    lines.append(f"System firmware {chosen['system_fw']} ({chosen['iboot1']}) stays at that "
                 f"version once macOS is gone; Aurora's startup firmware is {chosen['os_fw']}.")
    return "\n".join(lines)


def cmd_plan(a, owner=owner_state):
    chosen = read_chosen(a.chosen)
    disk = a.disk or disk_of(chosen["esp"])
    gpt = read_gpt(disk)
    layout = classify(gpt, chosen)
    print(plan_text(gpt, chosen, layout))
    state = owner(layout["own"]["node"])
    if state["account"]:
        print(f"Owner for future startup changes: {state['account']} "
              f"(recorded {state['phase']}; Recovery verifies it and its password first).")
    if layout["macos"] and state["problem"]:
        print(f"\nmacOS can't be removed yet: {state['problem']}.\nDry run: nothing was changed.")
        return 3
    if layout["macos"]:
        print("\nTo remove macOS: shut down, press and hold the power button until "
              "“Loading startup options” appears, choose Options, open Terminal "
              "(Utilities → Terminal) and run:\n"
              f"    '/Volumes/{system_name(layout['own'])}/aura' remove-macos --dry-run\n"
              f"    '/Volumes/{system_name(layout['own'])}/aura' remove-macos\n"
              "It refuses unless this installation's recovery account is a working owner. "
              "Then start Aurora; it adds the space to Linux "
              f"({gb(layout['macos']['size'])}).")
    print("\nDry run: nothing was changed.")
    return 0


def disk_of(esp):
    node = os.path.realpath(f"/dev/disk/by-partuuid/{esp.lower()}")
    parent = run(["lsblk", "-no", "PKNAME", node]).strip().splitlines()
    if not parent:
        raise Refusal("Couldn't find the disk of this installation's EFI partition.")
    return "/dev/" + parent[0]


def esp_mount(esp):
    node = os.path.realpath(f"/dev/disk/by-partuuid/{esp.lower()}")
    out = run(["findmnt", "-n", "-o", "TARGET", "--source", node], check=False).split()
    if not out:
        raise Refusal("This installation's EFI partition isn't mounted.")
    return out[0]


def write_atomic(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=2, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    fd = os.open(os.path.dirname(path), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def claim_plan(gpt, chosen, record, inspect=None):
    """Checks Recovery's record against the disk and returns the new
    partition (byte start, size)."""
    if record.get("schema") != 1 or record.get("phase") != "removed":
        raise Refusal("The removal record on the EFI partition is not one this tool knows.")
    if norm(record["espUUID"]) != chosen["esp"]:
        raise Refusal("The removal record belongs to another installation.")
    uuids = {p["uuid"] for p in gpt["parts"]}
    if norm(record["removedPartitionUUID"]) in uuids:
        raise Refusal("macOS's partition is still on the disk; nothing to claim.")
    layout = classify(gpt, chosen, inspect)
    if layout["own"]["uuid"] != norm(record["installationStoreUUID"]):
        raise Refusal("The removal record names another startup container.")
    lo, n = int(record["freeOffset"]), int(record["freeSize"])
    extent = next(((s, l) for s, l in free_extents(gpt) if s <= lo and lo + n <= s + l), None)
    if not extent:
        raise Refusal("The space Recovery freed is no longer free; nothing was changed.")
    start = -(-lo // MIB) * MIB
    end = (lo + n) // MIB * MIB
    if end - start < MIN_CLAIM:
        raise Refusal("Less than 1 GiB was freed; nothing to claim.")
    return layout, start, end - start


def cmd_claim(a):
    chosen = read_chosen(a.chosen)
    esp = a.esp or esp_mount(chosen["esp"])
    path = os.path.join(esp, RECORD)
    if not os.path.exists(path):
        if os.path.exists(os.path.join(esp, DONE)):
            print("The space macOS had was already added.")
        else:
            print("macOS hasn't been removed by Recovery; nothing to claim.")
        return 0
    with open(path) as f:
        record = json.load(f)
    disk = a.disk or disk_of(chosen["esp"])
    gpt = read_gpt(disk)
    _, start, size = claim_plan(gpt, chosen, record)
    devs = root_devices(a.root)
    print(f"Adds a new {gb(size)} Linux partition on {disk} at byte {start} "
          f"(the space macOS had) to the btrfs root at {a.root} (now on {', '.join(devs)}).")
    if a.dry_run:
        print("Dry run: nothing was changed.")
        return 0
    if not a.yes:
        if input("Type 'add' to continue: ").strip() != "add":
            print("Nothing was changed.")
            return 1
    ss = gpt["sector"]
    spec = f"start={start // ss}, size={size // ss}, type={LINUX}, name=\"Aurora (from macOS)\"\n"
    run(["sfdisk", "--append", "--no-reread", "--no-tell-kernel", disk], input=spec)
    after = read_gpt(disk)
    new = [p for p in after["parts"] if p["uuid"] not in {q["uuid"] for q in gpt["parts"]}]
    kept = [(p["uuid"], p["start"], p["size"]) for p in after["parts"] if p not in new]
    if len(new) != 1 or new[0]["start"] != start or new[0]["size"] != size \
            or kept != [(p["uuid"], p["start"], p["size"]) for p in gpt["parts"]]:
        raise Refusal("The partition table didn't come out as planned; stop and check "
                      f"`sfdisk -l {disk}`.")
    node = new[0]["node"]
    number = re.search(r"(\d+)$", node).group(1)
    run(["partx", "--add", "--nr", number, disk], check=False)
    run(["udevadm", "settle"], check=False)
    for _ in range(50):
        if os.path.exists(node):
            break
        time.sleep(0.1)
    else:
        raise Refusal(f"The kernel didn't show the new partition {node}; restart and run "
                      "`sudo aurora-whole-disk claim` again.")
    # The space held macOS's APFS container; clear its old signatures so btrfs
    # takes the partition. Only the new partition, verified above, is touched.
    run(["wipefs", "--all", "--quiet", node])
    run(["btrfs", "device", "add", node, a.root])
    if node not in root_devices(a.root):
        raise Refusal(f"btrfs didn't list {node} after adding it.")
    done = dict(record, phase="claimed", claimedPartitionUUID=new[0]["uuid"],
                claimedNode=node, claimedSize=size)
    write_atomic(os.path.join(esp, DONE), done)
    os.unlink(path)
    print(f"Added {gb(size)} to the root file system.")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="aurora-whole-disk", description=__doc__.split("\n")[0])
    ap.add_argument("--chosen", default="/proc/device-tree/chosen", help=argparse.SUPPRESS)
    ap.add_argument("--disk", help=argparse.SUPPRESS)
    ap.add_argument("--esp", help=argparse.SUPPRESS)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan", help="show what would be removed and kept (dry run)")
    c = sub.add_parser("claim", help="add the space Recovery freed to the root file system")
    c.add_argument("--dry-run", action="store_true")
    c.add_argument("--yes", action="store_true", help="don't ask (the boot-time service)")
    c.add_argument("--root", default="/", help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    try:
        return {"plan": cmd_plan, "claim": cmd_claim}[a.cmd](a)
    except Refusal as e:
        print(f"aurora-whole-disk: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
