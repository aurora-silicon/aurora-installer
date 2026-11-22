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
    aurora-whole-disk move [--dry-run] [--yes]
                                    at start, before /boot and the EFI partition
                                    are mounted: move the startup container, the
                                    EFI partition and /boot into the space macOS
                                    had (aurora-whole-disk-move.service)
    aurora-whole-disk claim [--dry-run] [--yes]
                                    after Recovery removed macOS: give the freed
                                    space to the root file system (one root
                                    partition when `move` ran, else a second
                                    btrfs device)

It decides from the disk itself and the device tree the boot firmware hands
over (chosen/asahi,efi-system-partition, chosen/apfs-preboot-uuid), never from
the Mac model. It never writes anything in `plan` or with --dry-run.
"""
import argparse
import contextlib
import errno
import fcntl
import glob
import hashlib
import json
import mmap
import os
import re
import signal
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
XBOOTLDR = "BC13C2FF-59E6-4262-A352-B275FD6F7172"
ROOT_ARM64 = "B921B045-1DF0-41C3-AF44-4C6F280D3FAE"
BOOT_TYPES = {LINUX, XBOOTLDR}
ROOT_TYPES = {LINUX, ROOT_ARM64}
MIB = 1 << 20
MIN_CLAIM = 1 << 30
RECORD = "aurora/whole-disk/removed.json"
DONE = "aurora/whole-disk/claimed.json"
ROLE_RECOVERY, ROLE_VM, ROLE_PREBOOT, ROLE_UPDATE = 4, 8, 0x10, 0xC0
MACOS_ROLES = {apfs_ro.ROLE_SYSTEM: "System", apfs_ro.ROLE_DATA: "Data", ROLE_PREBOOT: "Preboot",
               ROLE_RECOVERY: "Recovery", ROLE_VM: "VM", ROLE_UPDATE: "Update"}
CLAIM_NAME = "Aurora (from macOS)"
MOVED = ("stub", "esp", "boot")
MOVE_NAMES = {"stub": "startup container", "esp": "EFI partition", "boot": "/boot partition"}
CHUNK = 4 * MIB
RUN_DIR = "/run/aurora-whole-disk"
# Test-only fault injection (tools/whole-disk/image-test.sh): when this names a
# point, the tool kills itself there with SIGKILL. Unset (always, outside that
# test) it does nothing.
TEST_STOP = "AURORA_WHOLE_DISK_TEST_STOP"


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
                      "name": p.get("name", ""), "attrs": p.get("attrs", "")})
    parts.sort(key=lambda p: p["start"])
    return {"disk": disk, "sector": ss, "first": t["firstlba"] * ss,
            "last": (t["lastlba"] + 1) * ss, "parts": parts}


def container_info(node):
    """Volumes of the APFS container on `node`: (name, role, group, encrypted).
    The device is closed again before this returns: `move` re-points the
    partition afterwards, and the kernel won't while it is open."""
    fd = os.open(node, os.O_RDONLY | os.O_CLOEXEC)
    try:
        src = type("_Fd", (), {"pread": staticmethod(lambda n, off: os.pread(fd, n, off))})
        c = apfs_ro.Container(src)
        return [{"name": v.name, "role": v.role, "group": v.group.upper(),
                 "encrypted": v.encrypted} for v in c.volumes()]
    finally:
        os.close(fd)


def looks_like_macos(vols):
    """A System volume and an Update volume; installer-made startup
    containers have no Update volume."""
    return (any(v["role"] == apfs_ro.ROLE_SYSTEM for v in vols)
            and any(v["role"] == ROLE_UPDATE for v in vols))


def macos_problem(vols):
    """Why this container is more than exactly one macOS, or None. The same
    rule as Recovery's WholeDiskContainer.macOSProblem: deleting the container
    deletes every volume in it."""
    systems = [v for v in vols if v["role"] == apfs_ro.ROLE_SYSTEM]
    if len(systems) != 1:
        return f"it holds {len(systems)} System volumes"
    data = [v for v in vols if v["role"] == apfs_ro.ROLE_DATA]
    if len(data) != 1 or data[0]["group"] != systems[0]["group"]:
        return "its System and Data volumes aren't one volume group"
    for v in vols:
        if v["role"] not in MACOS_ROLES:
            return f"volume “{v['name']}” (role {v['role']:#x}) isn't part of macOS"
    for role, name in sorted(MACOS_ROLES.items()):
        if sum(v["role"] == role for v in vols) > 1:
            return f"it holds more than one {name} volume"
    return None


def holds_macos(vols):
    return looks_like_macos(vols) and macos_problem(vols) is None


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
    if sum(p["type"] == ISC for p in parts) != 1 or sum(p["type"] == RECOVERY for p in parts) != 1:
        raise Refusal("This disk has more than one Apple system or Recovery container.")
    if len({p["uuid"] for p in parts}) != len(parts):
        raise Refusal("Two partitions on this disk share a UUID.")
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
        elif looks_like_macos(vols):
            problem = macos_problem(vols)
            if problem:
                names = ", ".join(f"“{v['name']}”" for v in vols)
                raise Refusal(f"{p['node']} holds macOS together with something else: {problem}. "
                              f"Deleting it would delete every volume in it ({names}); move or "
                              "delete the extra volumes in macOS first.")
            macos.append(p)
        elif any(v["role"] == apfs_ro.ROLE_SYSTEM for v in vols):
            others.append(p)
    if not own:
        raise Refusal("This installation's startup container isn't on this disk.")
    if len(macos) > 1:
        raise Refusal(f"This disk has {len(macos)} macOS installations; remove the extra ones "
                      "with Aurora Installer's Erase first.")
    return {"own": own, "macos": macos[0] if macos else None, "others": others}


OWNER_PHASES = {
    "allocating": "this installation's recovery account wasn't finished. Open Aurora Installer "
                  "in its Recovery again to finish it, then authorize it in Startup Disk",
    "creating": "this installation's recovery account wasn't finished. Open Aurora Installer "
                "in its Recovery again to finish it, then authorize it in Startup Disk",
    "prepared": "this installation's recovery account isn't authorized yet. Choose this "
                "installation in Startup Disk and authorize the account there",
    "awaiting-ownership": "this installation's recovery account isn't authorized yet. Choose "
                          "this installation in Startup Disk and authorize the account there",
}


def owner_state(node, group=None):
    """What this installation's startup container says about its own owner:
    Aurora Recovery's receipt and the recovery account it records. Recovery
    checks the account itself (APFS volume owner, password) before removing
    anything; this only tells whether that can succeed. Only a finalized
    account of this installation's own volume group passes."""
    def read(vol, path):
        try:
            ino, _ = vol.resolve(path)
            return vol.read_file(ino)
        except (apfs_ro.ApfsError, OSError, KeyError):
            return None
    try:
        vol = apfs_ro.Container(node).volume(role=apfs_ro.ROLE_SYSTEM)
    except (apfs_ro.ApfsError, OSError) as e:
        return {"recovery": False, "account": None, "phase": None, "problem": f"unreadable ({e})"}
    receipt = read(vol, "/Aurora/Recovery/State/installation.json")
    pointer = read(vol, "/Aurora/Recovery/account-target.json")
    recovery = receipt is not None and read(vol, "/aura") is not None
    return owner_problem(recovery, pointer, group)


def owner_problem(recovery, pointer, group=None):
    state = {"recovery": recovery, "account": None, "phase": None, "problem": None}
    rec = None
    if pointer:
        try:
            rec = json.loads(pointer)
            if not isinstance(rec, dict):
                raise ValueError
            state["account"], state["phase"] = rec.get("username"), rec.get("phase")
        except ValueError:
            rec = None
            state["problem"] = "the recovery account record is unreadable"
    if not recovery:
        state["problem"] = ("this installation has no Aurora Recovery yet (it was installed by an "
                            "older installer). Update it with Aurora Installer (Partitions → ⋯ → "
                            "Update Boot Loader, which installs Aurora Recovery) or reinstall")
    elif state["problem"]:
        pass
    elif not state["account"]:
        state["problem"] = ("this installation has no recovery account of its own yet. Create it in "
                            "its Recovery (Aurora Installer → Utilities → Create Recovery Account…) "
                            "and authorize it in Startup Disk")
    elif group and not _same_group(rec, group):
        state["problem"] = "the recovery account record names another installation"
    elif state["phase"] != "finalized":
        state["problem"] = OWNER_PHASES.get(
            state["phase"], f"the recovery account is in an unknown state ({state['phase']!r})")
    return state


def _same_group(rec, group):
    try:
        return norm(rec["target"]["groupUUID"]) == group
    except (KeyError, TypeError, ValueError, AttributeError):
        return False


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


def root_devices(root, disk=None):
    """The block devices of the btrfs file system mounted at `root`, each a
    plain partition of `disk` when given."""
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
        if disk:
            parent = run(["lsblk", "-dn", "-o", "PKNAME", d]).strip()
            if "/dev/" + parent != os.path.realpath(disk):
                raise Refusal(f"The root file system's device {d} isn't on {disk}; the space "
                              "macOS had is only added to a root on the same disk.")
    return devs


def plan_text(gpt, chosen, layout):
    m = layout["macos"]
    lines = [f"Disk {gpt['disk']} ({gb(gpt['last'])})."]
    if not m:
        lines.append("There is no macOS on this disk.")
    else:
        lines.append("RECOVERY WOULD DELETE (with all its data):")
        lines.append(f"  {m['node']}  {gb(m['size'])}  macOS container “{system_name(m)}” "
                     f"(partition {m['uuid']}), every volume in it:")
        for v in sorted(m["volumes"], key=lambda v: v["name"]):
            role = MACOS_ROLES.get(v["role"], f"{v['role']:#x}")
            lines.append(f"    volume “{v['name']}” ({role})")
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
    state = owner(layout["own"]["node"], chosen["group"])
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
              "Or open the app instead with "
              f"'/Volumes/{system_name(layout['own'])}/aura' and choose Utilities → Remove macOS…. "
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


def check_record(gpt, chosen, record, inspect=None):
    """Checks Recovery's record against the disk: this installation's, macOS's
    partition gone. Returns (layout, freeOffset, freeSize)."""
    if not isinstance(record, dict) or record.get("schema") != 1 \
            or record.get("phase") != "removed":
        raise Refusal("The removal record on the EFI partition is not one this tool knows.")
    try:
        esp, removed = norm(record["espUUID"]), norm(record["removedPartitionUUID"])
        store = norm(record["installationStoreUUID"])
        lo, n = int(record["freeOffset"]), int(record["freeSize"])
    except (KeyError, TypeError, ValueError, AttributeError):
        raise Refusal("The removal record on the EFI partition is incomplete; nothing was changed.")
    if lo < 0 or n <= 0:
        raise Refusal("The removal record on the EFI partition is incomplete; nothing was changed.")
    if esp != chosen["esp"]:
        raise Refusal("The removal record belongs to another installation.")
    if removed in {p["uuid"] for p in gpt["parts"]}:
        raise Refusal("macOS's partition is still on the disk; nothing to claim.")
    layout = classify(gpt, chosen, inspect)
    if layout["macos"] is not None:
        raise Refusal("A macOS container is on the disk again; nothing was changed.")
    if layout["own"]["uuid"] != store:
        raise Refusal("The removal record names another startup container.")
    return layout, lo, n


def claim_plan(gpt, chosen, record, inspect=None):
    """Checks Recovery's record against the disk. Returns (layout, start,
    size, resume): resume is the partition a claim interrupted after
    `sfdisk --append` left exactly over the planned range, else None."""
    layout, lo, n = check_record(gpt, chosen, record, inspect)
    start = -(-lo // MIB) * MIB
    end = (lo + n) // MIB * MIB
    if end - start < MIN_CLAIM:
        raise Refusal("Less than 1 GiB was freed; nothing to claim.")
    if any(s <= lo and lo + n <= s + l for s, l in free_extents(gpt)):
        return layout, start, end - start, None
    # An earlier claim stopped after adding the partition: accept exactly one
    # partition of ours over exactly the planned range, nothing else in it.
    inside = [p for p in gpt["parts"] if p["start"] < lo + n and p["start"] + p["size"] > lo]
    if len(inside) == 1 and inside[0]["start"] == start and inside[0]["size"] == end - start \
            and inside[0]["type"] == LINUX and inside[0]["name"] == CLAIM_NAME:
        return layout, start, end - start, inside[0]
    raise Refusal("The space Recovery freed is no longer free; nothing was changed.")


# Claim v2: one root partition again. Recovery leaves
#   [iSC][freed][stub][ESP][/boot][root][System Recovery]
# and the end state is the normal layout
#   [iSC][stub][ESP][/boot][root][System Recovery]
# `move` (at start, /boot and the ESP not mounted) copies stub, ESP and /boot,
# in that order, byte for byte to the low end of the freed space and points
# their GPT entries there (same GPT UUID, type, name, attributes). `claim`
# then makes a partition from the end of /boot to the old root, moves the
# btrfs root onto it (device add, device remove), deletes the old root's
# entry and gives the new one the old root's GPT UUID, name and end. The GPT
# and the btrfs device list say where a claim stands; claimed.json carries
# the plan so a stopped claim is checked against it before it continues.


def align_up(x, a=MIB):
    return -(-x // a) * a


def v2_parts(gpt, layout, chosen, devs):
    """The partitions between Apple's iSC container and System Recovery, by
    role: stub, esp, boot, then one or two root partitions."""
    parts = gpt["parts"]
    mid = parts[1:-1]
    if len(mid) not in (4, 5) or layout["others"]:
        raise Refusal(f"Between Apple's containers this disk has {len(mid)} partitions; moving "
                      "needs exactly this installation's startup container, EFI partition, /boot "
                      "and root.")
    stub, esp, boot, roots = mid[0], mid[1], mid[2], mid[3:]
    if stub["uuid"] != layout["own"]["uuid"]:
        raise Refusal("This installation's startup container isn't the first partition after "
                      "Apple's iSC container.")
    if esp["uuid"] != chosen["esp"] or esp["type"] != EFI:
        raise Refusal("This installation's EFI partition doesn't follow its startup container.")
    if boot["type"] not in BOOT_TYPES or boot["node"] in devs:
        raise Refusal("The partition after the EFI partition isn't a separate /boot.")
    if any(r["type"] not in ROOT_TYPES for r in roots):
        raise Refusal("The partitions after /boot aren't Linux partitions.")
    return {"isc": parts[0], "stub": stub, "esp": esp, "boot": boot, "roots": roots,
            "rec": parts[-1]}


def move_targets(parts):
    """Where stub, ESP and /boot go: one after another from the end of the iSC
    container, each 1 MiB aligned. Also the new root's start. Depends only
    on the iSC end and the sizes, so every stage of a claim gets the same."""
    at, to = parts["isc"]["start"] + parts["isc"]["size"], {}
    for k in MOVED:
        to[k] = align_up(at)
        at = to[k] + parts[k]["size"]
    return to, align_up(at)


def v2_plan(parts, to, root_start):
    root = parts["roots"][0]
    return {"moves": {k: {"uuid": parts[k]["uuid"], "from": parts[k]["start"], "to": to[k],
                          "size": parts[k]["size"]} for k in MOVED},
            "root": {"uuid": root["uuid"], "name": root["name"], "start": root["start"],
                     "end": root["start"] + root["size"]},
            "newRoot": {"start": root_start, "size": root["start"] - root_start}}


def v2_stage(gpt, chosen, record, v2, devs, inspect=None):
    """Where a one-root-partition claim stands, from the disk. `v2` is the
    claimed.json of an earlier v2 claim of the same removal (else None),
    `devs` the nodes of the btrfs root. Returns {"stage", "plan", ...}:
    initial (nothing moved; "next" is stub), move ("next" names the
    partition to move), root-create, root-add, root-remove, root-merge,
    root-resize, finish (a root kept on two devices). Anything else refuses."""
    layout, lo, n = check_record(gpt, chosen, record, inspect)
    devs = set(devs)
    parts = v2_parts(gpt, layout, chosen, devs)
    to, root_start = move_targets(parts)
    pending = [k for k in MOVED if parts[k]["start"] != to[k]]
    if pending != list(MOVED[len(MOVED) - len(pending):]):
        raise Refusal("The startup container, EFI partition and /boot aren't where a claim "
                      "would have left them; nothing was changed.")
    order = [parts["stub"], parts["esp"], parts["boot"]] + parts["roots"]
    if len(pending) == len(MOVED):
        isc_end = parts["isc"]["start"] + parts["isc"]["size"]
        if not (isc_end <= lo and lo + n <= parts["stub"]["start"]):
            raise Refusal("The space Recovery freed isn't directly before the startup container.")
        for a, b in zip(order, order[1:]):
            if b["start"] - (a["start"] + a["size"]) >= MIB:
                raise Refusal(f"{a['node']} and {b['node']} aren't next to each other.")
        if len(parts["roots"]) != 1 or parts["roots"][0]["node"] not in devs or len(devs) != 1:
            raise Refusal("The btrfs root isn't on exactly one partition after /boot.")
        for k in MOVED:
            if to[k] + parts[k]["size"] > parts[k]["start"]:
                raise Refusal(f"The {MOVE_NAMES[k]} is bigger than the space macOS had; its copy "
                              "would overlap it.")
        plan = v2_plan(parts, to, root_start)
        if plan["newRoot"]["size"] < MIN_CLAIM:
            raise Refusal("Less than 1 GiB would be left for the root; nothing to claim.")
        if v2 is not None and v2.get("v2") != plan:
            raise Refusal("claimed.json has another plan than this disk gives; nothing was changed.")
        return {"stage": "initial", "plan": plan, "next": "stub"}
    plan = (v2 or {}).get("v2")
    if not isinstance(plan, dict):
        raise Refusal("The startup container or EFI partition was moved, but the EFI partition "
                      "has no claim record for it; nothing was changed.")
    try:
        moves, old, new = plan["moves"], plan["root"], plan["newRoot"]
        for k in MOVED:
            m, p = moves[k], parts[k]
            if (m["uuid"], m["size"], m["to"]) != (p["uuid"], p["size"], to[k]) or \
                    p["start"] != (m["from"] if k in pending else m["to"]):
                raise Refusal(f"The {MOVE_NAMES[k]} isn't where claimed.json says; nothing was "
                              "changed.")
        if (new["start"], new["size"]) != (root_start, old["start"] - root_start):
            raise Refusal("claimed.json's root plan doesn't fit this disk; nothing was changed.")
    except (KeyError, TypeError):
        raise Refusal("claimed.json on the EFI partition is incomplete; nothing was changed.")
    roots = parts["roots"]
    first = roots[0]
    as_old = first["uuid"] == old["uuid"]
    if pending:
        if len(roots) != 1 or not as_old or first["start"] != old["start"] \
                or first["start"] + first["size"] != old["end"]:
            raise Refusal("The root partition changed while partitions were being moved.")
        return {"stage": "move", "plan": plan, "next": pending[0]}
    if len(roots) == 1:
        if as_old and first["node"] in devs and first["start"] == old["start"] \
                and first["start"] + first["size"] == old["end"]:
            return {"stage": "root-create", "plan": plan, "old": first,
                    "start": new["start"], "size": new["size"]}
        if as_old and first["node"] in devs and first["start"] == root_start \
                and first["start"] + first["size"] == old["end"]:
            return {"stage": "root-resize", "plan": plan, "root": first}
        raise Refusal("The root partition isn't where a claim would have left it.")
    prev = roots[1]
    if first["start"] != new["start"] or first["size"] != new["size"] \
            or first["name"] != CLAIM_NAME or first["type"] != LINUX or prev["uuid"] != old["uuid"] \
            or prev["start"] != old["start"] or prev["start"] + prev["size"] != old["end"]:
        raise Refusal("The partitions after /boot aren't the ones this claim made.")
    stage = {(False, True): "root-add", (True, True): "root-remove",
             (True, False): "root-merge"}.get((first["node"] in devs, prev["node"] in devs))
    if stage == "root-remove" and v2.get("migrate") is False:
        stage = "finish"
    if stage is None or (stage == "root-merge" and v2.get("migrate") is not True):
        raise Refusal("The root file system's devices aren't the ones this claim expects.")
    return {"stage": stage, "plan": plan, "new": first, "old": prev}


def gpt_script(dump, sector, changes):
    """`sfdisk -d` output with some entries changed, as an sfdisk script for
    one write of the whole table (primary and backup). `changes` maps a GPT
    UUID to None (delete the entry) or to new fields: start and size in
    bytes, uuid, name, attrs. Everything else is kept as dumped."""
    out, seen = [], set()
    for line in dump.splitlines():
        if " : " not in line or "start=" not in line:
            out.append(line)
            continue
        node, spec = line.split(" : ", 1)
        fields = [(m.group(1), m.group(2).strip()) for m in
                  re.finditer(r'([a-z-]+)=\s*("(?:[^"\\]|\\.)*"|[^,]*)', spec)]
        uid = norm(dict(fields)["uuid"])
        if uid not in changes:
            out.append(line)
            continue
        seen.add(uid)
        ch = changes[uid]
        if ch is None:
            continue
        new = dict(fields)
        for k in ("start", "size"):
            if k in ch:
                if ch[k] % sector:
                    raise Refusal("A partition boundary isn't on a sector boundary.")
                new[k] = str(ch[k] // sector)
        for k in ("uuid", "name", "attrs"):
            if k in ch:
                v = ch[k]
                if k != "uuid" and ('"' in v or "\\" in v or "\n" in v):
                    raise Refusal(f"Can't write the GPT {k} {v!r}.")
                if v:
                    new[k] = v if k == "uuid" else f'"{v}"'
                else:
                    new.pop(k, None)
        keys = [k for k, _ in fields] + [k for k in new if k not in dict(fields)]
        out.append(f"{node} : " + ", ".join(f"{k}={new[k]}" for k in keys if k in new))
    if seen != set(changes):
        raise Refusal("The partition table changed while it was being edited.")
    return "\n".join(out) + "\n"


def root_references(texts, part):
    """Which texts name the root partition itself (its GPT UUID, its GPT
    name or its kernel name) rather than its file system. Those would point
    at a partition without the root while it moves."""
    hits = []
    uid, kname = part["uuid"].lower(), os.path.basename(part["node"])
    name = (part.get("name") or "").lower()
    for path, text in texts:
        low = text.lower()
        if uid in low:
            hits.append(f"{path} (PARTUUID {uid})")
        if name and re.search(r'(partlabel=|by-partlabel/)"?' + re.escape(name) + r'(?=["\s,]|$)',
                              low):
            hits.append(f"{path} (PARTLABEL {name})")
        if re.search(r"(?<![\w-])" + re.escape(kname) + r"(?![\w-])", text):
            hits.append(f"{path} ({kname})")
    return hits


def root_fits(used, size):
    """btrfs can move `used` bytes of allocated chunks onto a `size` device,
    with 1 GiB to spare for metadata."""
    return used + MIN_CLAIM <= size


def read_record(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        raise Refusal(f"The removal record {path} is unreadable ({e}); nothing was changed.")


def wait_for_partition(disk, node, number, partuuid):
    """The kernel's node for the new partition, checked by its GPT UUID."""
    for attempt in range(2):
        if not os.path.exists(node):
            run(["partx", "--add" if attempt == 0 else "--update", "--nr", number, disk],
                check=False)
            run(["udevadm", "settle", "--timeout=10"], check=False)
        if os.path.exists(node):
            got = run(["blkid", "-p", "-s", "PART_ENTRY_UUID", "-o", "value", node],
                      check=False).strip()
            if got and norm(got) == partuuid:
                return
            raise Refusal(f"{node} isn't the partition just added (GPT UUID {got or 'unknown'}); "
                          "nothing more was changed.")
    raise Refusal(f"The kernel didn't show the new partition {node}; restart and run "
                  "`sudo aurora-whole-disk claim` again.")


def test_stop(point):
    """Test-only (image-test.sh): die here, as a power cut would, when
    TEST_STOP names this point. Inert when it is unset."""
    if os.environ.get(TEST_STOP) == point:
        print(f"aurora-whole-disk: test stop at {point}", file=sys.stderr, flush=True)
        os.kill(os.getpid(), signal.SIGKILL)


def partnum(node):
    m = re.search(r"(\d+)$", node)
    if not m:
        raise Refusal(f"Couldn't tell the partition number of {node}.")
    return m.group(1)


def kernel_parts(disk):
    """The kernel's partitions of `disk`: number -> (start, size) in bytes."""
    base = f"/sys/class/block/{os.path.basename(os.path.realpath(disk))}"
    out = {}
    for e in os.listdir(base):
        d = os.path.join(base, e)
        if os.path.exists(os.path.join(d, "partition")):
            def val(name):
                with open(os.path.join(d, name)) as f:
                    return int(f.read())
            out[str(val("partition"))] = (val("start") * 512, val("size") * 512)
    return out


def kernel_sync(disk, gpt, locked=False):
    """Brings the kernel's partitions in line with the GPT where they differ
    (a stop between a table write and partx leaves them stale). Partitions
    in use can only change size; those that can't change are left as they
    are and checked by the caller. With the disk locked (disk_locked) udev
    leaves its partitions alone, so there is nothing to wait for."""
    want = {partnum(p["node"]): (p["start"], p["size"]) for p in gpt["parts"]}
    for _ in range(5):
        have = kernel_parts(disk)
        todo = [["--delete", nr] for nr in have if nr not in want] + \
               [["--add" if nr not in have else "--update", nr]
                for nr, g in want.items() if have.get(nr) != g]
        if not todo:
            return
        for op, nr in todo:
            run(["partx", op, "--nr", nr, disk], check=False)
        if not locked:
            run(["udevadm", "settle", "--timeout=30"], check=False)


@contextlib.contextmanager
def disk_locked(disk):
    """The whole disk locked the way systemd-udevd honours (BSD flock,
    systemd.io/BLOCK_DEVICE_LOCKING), so udev doesn't probe partitions
    while they are copied and re-pointed. Waits for pending events first."""
    run(["udevadm", "settle", "--timeout=30"], check=False)
    fd = os.open(disk, os.O_RDONLY | os.O_CLOEXEC)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)
    run(["udevadm", "settle", "--timeout=30"], check=False)


def require_geometry(disk, part):
    if kernel_parts(disk).get(partnum(part["node"])) != (part["start"], part["size"]):
        raise Refusal(f"The kernel doesn't show {part['node']} where the partition table has it; "
                      "restart and the claim continues.")


@contextlib.contextmanager
def exclusive(node, what):
    """Holds `node` open exclusively: fails when it is mounted or in use,
    and keeps anyone from mounting it meanwhile."""
    try:
        fd = os.open(node, os.O_RDONLY | os.O_EXCL | os.O_CLOEXEC)
    except OSError as e:
        if e.errno == errno.EBUSY:
            raise Refusal(f"The {what} ({node}) is in use (mounted?); it can only move while "
                          "nothing uses it.")
        raise Refusal(f"Couldn't open {node} ({e}).")
    try:
        yield fd
    finally:
        os.close(fd)


class Direct:
    """Unbuffered (O_DIRECT) access to a block device, so what is read is
    what is on the disk, not a cached page."""

    def __init__(self, path, write=False):
        self.fd = os.open(path, (os.O_RDWR if write else os.O_RDONLY) | os.O_DIRECT | os.O_CLOEXEC)
        self.buf = mmap.mmap(-1, CHUNK)

    def close(self):
        os.close(self.fd)
        self.buf.close()

    def chunks(self, off, n):
        done = 0
        while done < n:
            k = min(CHUNK, n - done)
            with memoryview(self.buf)[:k] as mv:
                if os.preadv(self.fd, [mv], off + done) != k:
                    raise Refusal(f"Short read at byte {off + done}.")
                yield done, mv
            done += k

    def sha256(self, off, n):
        h = hashlib.sha256()
        for _, mv in self.chunks(off, n):
            h.update(mv)
        return h.hexdigest()

    def copy(self, src, dst, n):
        if dst < src + n and src < dst + n:
            raise Refusal("The copy would overlap the partition it copies; nothing was changed.")
        h = hashlib.sha256()
        for done, mv in self.chunks(src, n):
            h.update(mv)
            if os.pwritev(self.fd, [mv], dst + done) != len(mv):
                raise Refusal(f"Short write at byte {dst + done}.")
        os.fsync(self.fd)
        return h.hexdigest()


def gpt_rewrite(disk, gpt, changes):
    """One write of the whole table with `changes` (see gpt_script), then
    checks that exactly those entries changed. Returns the new table."""
    script = gpt_script(run(["sfdisk", "--dump", disk]), gpt["sector"], changes)
    run(["sfdisk", "--quiet", "--no-reread", "--no-tell-kernel", disk], input=script)
    after = read_gpt(disk)
    want = {}
    for p in gpt["parts"]:
        ch = changes.get(p["uuid"], {})
        if ch is None:
            continue
        q = dict(p, **ch)
        want[partnum(p["node"])] = (q["uuid"].upper(), q["type"], q["start"], q["size"], q["name"])
    got = {partnum(p["node"]): (p["uuid"], p["type"], p["start"], p["size"], p["name"])
           for p in after["parts"]}
    if got != want:
        raise Refusal(f"The partition table didn't come out as planned; stop and check "
                      f"`sfdisk -l {disk}`.")
    return after


@contextlib.contextmanager
def esp_mounted(node, run_dir, write=False):
    """The (otherwise unmounted) ESP mounted at a private directory."""
    where = os.path.join(run_dir, "esp")
    os.makedirs(where, mode=0o700, exist_ok=True)
    if os.path.ismount(where):
        raise Refusal(f"{where} is already mounted.")
    run(["mount", "-t", "vfat", "-o", ("rw" if write else "ro") + ",nodev,nosuid,noexec",
         node, where])
    try:
        yield where
    finally:
        run(["umount", where])


def btrfs_devs(root):
    """devid, size, used (allocated) and path of each device of the btrfs at `root`."""
    out = []
    for line in run(["btrfs", "filesystem", "show", "--raw", root]).splitlines():
        m = re.match(r"\s*devid\s+(\d+)\s+size\s+(\d+)\s+used\s+(\d+)\s+path\s+(\S+)", line)
        if m:
            out.append({"devid": m.group(1), "size": int(m.group(2)), "used": int(m.group(3)),
                        "path": os.path.realpath(m.group(4))})
    return out


def reference_texts(root, disk, gpt):
    """Where a root partition could be named: the running kernel's command
    line, fstab, crypttab, kernel command-line files, and boot entries on
    whichever of this disk's partitions are mounted."""
    paths = ["/proc/cmdline"] + [os.path.join(root, f) for f in
                                 ("etc/fstab", "etc/crypttab", "etc/kernel/cmdline",
                                  "etc/default/grub")]
    for p in gpt["parts"]:
        for m in run(["findmnt", "-n", "-o", "TARGET", "--source", p["node"]],
                     check=False).split():
            for pat in ("loader/entries/*.conf", "grub2/grub.cfg", "grub/grub.cfg",
                        "EFI/*/grub.cfg"):
                paths += sorted(glob.glob(os.path.join(m, pat)))
    texts = []
    for path in paths:
        try:
            with open(path, errors="replace") as f:
                texts.append((path, f.read()))
        except OSError:
            pass
    return texts


def migrate_problem(root, disk, gpt, old, new_size):
    """Why the root can't be moved onto the new partition, or None."""
    devs = btrfs_devs(root)
    if len(devs) != 1:
        return f"the btrfs root has {len(devs)} devices"
    if not root_fits(devs[0]["used"], new_size):
        return (f"the root holds {gb(devs[0]['used'])} and the space macOS had is "
                f"{gb(new_size)}, too little to move it there")
    refs = root_references(reference_texts(root, disk, gpt), old)
    if refs:
        return "the root partition itself is named in " + "; ".join(refs)
    return None


def plan_lines(plan):
    out = []
    for k in MOVED:
        m = plan["moves"][k]
        out.append(f"  {MOVE_NAMES[k]} {m['uuid']} ({gb(m['size'])}): byte {m['from']} -> "
                   f"{m['to']}")
    r, n = plan["root"], plan["newRoot"]
    out.append(f"  root: btrfs moves to a new partition at byte {n['start']}, which then takes "
               f"the old root's place up to byte {r['end']} and its GPT UUID {r['uuid']}")
    return out


def move_one(disk, gpt, part, dst, key):
    """Copies `part` to `dst`, checks both copies, then points its GPT entry
    there in one table write. Until that write the old place is the live
    one, so a stop anywhere leaves a valid partition."""
    with disk_locked(disk):
        return _move_one(disk, gpt, part, dst, key)


def _move_one(disk, gpt, part, dst, key):
    what = MOVE_NAMES[key]
    with exclusive(part["node"], what):
        dev = Direct(disk, write=True)
        try:
            src_sum = dev.copy(part["start"], dst, part["size"])
            test_stop(f"copied-{key}")
            dst_sum = dev.sha256(dst, part["size"])
            again = dev.sha256(part["start"], part["size"])
        finally:
            dev.close()
    if not src_sum == dst_sum == again:
        raise Refusal(f"The copy of the {what} doesn't match it (sha256 {src_sum} / {dst_sum} / "
                      f"{again}); nothing was switched.")
    after = gpt_rewrite(disk, gpt, {part["uuid"]: {"start": dst}})
    test_stop(f"table-{key}")
    kernel_sync(disk, after, locked=True)
    moved = next(p for p in after["parts"] if p["uuid"] == part["uuid"])
    require_geometry(disk, moved)
    with exclusive(moved["node"], what):
        dev = Direct(moved["node"])
        try:
            node_sum = dev.sha256(0, moved["size"])
        finally:
            dev.close()
    if node_sum != dst_sum:
        raise Refusal(f"{moved['node']} doesn't read as the copy after the switch; stop and check.")
    print(f"Moved the {what} to byte {dst} (sha256 {dst_sum}).", flush=True)
    return after, dst_sum


def move_gate(gpt, chosen):
    """True when a free extent of at least 1 GiB ends at a partition up to
    the one after the ESP: only then can a move be due, and only then is the
    ESP mounted to look for Recovery's record."""
    parts = gpt["parts"]
    i = next((i for i, p in enumerate(parts) if p["uuid"] == chosen["esp"]), None)
    if i is None:
        return False
    ends = {p["start"] for p in parts[:i + 2]}
    return any(s + n in ends and n >= MIN_CLAIM for s, n in free_extents(gpt))


def cmd_move(a):
    chosen = read_chosen(a.chosen)
    run(["udevadm", "settle", "--timeout=30"], check=False)
    disk = a.disk or disk_of(chosen["esp"])
    gpt = read_gpt(disk)
    # A move that stopped between its table write and partx leaves the
    # kernel's view behind the GPT until it is synced (a restart does it too).
    kernel_sync(disk, gpt)
    if not move_gate(gpt, chosen):
        print("Nothing to move.")
        return 0
    esp_node = next(p["node"] for p in gpt["parts"] if p["uuid"] == chosen["esp"])
    try:
        with exclusive(esp_node, "EFI partition"):
            pass
    except Refusal as e:
        print(f"The partitions stay where they are: {e}")
        return 0
    with esp_mounted(esp_node, a.run_dir) as esp:
        record = read_record(os.path.join(esp, RECORD)) \
            if os.path.exists(os.path.join(esp, RECORD)) else None
        done = read_record(os.path.join(esp, DONE)) \
            if os.path.exists(os.path.join(esp, DONE)) else None
    if record is None:
        print("macOS hasn't been removed by Recovery; nothing to move.")
        return 0
    v2 = done if isinstance(done, dict) and isinstance(done.get("v2"), dict) \
        and done.get("removedPartitionUUID") == record.get("removedPartitionUUID") else None
    if v2 is not None and v2.get("phase") == "claimed":
        print("The space macOS had was already added.")
        return 0
    started = False
    try:
        devs = root_devices(a.root, disk)
        st = v2_stage(gpt, chosen, record, v2, devs)
        started = st["stage"] != "initial"
        if st["stage"] not in ("initial", "move"):
            print("The partitions were already moved; aurora-whole-disk-claim.service "
                  "finishes the claim.")
            return 0
        plan = st["plan"]
        if not started:
            problem = migrate_problem(a.root, disk, gpt, next(
                p for p in gpt["parts"] if p["uuid"] == plan["root"]["uuid"]),
                plan["newRoot"]["size"])
            if problem:
                raise Refusal(f"The root can't be moved onto one partition: {problem}.")
            for k in MOVED:
                with exclusive(next(p["node"] for p in gpt["parts"]
                                    if p["uuid"] == plan["moves"][k]["uuid"]), MOVE_NAMES[k]):
                    pass
    except Refusal as e:
        if started or (v2 is not None and v2.get("phase") != "moving-stub"):
            raise  # a claim under way: never fall back, fail where it shows
        print(f"The partitions stay where they are: {e} aurora-whole-disk-claim.service adds "
              "the space macOS had as a second device of the root instead.")
        return 0
    print("Moves this installation's partitions into the space macOS had, one after another "
          "(each is copied and checked before its partition table entry moves):")
    print("\n".join(plan_lines(plan)), flush=True)
    if a.dry_run:
        print("Dry run: nothing was changed.")
        return 0
    if not a.yes:
        if input("Type 'move' to continue: ").strip() != "move":
            print("Nothing was changed.")
            return 1
    rec = dict(record)
    rec.update(v2 or {})
    rec["v2"] = plan

    def note(phase):
        # The record lives on the ESP; it is written only while the ESP isn't
        # being copied, and the GPT, not the record, says which copy is live.
        rec["phase"] = phase
        node = next(p["node"] for p in gpt["parts"] if p["uuid"] == chosen["esp"])
        with esp_mounted(node, a.run_dir, write=True) as esp:
            write_atomic(os.path.join(esp, DONE), rec)

    try:
        for k in MOVED[MOVED.index(st["next"]):]:
            note(f"moving-{k}")
            started = True
            part = next(p for p in gpt["parts"] if p["uuid"] == plan["moves"][k]["uuid"])
            gpt, digest = move_one(disk, gpt, part, plan["moves"][k]["to"], k)
            rec.setdefault("sha256", {})[k] = digest
            note(f"moved-{k}")
            test_stop(f"moved-{k}")
    except Refusal as e:
        now = read_gpt(disk)
        if any(p["uuid"] == plan["moves"][k]["uuid"] and p["start"] == plan["moves"][k]["to"]
               for k in MOVED for p in now["parts"]):
            raise
        print(f"The partitions stay where they are: {e} aurora-whole-disk-claim.service adds "
              "the space macOS had as a second device of the root instead.")
        return 0
    print("Moved the startup container, the EFI partition and /boot; "
          "aurora-whole-disk-claim.service moves the root next.")
    return 0


def claim_root(a, disk, chosen, record, v2, st, done_path, path):
    """The root half of a one-root claim, after `move`: new partition, btrfs
    onto it, old partition's entry folded into it, file system grown. Each
    step starts from what the disk shows (v2_stage)."""
    rec = dict(v2)

    def note(phase, **kw):
        rec.update(kw, phase=phase)
        write_atomic(done_path, rec)

    print("Finishes moving the root into the space macOS had:")
    print("\n".join(plan_lines(st["plan"])))
    if a.dry_run:
        print(f"Next step: {st['stage']}.\nDry run: nothing was changed.")
        return 0
    if not a.yes:
        if input("Type 'add' to continue: ").strip() != "add":
            print("Nothing was changed.")
            return 1
    gpt = read_gpt(disk)
    kernel_sync(disk, gpt)
    for k in MOVED:
        # /boot or the ESP mounted from a place the GPT no longer has: the
        # root must not move over it. A restart mounts them from the GPT.
        part = next(p for p in gpt["parts"] if p["uuid"] == st["plan"]["moves"][k]["uuid"])
        require_geometry(disk, part)
    for _ in range(8):
        stage = st["stage"]
        if stage == "root-create":
            problem = migrate_problem(a.root, disk, gpt, st["old"], st["size"])
            if problem:
                print(f"The root stays on two partitions: {problem}.", flush=True)
            note("root-adding", migrate=problem is None, migrateProblem=problem)
            ss = gpt["sector"]
            spec = (f"start={st['start'] // ss}, size={st['size'] // ss}, type={LINUX}, "
                    f"name=\"{CLAIM_NAME}\"\n")
            run(["sfdisk", "--append", "--no-reread", "--no-tell-kernel", disk], input=spec)
            after = read_gpt(disk)
            added = [p for p in after["parts"] if p["uuid"] not in {q["uuid"] for q in gpt["parts"]}]
            kept = [(p["uuid"], p["start"], p["size"]) for p in after["parts"] if p not in added]
            if len(added) != 1 or (added[0]["start"], added[0]["size"]) != (st["start"], st["size"]) \
                    or kept != [(p["uuid"], p["start"], p["size"]) for p in gpt["parts"]]:
                raise Refusal("The partition table didn't come out as planned; stop and check "
                              f"`sfdisk -l {disk}`.")
            test_stop("root-appended")
        elif stage == "root-add":
            new = st["new"]
            wait_for_partition(disk, new["node"], partnum(new["node"]), new["uuid"])
            run(["wipefs", "--all", "--quiet", new["node"]])
            run(["btrfs", "device", "add", new["node"], a.root])
            note("root-added")
            test_stop("root-added")
        elif stage == "root-remove":
            print(f"Moving the root file system from {st['old']['node']} to {st['new']['node']} "
                  "(btrfs device remove; this takes a while, and continues after a restart).",
                  flush=True)
            run(["btrfs", "device", "remove", st["old"]["node"], a.root])
            note("root-removed")
            test_stop("root-removed")
        elif stage == "root-merge":
            old, new = st["old"], st["new"]
            m = re.search(r"uuid:\s*([0-9a-f-]{36})",
                          run(["btrfs", "filesystem", "show", "--raw", a.root]))
            fsid = m.group(1) if m else None
            sig = run(["blkid", "-p", "-o", "value", "-s", "UUID", old["node"]],
                      check=False).strip().lower()
            if not fsid or sig == fsid:
                raise Refusal(f"{old['node']} still carries the root file system; nothing more "
                              "was changed.")
            with disk_locked(disk):
                gpt = gpt_rewrite(disk, gpt, {
                    old["uuid"]: None,
                    new["uuid"]: {"uuid": old["uuid"], "name": old["name"], "attrs": old["attrs"],
                                  "size": old["start"] + old["size"] - new["start"]}})
                test_stop("root-merged")
                kernel_sync(disk, gpt, locked=True)
            note("grown")
            test_stop("grown")
        elif stage == "root-resize":
            root = st["root"]
            require_geometry(disk, root)
            run(["udevadm", "trigger", "--action=change", root["node"]], check=False)
            run(["udevadm", "settle", "--timeout=30"], check=False)
            dev = next((d for d in btrfs_devs(a.root) if d["path"] == os.path.realpath(root["node"])),
                       None)
            if dev is None:
                raise Refusal(f"btrfs doesn't list {root['node']}.")
            run(["btrfs", "filesystem", "resize", f"{dev['devid']}:max", a.root])
            got = next(d for d in btrfs_devs(a.root) if d["devid"] == dev["devid"])["size"]
            if got < root["size"] - MIB:
                raise Refusal(f"btrfs grew to {got} bytes, not {root['size']}.")
            return claim_done(rec, root, st["plan"]["newRoot"]["size"], "one-root", done_path, path)
        elif stage == "finish":
            new = st["new"]
            return claim_done(rec, new, new["size"], "two-devices", done_path, path)
        gpt = read_gpt(disk)
        kernel_sync(disk, gpt)
        st = v2_stage(gpt, chosen, record, rec, root_devices(a.root, disk))
    raise Refusal("The claim didn't finish; run `sudo aurora-whole-disk claim` again.")


def claim_done(rec, part, size, layout, done_path, path):
    write_atomic(done_path, dict(rec, phase="claimed", claimedPartitionUUID=part["uuid"],
                                 claimedNode=part["node"], claimedSize=size, layout=layout))
    os.unlink(path)
    if layout == "one-root":
        print(f"Added {gb(size)} to the root file system; it is one partition again "
              f"({part['node']}, {gb(part['size'])}).")
    else:
        print(f"Added {gb(size)} to the root file system as a second device ({part['node']}).")
    return 0


def cmd_claim(a):
    chosen = read_chosen(a.chosen)
    esp = a.esp or esp_mount(chosen["esp"])
    path, done_path = os.path.join(esp, RECORD), os.path.join(esp, DONE)
    disk = a.disk or disk_of(chosen["esp"])
    done = read_record(done_path) if os.path.exists(done_path) else None
    unfinished = None
    if isinstance(done, dict) and done.get("phase", "claimed") != "claimed":
        unfinished, done = done, None  # a one-root claim under way: see below
    if done is not None and os.path.exists(path):
        record = read_record(path)
        same = isinstance(done, dict) and isinstance(record, dict) \
            and done.get("removedPartitionUUID") == record.get("removedPartitionUUID")
        if not same:
            done = None  # a later removal: claim it like the first
    if done is not None:
        if os.path.exists(path):
            # Stopped between writing claimed.json and removing removed.json.
            node = done.get("claimedNode") if isinstance(done, dict) else None
            if not node or node not in root_devices(a.root, disk):
                raise Refusal(f"{DONE} and {RECORD} are both on the EFI partition but the claimed "
                              "partition isn't in the root file system; nothing was changed.")
            if not a.dry_run:
                os.unlink(path)
        print("The space macOS had was already added.")
        return 0
    if not os.path.exists(path):
        print("macOS hasn't been removed by Recovery; nothing to claim.")
        return 0
    record = read_record(path)
    gpt = read_gpt(disk)
    devs = root_devices(a.root, disk)
    v2 = unfinished if isinstance(unfinished, dict) and isinstance(unfinished.get("v2"), dict) \
        and unfinished.get("removedPartitionUUID") == record.get("removedPartitionUUID") else None
    try:
        st, why = v2_stage(gpt, chosen, record, v2, devs), None
    except Refusal as e:
        st, why = None, e
    if st and st["stage"] == "move":
        raise Refusal("The partitions are being moved into the space macOS had; that continues "
                      "at the next start (aurora-whole-disk-move.service). Restart.")
    if st and st["stage"] != "initial":
        return claim_root(a, disk, chosen, record, v2, st, done_path, path)
    try:
        _, start, size, resume = claim_plan(gpt, chosen, record)
    except Refusal:
        if v2 is not None and why is not None:
            raise why
        raise
    if st:
        print("The partitions weren't moved at start (aurora-whole-disk-move.service), so the "
              "space macOS had becomes a second device of the root.")
    if resume:
        print(f"Finishes an earlier claim: {resume['node']} ({gb(size)}, the space macOS had) "
              f"goes into the btrfs root at {a.root} (now on {', '.join(devs)}).")
    else:
        print(f"Adds a new {gb(size)} Linux partition on {disk} at byte {start} "
              f"(the space macOS had) to the btrfs root at {a.root} (now on {', '.join(devs)}).")
    if a.dry_run:
        print("Dry run: nothing was changed.")
        return 0
    if not a.yes:
        if input("Type 'add' to continue: ").strip() != "add":
            print("Nothing was changed.")
            return 1
    if resume:
        new = resume
    else:
        ss = gpt["sector"]
        spec = f"start={start // ss}, size={size // ss}, type={LINUX}, name=\"{CLAIM_NAME}\"\n"
        run(["sfdisk", "--append", "--no-reread", "--no-tell-kernel", disk], input=spec)
        after = read_gpt(disk)
        added = [p for p in after["parts"] if p["uuid"] not in {q["uuid"] for q in gpt["parts"]}]
        kept = [(p["uuid"], p["start"], p["size"]) for p in after["parts"] if p not in added]
        if len(added) != 1 or added[0]["start"] != start or added[0]["size"] != size \
                or kept != [(p["uuid"], p["start"], p["size"]) for p in gpt["parts"]]:
            raise Refusal("The partition table didn't come out as planned; stop and check "
                          f"`sfdisk -l {disk}`.")
        new = added[0]
    node = new["node"]
    m = re.search(r"(\d+)$", node)
    if not m:
        raise Refusal(f"Couldn't tell the partition number of {node}; nothing more was changed.")
    wait_for_partition(disk, node, m.group(1), new["uuid"])
    if node not in devs:
        # The space held macOS's APFS container; clear its old signatures so
        # btrfs takes the partition. Only the new partition, verified above by
        # its place in the table and its GPT UUID, is touched.
        run(["wipefs", "--all", "--quiet", node])
        run(["btrfs", "device", "add", node, a.root])
        if node not in root_devices(a.root, disk):
            raise Refusal(f"btrfs didn't list {node} after adding it.")
    done = dict(record, phase="claimed", claimedPartitionUUID=new["uuid"],
                claimedNode=node, claimedSize=size)
    write_atomic(done_path, done)
    os.unlink(path)
    print(f"Added {gb(size)} to the root file system.")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="aurora-whole-disk", description=__doc__.split("\n")[0])
    ap.add_argument("--chosen", default="/proc/device-tree/chosen", help=argparse.SUPPRESS)
    ap.add_argument("--disk", help=argparse.SUPPRESS)
    ap.add_argument("--esp", help=argparse.SUPPRESS)
    ap.add_argument("--run-dir", default=RUN_DIR, help=argparse.SUPPRESS)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan", help="show what would be removed and kept (dry run)")
    m = sub.add_parser("move", help="at start, before /boot and the EFI partition are mounted: "
                       "move them and the startup container into the space macOS had")
    m.add_argument("--dry-run", action="store_true")
    m.add_argument("--yes", action="store_true", help="don't ask (the boot-time service)")
    m.add_argument("--root", default="/", help=argparse.SUPPRESS)
    c = sub.add_parser("claim", help="add the space Recovery freed to the root file system")
    c.add_argument("--dry-run", action="store_true")
    c.add_argument("--yes", action="store_true", help="don't ask (the boot-time service)")
    c.add_argument("--root", default="/", help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    try:
        return {"plan": cmd_plan, "move": cmd_move, "claim": cmd_claim}[a.cmd](a)
    except Refusal as e:
        print(f"aurora-whole-disk: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
