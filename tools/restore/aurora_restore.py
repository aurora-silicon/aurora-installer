#!/usr/bin/python3 -I
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 The Aurora Silicon Contributors
"""aurora-restore: put macOS back on this Mac from Aurora.

    aurora-restore list                       macOS versions Apple offers for this Mac
    aurora-restore plan VERSION [--replace]   what would change, step by step (dry run)
    aurora-restore apply VERSION [--replace]  prepare it (asks for a typed confirmation)
    aurora-restore cancel [--regrow]          remove a prepared request (and give the space back)
    aurora-restore dfu-help                   the second-computer restore (erases everything)

A Mac only starts a macOS that Apple's own installer set up: the installer
creates the APFS volumes, has Apple personalize the boot files for this Mac
and asks a machine owner to approve the new startup policy. None of that can
be done from Linux. So this tool decides and prepares, and Apple's installer
installs, run from this installation's Recovery:

  * Linux checks the version against Apple's Software Update catalog for this
    Mac's board (read from the device tree, never from a model list), makes
    room on the disk (``alongside``: shrinks the btrfs root) or plans to
    reuse Aurora's space (``--replace``), and writes a request and a script
    with every value spelled out to Aurora's EFI partition.
  * In Recovery the script checks the disk is still as planned, creates the
    macOS container, downloads the installer from Apple and starts it.

It never writes APFS, the startup security policy, NVRAM or the boot loader.
``list``, ``plan`` and ``--dry-run`` write nothing.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import plistlib
import re
import shlex
import sys
import time
import urllib.request

_here = os.path.dirname(os.path.abspath(__file__))
# Installed: the WHOLE-DISK disk rules and apfs_ro.py sit beside this file. In
# the repository they are tools/whole-disk/ and tools/wifi-firmware/.
sys.path[:0] = [_here, os.path.join(_here, "..", "whole-disk"),
                os.path.join(_here, "..", "wifi-firmware")]
import aurora_whole_disk as wd  # noqa: E402

Refusal = wd.Refusal
run = wd.run
gb = wd.gb

SCHEMA = 1
USER_AGENT = "aurora-restore/1"
GIB, MIB = 1 << 30, 1 << 20
# Newest first. Apple names the merged catalog after every major it covers;
# a catalog for a newer major also lists the older installers.
CATALOGS = [
    "https://swscan.apple.com/content/catalogs/others/index-{}-10.16-10.15-10.14-10.13-10.12-"
    "10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog".format(m)
    for m in ("28-27-26-15-14-13-12", "27-26-15-14-13-12", "26-15-14-13-12")
]
CACHE = "/var/cache/aurora-restore"
CACHE_SECONDS = 3600
REQUEST_DIR = "aurora/restore"
# macOS needs room for itself on top of the installer: Apple asks for about
# 35 GB free to install. The installer package and the app it installs each
# take the package's size until the install finishes.
MACOS_ROOM = 35 * 10**9
LINUX_MARGIN = 10 * GIB


# ------------------------------------------------------------------ machine


def read_board(dt="/proc/device-tree"):
    """This Mac's board, the ADT target-type the boot loader puts first in
    the device tree's compatible list (`apple,j314s` -> `J314sAP`)."""
    try:
        with open(os.path.join(dt, "compatible"), "rb") as f:
            entries = [e.decode("ascii", "replace") for e in f.read().split(b"\0") if e]
    except OSError:
        entries = []
    if not entries or not entries[0].startswith("apple,"):
        raise Refusal("The device tree doesn't name an Apple board; this only runs on an Apple "
                      "silicon Mac started by Aurora.")
    target = entries[0].split(",", 1)[1]
    if not re.fullmatch(r"[a-z]\d{3}[a-z]{0,2}", target):
        raise Refusal(f"The device tree's board {entries[0]!r} isn't an Apple target type.")
    return target[0].upper() + target[1:] + "AP"


# ------------------------------------------------------------------ catalog


def fetch(url, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def vkey(version):
    return tuple(int(x) for x in re.findall(r"\d+", version))


def parse_dist(text):
    title = re.search(r"<title>(.*?)</title>", text, re.S)
    keys = dict(re.findall(r"<key>(\w+)</key>\s*<string>(.*?)</string>", text))
    ids = re.search(r"supportedDeviceIDs\s*=\s*\[(.*?)\]", text, re.S)
    return {
        "title": title.group(1).strip() if title else "macOS",
        "version": keys.get("VERSION"),
        "build": keys.get("BUILD"),
        "devices": sorted({x.strip(" '\"\n\t") for x in ids.group(1).split(",")} - {""})
        if ids else [],
    }


def parse_catalog(catalog, get=fetch):
    """Every full macOS installer in an Apple Software Update catalog (plist
    bytes), with the boards its .dist accepts."""
    try:
        c = plistlib.loads(catalog)
    except (plistlib.InvalidFileException, ValueError) as e:
        raise Refusal(f"Apple's Software Update catalog isn't a property list: {e}") from e
    found = []
    for pid, p in c.get("Products", {}).items():
        pkg = [x for x in p.get("Packages", [])
               if x.get("URL", "").endswith("/InstallAssistant.pkg")]
        dists = p.get("Distributions", {})
        dist = dists.get("English") or dists.get("en") or next(iter(dists.values()), None)
        if len(pkg) != 1 or not dist:
            continue
        found.append((pid, p, pkg[0], dist))

    def one(item):
        pid, p, pkg, dist = item
        try:
            d = parse_dist(get(dist).decode("utf-8", "replace"))
        except OSError as e:
            raise Refusal(f"Couldn't read {dist} from Apple's server: {e}") from e
        if not d["version"] or not d["build"]:
            return None
        return {
            "product": pid, "version": d["version"], "build": d["build"], "title": d["title"],
            "url": pkg["URL"], "size": int(pkg["Size"]), "devices": d["devices"],
            "posted": p.get("PostDate").isoformat() if p.get("PostDate") else None,
        }

    with concurrent.futures.ThreadPoolExecutor(8) as ex:
        out = [x for x in ex.map(one, found) if x]
    out.sort(key=lambda x: (vkey(x["version"]), x["posted"] or ""))
    return out


def load_catalog(refresh=False, get=fetch, cache=CACHE):
    path = os.path.join(cache, "installers.json")
    if not refresh:
        try:
            if time.time() - os.path.getmtime(path) < CACHE_SECONDS:
                with open(path) as f:
                    return json.load(f)
        except (OSError, ValueError):
            pass
    errors = []
    for url in CATALOGS:
        try:
            data = get(url)
        except OSError as e:
            errors.append(f"{url}: {e}")
            continue
        installers = parse_catalog(data, get)
        if installers:
            record = {"catalog": url, "fetched": int(time.time()), "installers": installers}
            try:
                wd.write_atomic(path, record)
            except OSError:
                pass
            return record
    raise Refusal("Couldn't read Apple's Software Update catalog (is the network up?):\n  "
                  + "\n  ".join(errors))


def offered(installers, board, everything=False):
    """The installers for `board`. By default only the newest build of each
    major version: the ones Apple still offers and signs."""
    mine = [i for i in installers if board.lower() in {d.lower() for d in i["devices"]}]
    if everything:
        return mine
    best = {}
    for i in mine:
        best[vkey(i["version"])[0]] = i  # sorted ascending: the last one wins
    return [best[k] for k in sorted(best)]


def pick(installers, board, version):
    mine = offered(installers, board, everything=True)
    match = [i for i in mine if version in (i["version"], i["build"])]
    if not match and re.fullmatch(r"\d+", version):
        match = [i for i in offered(installers, board) if vkey(i["version"])[0] == int(version)]
    if not match:
        have = ", ".join(f"{i['version']} ({i['build']})" for i in offered(installers, board))
        raise Refusal(f"Apple offers no macOS {version} for this Mac ({board}). "
                      f"Available: {have or 'none'}.")
    newest = offered(installers, board)
    chosen = match[-1]
    chosen = dict(chosen, current=chosen in newest)
    return chosen


def check_manifest(installer, board):
    """Reads the installer's own BuildManifest from Apple's server with a few
    range requests (about 12 MB) and checks it carries this board. Anything
    unexpected from the server is a Refusal (this runs before any change)."""
    import zipfile

    import apple_remote as R

    try:
        return _check_manifest(installer, board, R, zipfile)
    except Refusal:
        raise
    except (R.RemoteError, OSError, StopIteration, KeyError, ValueError, EOFError,
            zipfile.BadZipFile, plistlib.InvalidFileException) as e:
        raise Refusal(f"Couldn't check the installer on Apple's server ({installer['url']}): "
                      f"{type(e).__name__}: {e}. Nothing was changed; try again later, or "
                      "--no-check to skip this check.") from e


def _check_manifest(installer, board, R, zipfile):
    f = R.HTTPFile(installer["url"])
    if f.size != installer["size"]:
        raise Refusal(f"Apple's server reports {f.size} bytes for the installer, the catalog "
                      f"{installer['size']}.")
    shared, _ = R.xar_open(f, "SharedSupport.dmg")
    disk = R.UDIFDisk(shared)
    part = next((p for p in R.gpt_partitions(disk) if p["type"] == R.HFS_TYPE), None)
    if part is None:
        raise Refusal("The installer's SharedSupport.dmg has no HFS+ partition.")
    vol = R.HFSVolume(R.Slice(disk, part["start"], part["size"]))
    folder = "/com_apple_MobileAsset_MacSoftwareUpdate"
    archives = [n for n, kind, _ in vol.listdir(folder) if kind == "file" and n.endswith(".zip")]
    if len(archives) != 1:
        raise Refusal(f"The installer holds {len(archives)} update archives, expected one.")
    z = zipfile.ZipFile(vol.open(f"{folder}/{archives[0]}"))
    manifest = plistlib.loads(z.read("AssetData/boot/BuildManifest.plist"))
    version = plistlib.loads(z.read("AssetData/boot/SystemVersion.plist"))
    classes = {bi.get("Info", {}).get("DeviceClass", "").lower()
               for bi in manifest.get("BuildIdentities", [])}
    if board.lower() not in classes:
        raise Refusal(f"The installer's BuildManifest has no identity for {board}.")
    if version.get("ProductBuildVersion") != installer["build"]:
        raise Refusal(f"The installer holds build {version.get('ProductBuildVersion')}, the "
                      f"catalog says {installer['build']}.")
    return {"requests": f.requests, "bytes": f.bytes_fetched, "classes": len(classes)}


# ------------------------------------------------------------------ disk


def needed_bytes(installer):
    raw = 2 * installer["size"] + MACOS_ROOM
    return -(-raw // GIB) * GIB


def btrfs_min_size(dev, root):
    out = run(["btrfs", "inspect-internal", "min-dev-size", "--id", dev_id(dev, root), root])
    m = re.match(r"\s*(\d+)", out)
    if not m:
        raise Refusal(f"Couldn't read the smallest size of {dev}: {out.strip()}")
    return int(m.group(1))


def dev_id(dev, root):
    for line in run(["btrfs", "filesystem", "show", root]).splitlines():
        m = re.match(r"\s*devid\s+(\d+)\s.*\spath\s+(\S+)", line)
        if m and os.path.realpath(m.group(2)) == os.path.realpath(dev):
            return m.group(1)
    raise Refusal(f"{dev} isn't a device of the root file system.")


def mounts_of(node):
    # -r escapes blanks in mount points (\\x20), so one target per word.
    return sorted(set(run(["findmnt", "-rn", "-o", "TARGET", "--source", node],
                          check=False).split()))


def fstab_targets(path="/etc/fstab"):
    """The mount points this system's own fstab lists."""
    return set(run(["findmnt", "--fstab", "--tab-file", path, "-rn", "-o", "TARGET"],
                   check=False).split())


def linux_parts(gpt, chosen, root_devs, mounts=mounts_of, fstab=None):
    """This installation's own partitions: its ESP, the root file system's
    devices and the Linux partitions it mounts from its own fstab. Another
    Linux partition is never included; one that is mounted somewhere else
    right now (another system's root on /mnt, say) is refused by name, since
    nothing tells whose it is."""
    roots = {os.path.realpath(d) for d in root_devs}
    ours = fstab if fstab is not None else fstab_targets()
    out = []
    for p in gpt["parts"]:
        m = mounts(p["node"])
        if p["uuid"] == chosen["esp"] or (p["type"] == wd.LINUX and (
                os.path.realpath(p["node"]) in roots or set(m) & ours)):
            out.append(dict(p, mounts=m))
        elif p["type"] == wd.LINUX and m:
            raise Refusal(f"{p['node']} ({p['uuid']}) is mounted at {', '.join(m)} but isn't in "
                          "this system's /etc/fstab, so it may be another system's. Unmount it "
                          "and plan again; it is then kept.")
    # The ESP goes last: restore.sh sits on it, and a rerun after an
    # interruption needs it until every other partition is gone.
    return sorted(out, key=lambda p: p["uuid"] == chosen["esp"])


def plan_alongside(gpt, chosen, layout, need, root="/", min_size=None, root_devs=None,
                   mounts=mounts_of, fstab=None):
    """Find or make an unallocated gap of `need` bytes. Returns the plan's
    disk part: the gap, its predecessor and the Linux changes. Only free
    space before System Recovery that follows an Apple container or one of
    this installation's partitions counts (classify() has checked that
    System Recovery is the last partition)."""
    parts = gpt["parts"]
    devs = root_devs if root_devs is not None else wd.root_devices(root)
    recovery = parts[-1]["start"]
    roots = {os.path.realpath(d) for d in devs}
    ours = None

    def usable(pred):
        nonlocal ours
        if pred["type"] in (wd.APFS, wd.ISC) or pred["uuid"] == chosen["esp"]:
            return True
        if pred["type"] != wd.LINUX:
            return False
        if os.path.realpath(pred["node"]) in roots:
            return True
        ours = ours if ours is not None else (fstab if fstab is not None else fstab_targets())
        return bool(set(mounts(pred["node"])) & ours)

    for start, size in wd.free_extents(gpt):
        if size < need or start + size > recovery:
            continue
        before = [p for p in parts if p["start"] + p["size"] <= start]
        if before and usable(before[-1]):
            return {"shrink": None, "gap": align_gap(start, size), "predecessor": before[-1]}
    if len(devs) != 1:
        raise Refusal(f"The root file system spans {len(devs)} partitions ({', '.join(devs)}). "
                      "Remove the extra device first (`btrfs device remove`), or use --replace.")
    node = os.path.realpath(devs[0])
    idx = next((i for i, p in enumerate(parts) if os.path.realpath(p["node"]) == node), None)
    if idx is None:
        raise Refusal(f"The root partition {devs[0]} isn't on {gpt['disk']}.")
    rp = parts[idx]
    end = rp["start"] + rp["size"]
    nxt = parts[idx + 1] if idx + 1 < len(parts) else None
    if nxt is None or nxt["type"] != wd.RECOVERY:
        raise Refusal("The root partition isn't followed by Apple's System Recovery, so shrinking "
                      "it wouldn't leave one free gap. Use --replace, or free space by hand.")
    after = nxt["start"] - end
    shrink_by = -(-(need - after) // MIB) * MIB
    new_size = rp["size"] - shrink_by
    floor = (min_size if min_size is not None else btrfs_min_size(node, root)) + LINUX_MARGIN
    if new_size < floor:
        raise Refusal(f"Linux needs at least {gb(floor)} ({gb(floor - LINUX_MARGIN)} in use + "
                      f"{gb(LINUX_MARGIN)}); making {gb(need)} for macOS would leave it "
                      f"{gb(max(new_size, 0))}. Free space in Linux, pick a smaller --size, or use "
                      "--replace.")
    gap_start = rp["start"] + new_size
    return {"shrink": {"node": rp["node"], "uuid": rp["uuid"], "from": rp["size"],
                       "to": new_size},
            "gap": align_gap(gap_start, nxt["start"] - gap_start), "predecessor": rp}


def plan_replace(gpt, chosen, layout, need, root_devs, mounts=mounts_of, fstab=None):
    """Aurora's Linux partitions, deleted in Recovery, plus any free space
    next to them, give macOS one gap."""
    lp = linux_parts(gpt, chosen, root_devs, mounts, fstab)
    if not lp:
        raise Refusal("No Aurora Linux partitions were found.")
    gone = {p["uuid"] for p in lp}
    parts = gpt["parts"]
    idx = [i for i, p in enumerate(parts) if p["uuid"] in gone]
    if idx != list(range(idx[0], idx[-1] + 1)):
        between = [parts[i]["node"] for i in range(idx[0], idx[-1] + 1) if i not in idx]
        raise Refusal("Aurora's Linux partitions aren't next to each other (in between: "
                      f"{', '.join(between)}, which isn't this installation's), so deleting them "
                      "wouldn't give one gap.")
    pred = parts[idx[0] - 1]
    nxt = parts[idx[-1] + 1] if idx[-1] + 1 < len(parts) else None
    start = pred["start"] + pred["size"]
    end = nxt["start"] if nxt else gpt["last"]
    if pred["type"] not in (wd.APFS, wd.ISC):
        raise Refusal(f"The partition before Aurora's ({pred['node']}) isn't an Apple container.")
    gap = align_gap(start, end - start)
    if gap[1] < need:
        raise Refusal(f"Aurora's partitions free {gb(gap[1])}; macOS {gb(need)} needs more.")
    return {"delete": lp, "gap": gap, "predecessor": pred}


def align_gap(start, size):
    s = -(-start // MIB) * MIB
    e = (start + size) // MIB * MIB
    return (s, max(0, e - s))


def owner_of(layout, chosen, owner=None):
    if owner:
        return owner(layout["own"]["node"])
    return wd.owner_state(layout["own"]["node"], chosen["group"])


def make_plan(installer, board, chosen, gpt, layout, mode, owner_state, size=None,
              root="/", min_size=None, root_devs=None, mounts=mounts_of, fstab=None):
    need = needed_bytes(installer)
    if size:
        if size < need:
            raise Refusal(f"--size {gb(size)} is less than macOS {installer['version']} needs "
                          f"({gb(need)}).")
        need = size
    if mode == "replace":
        devs = root_devs if root_devs is not None else wd.root_devices(root)
        disk = plan_replace(gpt, chosen, layout, need, devs, mounts, fstab)
    else:
        disk = plan_alongside(gpt, chosen, layout, need, root, min_size, root_devs, mounts,
                              fstab)
    if owner_state.get("account") and owner_state.get("problem") and not layout["macos"]:
        raise Refusal(
            f"This Mac has no macOS, and this installation's recovery account can't approve a new "
            f"macOS's startup policy yet: {owner_state['problem']}.")
    if not owner_state.get("account") and not layout["macos"]:
        raise Refusal(
            "This Mac has no macOS and this installation has no recovery account, so nobody can "
            "approve a new macOS's startup policy. Create the recovery account first (in "
            "Aurora's Recovery: Aurora Installer -> Utilities -> Create Recovery Account...), or "
            "use the second-computer restore: `aurora-restore dfu-help`.")
    container = disk["gap"][1] if mode == "replace" or not size else need
    label = f"macOS {installer['version']}"
    names = [wd.system_name(c) for c in [layout["own"]] + layout["others"]
             + ([layout["macos"]] if layout["macos"] else [])]
    if label in names:
        label += " (new)"
    plan = {
        "schema": SCHEMA, "mode": mode, "board": board,
        "installer": {k: installer[k] for k in ("version", "build", "title", "product", "url",
                                                "size")},
        "disk": gpt["disk"], "sector": gpt["sector"], "espUUID": chosen["esp"],
        "group": chosen["group"],
        "partitions": [{k: p[k] for k in ("node", "uuid", "type", "start", "size", "name")}
                       for p in gpt["parts"]],
        "predecessor": {k: disk["predecessor"][k] for k in ("node", "uuid", "start", "size")},
        "gap": {"start": disk["gap"][0], "size": disk["gap"][1]},
        "containerBytes": min(container, disk["gap"][1]),
        "label": label,
        "owner": owner_state.get("account"),
        "macos": wd.system_name(layout["macos"]) if layout["macos"] else None,
        "routes": native_routes(chosen),
        "own": layout["own"]["uuid"] if layout.get("own") else None,
        "shrink": disk.get("shrink"),
        "delete": [{k: p[k] for k in ("node", "uuid", "type", "start", "size", "mounts")}
                   for p in disk.get("delete", [])],
    }
    if plan["shrink"]:
        # The partition table after the shrink is what Recovery will check.
        for p in plan["partitions"]:
            if p["uuid"] == plan["shrink"]["uuid"]:
                p["size"] = plan["shrink"]["to"]
        plan["predecessor"]["size"] = plan["shrink"]["to"]
    plan["digest"] = digest(plan)
    return plan


def digest(plan):
    body = {k: v for k, v in plan.items() if k not in ("digest", "created")}
    return hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()[:16]


def phrase(plan):
    v = plan["installer"]["version"]
    return (f"replace Aurora with macOS {v}" if plan["mode"] == "replace"
            else f"install macOS {v} alongside Aurora")


def native_routes(chosen):
    """The recoveryOS this Mac already has and the macOS major its own
    "Reinstall macOS" offers, from the versions the boot loader reports:
    Aurora's paired Recovery runs the startup container's macOS
    (chosen/asahi,os-fw-version); System Recovery is updated with the system
    firmware (chosen/asahi,system-fw-version) and can't install below it."""
    out = []
    for key, name, how in (
            ("os_fw", "Aurora's Recovery",
             "shut down, press and hold the power button until “Loading startup options”, "
             "choose Options"),
            ("system_fw", "System Recovery",
             "shut down, press and release the power button, then at once press and hold it")):
        v = (chosen or {}).get(key)
        if v and re.match(r"\d+", v):
            out.append({"name": name, "how": how, "version": v, "major": vkey(v)[0]})
    return out


def native_note(routes, installer=None):
    """Lines saying which versions Recovery installs with no help from Linux."""
    L = []
    for r in routes:
        if installer and r["major"] != vkey(installer["version"])[0]:
            continue
        L.append(f"  {r['name']} ({r['version']}): “Reinstall macOS” installs the newest macOS "
                 f"{r['major']} itself ({r['how']}).")
    return L


def plan_text(plan):
    i = plan["installer"]
    L = [f"{i['title']} {i['version']} ({i['build']}) for this Mac ({plan['board']}), "
         f"from Apple: {i['url']} ({gb(i['size'])})."]
    L.append(f"Disk {plan['disk']}.")
    if plan["macos"]:
        L.append(f"Note: macOS “{plan['macos']}” is already on this disk; it stays.")
    L.append("")
    L.append("IN AURORA, NOW:")
    if plan["shrink"]:
        s = plan["shrink"]
        L.append(f"  1. Shrink the btrfs root file system and its partition {s['node']} from "
                 f"{gb(s['from'])} to {gb(s['to'])} (online; files are kept).")
        n = 2
    else:
        n = 1
        if plan["mode"] == "alongside":
            L.append("  (no change to Linux: the disk already has the free space)")
    L.append(f"  {n}. Write {REQUEST_DIR}/request.json and restore.sh to Aurora's EFI partition "
             f"({plan['espUUID']}).")
    L.append("")
    L.append("IN RECOVERY, AFTER YOU RESTART INTO IT:")
    L.append("  1. Check every partition is still as planned; otherwise stop with no change.")
    k = 2
    if plan["mode"] == "replace":
        L.append(f"  {k}. DELETE Aurora's Linux partitions, with all their data (the EFI partition, "
                 "which holds this script, last):")
        for p in plan["delete"]:
            what = ", ".join(p["mounts"]) or ("EFI" if p["uuid"] == plan["espUUID"] else "")
            L.append(f"       {p['node']}  {gb(p['size'])}  {what}  ({p['uuid']})")
        L.append("       If this stops part-way, run the script again: it carries on from the "
                 "partitions already deleted.")
        k += 1
    g = plan["gap"]
    L.append(f"  {k}. Create an APFS container “{plan['label']}” of "
             f"{gb(plan['containerBytes'])} after {plan['predecessor']['node']} (at byte {g['start']}).")
    L.append(f"  {k + 1}. Check diskutil put it in that free space, copy this script into it "
             "(to rerun from there), download the installer from Apple into it, install it with "
             "Apple's installer (signature checked) and start it.")
    L.append(f"  {k + 2}. Apple's installer installs macOS {i['version']}; it asks for "
             + (f"the machine owner ({plan['owner']}) " if plan["owner"] else "a machine owner ")
             + "to approve the new startup disk.")
    aurora = next((r for r in plan.get("routes", []) if r["name"] == "Aurora's Recovery"), None)
    if aurora and vkey(i["version"])[0] > vkey(aurora["version"])[0]:
        L.append("")
        L.append(f"UNPROVEN: macOS {i['version']} is newer than Aurora's Recovery "
                 f"({aurora['version']}), where the script runs. Apple's installer app may need a "
                 "newer Recovery to start; if it refuses, the container is left with the installer "
                 "in it: use System Recovery instead (shut down, press and release the power "
                 "button, then at once press and hold it) and in its Terminal run "
                 f"sh \"/Volumes/{plan['label']}/.aurora-restore/restore.sh\" (it resumes).")
    if aurora and vkey(i["version"]) < vkey(aurora["version"]):
        L.append("")
        L.append(f"UNPROVEN: macOS {i['version']} is older than Aurora's Recovery "
                 f"({aurora['version']}), where the script runs. Apple's installer may refuse an older macOS there; if it "
                 "does, it stops before installing and the new container holds only the download "
                 "(delete it in Disk Utility).")
    native = native_note(plan.get("routes", []), i)
    if native:
        L.append("")
        room = ("the disk already has room for it" if plan["mode"] == "alongside"
                and not plan["shrink"] else
                "once the disk has room for it (the shrink above, or --replace in Recovery)")
        L.append(f"WITHOUT THE SCRIPT: Recovery can install macOS {vkey(i['version'])[0]} by "
                 f"itself; {room}:")
        L += native
    L.append("")
    L.append("KEPT, unchanged:")
    gone = {p["uuid"] for p in plan["delete"]}
    for p in plan["partitions"]:
        if p["uuid"] in gone:
            continue
        if p["uuid"] == plan.get("own"):
            what = "Aurora's startup container (its boot stub and Aurora's Recovery)"
            if plan["mode"] == "replace":
                what += (": it stays because the script runs from its Recovery. With Linux gone "
                         "it starts nothing; once the new macOS works, delete it in Disk Utility "
                         "(View -> Show All Devices, select it, click -) or with `diskutil apfs "
                         "deleteContainer diskNsM` (its identifier in `diskutil list`)")
            L.append(f"  {p['node']}  {gb(p['size'])}  {what}")
            continue
        what = {wd.ISC: "Apple system container (iSC)", wd.RECOVERY: "Apple System Recovery",
                wd.EFI: "EFI partition", wd.APFS: "APFS container"}.get(p["type"], p["type"])
        if plan["shrink"] and p["uuid"] == plan["shrink"]["uuid"]:
            what = "Linux root (shrunk, files kept)"
        elif p["type"] == wd.LINUX:
            what = "Linux"
        L.append(f"  {p['node']}  {gb(p['size'])}  {what}")
    return "\n".join(L)


# ------------------------------------------------------------------ recovery script


def q(s):
    return shlex.quote(str(s))


def recovery_script(plan):
    """The script Recovery runs: plain sh, every value written in, only
    Apple's own tools (diskutil, curl, installer)."""
    i = plan["installer"]
    gone = {p["uuid"] for p in plan["delete"]}
    kept = "\n".join(f"check_part {q(p['uuid'])} {p['start']} {p['size']}"
                     for p in plan["partitions"] if p["uuid"] not in gone)
    doomed = "\n".join(f"    doomed_part {q(p['uuid'])} {p['start']} {p['size']}"
                       for p in plan["delete"])
    deletes = "\n".join(f"        delete_part {q(p['uuid'])} {p['start']} {p['size']}"
                        for p in plan["delete"])
    kept_count = len(plan["partitions"]) - len(gone)
    pred_end = plan["predecessor"]["start"] + plan["predecessor"]["size"]
    return f"""#!/bin/sh
# aurora-restore {plan['digest']}: install {i['title']} {i['version']} ({i['build']}).
# Written by aurora-restore in Aurora; run in this Mac's Recovery (Terminal).
# Every value is fixed here; nothing is read from elsewhere.
set -eu
MODE={q(plan['mode'])}
VERSION={q(i['version'])}
URL={q(i['url'])}
PKG_SIZE={i['size']}
LABEL={q(plan['label'])}
PRED_UUID={q(plan['predecessor']['uuid'])}
GAP_START={plan['gap']['start']}
GAP_SIZE={plan['gap']['size']}
CONTAINER_BYTES={plan['containerBytes']}
OWNER={q(plan['owner'] or '')}
KEPT_COUNT={kept_count}
PRED_END={pred_end}
ESP_UUID={q(plan['espUUID'])}
DIGEST={q(plan['digest'])}
CONFIRM={q(phrase(plan))}
UNATTENDED=0
CHECK=0
case "${{1:-}}" in
    --unattended) UNATTENDED=1 ;;
    --check) CHECK=1 ;;
    "") ;;
    *) printf '%s\\n' "usage: restore.sh [--check | --unattended]"; exit 2 ;;
esac

# Run from a copy in RAM: with --replace the EFI partition this file sits on
# is deleted, and sh reads a script as it goes.
self="/tmp/aurora-restore-$DIGEST.sh"
if [ "$0" != "$self" ]; then
    cp "$0" "$self" && exec sh "$self" "$@"
    printf '%s\\n' "aurora-restore: couldn't copy myself to $self"; exit 1
fi

say() {{ printf '%s\\n' "aurora-restore: $*"; }}
die() {{ say "$*"; say "Stopped."; exit 1; }}
pint() {{ # pint KEY: an integer from `diskutil info -plist` on stdin
    awk -v k="<key>$1</key>" '$0 ~ k {{ getline; gsub(/[^0-9]/, ""); print; exit }}'
}}
pbool() {{ # pbool KEY: true, false or empty
    awk -v k="<key>$1</key>" '$0 ~ k {{ getline; if ($0 ~ /<true\\/>/) print "true"; else if ($0 ~ /<false\\/>/) print "false"; exit }}'
}}
pstr() {{
    awk -v k="<key>$1</key>" '$0 ~ k {{ getline; sub(/^[^>]*>/, ""); sub(/<.*$/, ""); print; exit }}'
}}
DISK=
part_ids() {{ diskutil list -plist "$DISK" | grep -o "<string>${{DISK}}s[0-9]*</string>" | sed 's/<[^>]*>//g' | sort -u; }}
same_place() {{ # INFO START SIZE UUID
    off=$(printf '%s' "$1" | pint PartitionMapPartitionOffset)
    size=$(printf '%s' "$1" | pint Size)
    whole=$(printf '%s' "$1" | pstr ParentWholeDisk)
    [ "$off" = "$2" ] || die "partition $4 moved (offset $off, planned $2)"
    [ "$size" = "$3" ] || die "partition $4 changed size ($size, planned $3)"
    [ -z "$DISK" ] && DISK=$whole
    [ "$whole" = "$DISK" ] || die "partition $4 is on $whole, not $DISK"
    # A clone of this disk (same partition GUIDs) on an external drive is not it.
    [ "$(printf '%s' "$1" | pbool Internal)" = true ] || die "partition $4 is on $whole, which isn't this Mac's internal disk; disconnect other drives and $(rerun)"
}}
check_part() {{ # UUID START SIZE: the partition is where the plan has it
    info=$(diskutil info -plist "$1" 2>/dev/null) || die "partition $1 is missing"
    same_place "$info" "$2" "$3" "$1"
}}
PRESENT=0
doomed_part() {{ # UUID START SIZE: still where planned, or already deleted by an
    # earlier run of this script. Every partition on the disk is accounted for
    # by the count below, so a deleted one's range is free space.
    if info=$(diskutil info -plist "$1" 2>/dev/null); then
        same_place "$info" "$2" "$3" "$1"
        PRESENT=$((PRESENT + 1))
    else
        say "$1 is already deleted (an earlier run)"
    fi
}}
ident() {{ diskutil info -plist "$1" | pstr DeviceIdentifier; }}
delete_part() {{ # UUID START SIZE
    info=$(diskutil info -plist "$1" 2>/dev/null) || return 0
    same_place "$info" "$2" "$3" "$1"
    id=$(printf '%s' "$info" | pstr DeviceIdentifier)
    say "deleting $id ($1)"
    diskutil eraseVolume free none "$id" || die "couldn't delete $id; $(rerun)"
}}
rerun() {{ # how to run this script again, from where it is now
    if [ -f "$VOL/.aurora-restore/restore.sh" ]; then
        printf '%s' "run it again: sh \\"$VOL/.aurora-restore/restore.sh\\""
    elif diskutil info -plist "$ESP_UUID" >/dev/null 2>&1; then
        printf '%s' "run the same Terminal line again"
    else
        printf '%s' "run it again now: sh $self (this copy is gone once the Mac restarts; then create an APFS partition in the free space with Disk Utility and use Reinstall macOS)"
    fi
}}

command -v diskutil >/dev/null || die "run this in macOS Recovery (Terminal)"
say "checking the disk"
VOL="/Volumes/$LABEL"
RESUME=0
if [ -f "$VOL/.aurora-restore/plan" ] && [ "$(cat "$VOL/.aurora-restore/plan")" = "$DIGEST" ]; then
    RESUME=1
    say "resuming: $VOL was made by this script"
fi
{kept or ':'}
want=$KEPT_COUNT
if [ $RESUME = 0 ]; then
{doomed or '    :'}
    want=$((KEPT_COUNT + PRESENT))
else
    want=$((KEPT_COUNT + 1))
fi
n=$(part_ids | wc -l | tr -d ' ')
if [ $RESUME = 0 ] && [ "$n" = $((want + 1)) ] && [ "$PRESENT" = 0 ] && [ -d "$VOL" ]; then
    die "$VOL exists but this script didn't record it (stopped right after creating it?). If it is empty, delete it in Disk Utility, then $(rerun)"
fi
if [ $RESUME = 0 ] && [ -e "$VOL" ]; then
    die "$VOL already exists (another drive or volume named “$LABEL”?): eject or rename it, then $(rerun)"
fi
mounted_here() {{ # the volume at $VOL is mounted there and is on the internal disk
    vinfo=$(diskutil info -plist "$VOL" 2>/dev/null) || return 1
    [ "$(printf '%s' "$vinfo" | pstr MountPoint)" = "$VOL" ] &&
        [ "$(printf '%s' "$vinfo" | pbool Internal)" != false ]
}}
if [ $RESUME = 1 ]; then
    mounted_here || die "$VOL isn't a volume on this Mac's internal disk; disconnect other drives and $(rerun)"
fi
[ "$n" = "$want" ] || die "$DISK has $n partitions; the plan has $want"
[ $((GAP_START + GAP_SIZE)) -gt "$GAP_START" ] || die "bad plan"
say "checking the network"
curl -fsIL --max-time 30 "$URL" >/dev/null || die "Apple's server isn't reachable: join a network (Wi-Fi menu) and $(rerun)"

cat <<'PLAN'
{plan_text(plan)}
PLAN
if [ $CHECK = 1 ]; then
    say "check passed: the disk is as planned and Apple's server answers. Nothing was changed."
    exit 0
fi
printf 'Type "%s" to continue: ' "$CONFIRM"
read -r answer || die "no answer; nothing was changed"
[ "$answer" = "$CONFIRM" ] || die "not confirmed; nothing was changed"

if [ $RESUME = 0 ]; then
    if [ "$MODE" = replace ]; then
{deletes or '        :'}
    fi
    pred=$(ident "$PRED_UUID")
    say "creating $LABEL after $pred"
    diskutil addPartition "$pred" APFS "$LABEL" "${{CONTAINER_BYTES}}B" || die "couldn't create the container; $(rerun)"
    # Where diskutil put it: inside the planned free space, after the predecessor.
    new=
    for id in $(part_ids); do
        info=$(diskutil info -plist "$id")
        off=$(printf '%s' "$info" | pint PartitionMapPartitionOffset)
        size=$(printf '%s' "$info" | pint Size)
        if [ "$off" -ge "$PRED_END" ] && [ "$off" -lt $((GAP_START + GAP_SIZE)) ]; then
            [ -z "$new" ] || die "more than one partition in the planned free space"
            new=$id; new_end=$((off + size))
        fi
    done
    [ -n "$new" ] || die "the new container isn't in the planned free space; check Disk Utility"
    [ "$new_end" -le $((GAP_START + GAP_SIZE)) ] || die "$new ends past the planned free space (byte $new_end); delete it in Disk Utility"
    mounted_here || die "the new container's volume isn't mounted at $VOL; check Disk Utility"
    mkdir -p "$VOL/.aurora-restore"
    printf '%s\\n' "$DIGEST" > "$VOL/.aurora-restore/plan"
    cp "$self" "$VOL/.aurora-restore/restore.sh"
fi
installed_app() {{ # the installer app an earlier run installed, if complete
    app=$(ls -d "$VOL"/Applications/Install\\ macOS*.app 2>/dev/null | head -n 1)
    # Apple's package links (or copies) itself in as SharedSupport.dmg.
    [ -n "$app" ] && [ -f "$app/Contents/SharedSupport/SharedSupport.dmg" ] &&
        [ "$(stat -f %z "$app/Contents/SharedSupport/SharedSupport.dmg")" = "$PKG_SIZE" ] &&
        printf '%s' "$app"
}}
if APP=$(installed_app); then
    say "$APP is already installed (an earlier run); not downloading it again"
else
    PKG="$VOL/.aurora-restore/InstallAssistant.pkg"
    say "downloading macOS $VERSION from Apple ($PKG_SIZE bytes)"
    tries=0
    until curl -fL --retry 5 --speed-limit 1024 --speed-time 120 -C - -o "$PKG" "$URL"; do
        tries=$((tries + 1)); [ $tries -lt 5 ] || die "download failed; $(rerun) to resume"
        sleep 5
    done
    got=$(stat -f %z "$PKG")
    [ "$got" = "$PKG_SIZE" ] || die "downloaded $got bytes, expected $PKG_SIZE; delete “$PKG” and $(rerun)"
    say "installing the installer (Apple checks its signature)"
    installer -pkg "$PKG" -target "$VOL" || die "Apple's installer refused the package. Only $VOL was changed; to undo, delete “$LABEL” in Disk Utility"
    APP=$(installed_app) || die "the installer app wasn't installed completely; $(rerun)"
    rm -f "$PKG"
fi
if [ $UNATTENDED = 1 ]; then
    # Apple's license is the user's to accept: show it and ask.
    "$APP/Contents/Resources/startosinstall" --license || die "couldn't show Apple's license"
    printf '%s' 'Type "agree" to accept the license above: '
    read -r answer || die "no answer; nothing more was changed"
    [ "$answer" = agree ] || die "license not accepted; nothing more was changed. $(rerun), or start $APP"
    say "starting $APP (unattended)"
    exec "$APP/Contents/Resources/startosinstall" --agreetolicense --volume "$VOL" \\
        ${{OWNER:+--user "$OWNER"}} --passprompt
fi
say "starting $APP: choose “$LABEL” as the disk"
for bin in "$APP"/Contents/MacOS/*; do
    [ -x "$bin" ] && exec "$bin"
done
die "couldn't start $APP"
"""


def recovery_line(plan):
    return (f"sh \"$(diskutil mount {plan['espUUID']} >/dev/null; diskutil info "
            f"{plan['espUUID']} | sed -n 's/^ *Mount Point: *//p')/{REQUEST_DIR}/restore.sh\"")


# ------------------------------------------------------------------ commands


def gather(a):
    chosen = wd.read_chosen(a.chosen)
    board = a.board or read_board(a.dt)
    disk = a.disk or wd.disk_of(chosen["esp"])
    gpt = wd.read_gpt(disk)
    layout = wd.classify(gpt, chosen)
    return chosen, board, gpt, layout


def cmd_list(a):
    board = a.board or read_board(a.dt)
    cat = load_catalog(a.refresh, cache=a.cache)
    rows = offered(cat["installers"], board, a.all)
    print(f"macOS for this Mac ({board}), from Apple's Software Update catalog:")
    newest = offered(cat["installers"], board)
    for i in rows:
        mark = "" if i in newest else "   (older build: Apple may refuse to install it)"
        print(f"  {i['version']:<9} {i['build']:<9} {i['title']:<26} {gb(i['size']):>8}{mark}")
    if not rows:
        print("  none")
    try:
        routes = native_routes(wd.read_chosen(a.chosen))
    except Refusal:
        routes = []
    if routes:
        print("\nWith no change from Linux, Recovery's own “Reinstall macOS” offers (it needs free "
              "space or a macOS container to install into):")
        print("\n".join(native_note(routes)))
    print("\nAny version above: sudo aurora-restore plan <version>")
    return 0


def build(a):
    chosen, board, gpt, layout = gather(a)
    cat = load_catalog(a.refresh, cache=a.cache)
    inst = pick(cat["installers"], board, a.version)
    if not inst["current"] and not a.older:
        raise Refusal(f"{inst['version']} ({inst['build']}) is not the newest {vkey(inst['version'])[0]}.x "
                      "build; Apple usually refuses to install those. Add --older to try anyway.")
    state = owner_of(layout, chosen, a.owner_fn)
    plan = make_plan(inst, board, chosen, gpt, layout, "replace" if a.replace else "alongside",
                     state, size=a.size, root=a.root, fstab=fstab_targets(a.fstab))
    if not a.no_check:
        info = check_manifest(inst, board)
        print(f"Checked the installer on Apple's server: BuildManifest has {board} "
              f"({info['requests']} requests, {info['bytes'] / 1e6:.1f} MB).")
    return chosen, plan


def cmd_plan(a):
    _, plan = build(a)
    print(plan_text(plan))
    if a.show_script:
        print("\n----- restore.sh -----\n" + recovery_script(plan))
    print(f"\nTo do it: sudo aurora-restore apply {a.version}" + (" --replace" if a.replace else ""))
    print("Dry run: nothing was changed.")
    return 0


def shrink(plan, root):
    s = plan["shrink"]
    devid = dev_id(s["node"], root)
    run(["btrfs", "filesystem", "resize", f"{devid}:{s['to']}", root])
    ss = plan["sector"]
    start = next(p["start"] for p in plan["partitions"] if p["uuid"] == s["uuid"])
    number = re.search(r"(\d+)$", s["node"]).group(1)
    run(["sfdisk", "--no-reread", "--no-tell-kernel", "-N", number, plan["disk"]],
        input=f"{start // ss},{s['to'] // ss}\n")
    run(["partx", "--update", "--nr", number, plan["disk"]])
    run(["udevadm", "settle"], check=False)
    got = int(run(["blockdev", "--getsize64", s["node"]]).strip())
    if got != s["to"]:
        raise Refusal(f"{s['node']} is {got} bytes after the shrink, planned {s['to']}; check "
                      f"`sfdisk -l {plan['disk']}` before restarting.")


def cmd_apply(a):
    chosen, plan = build(a)
    print(plan_text(plan))
    if a.dry_run:
        print("\nDry run: nothing was changed.")
        return 0
    want = phrase(plan)
    if not a.yes:
        print(f"\nType \"{want}\" to continue:")
        if input("> ").strip() != want:
            print("Not confirmed; nothing was changed.")
            return 1
    # Re-read the disk: act only on the layout that was shown.
    _, again = build(argparse.Namespace(**{**vars(a), "no_check": True}))
    if again["digest"] != plan["digest"]:
        raise Refusal("The disk changed since the plan was shown; nothing was changed. Run it "
                      "again.")
    esp = a.esp or wd.esp_mount(chosen["esp"])
    if plan["shrink"]:
        print(f"Shrinking {plan['shrink']['node']} ...")
        shrink(plan, a.root)
    after = wd.read_gpt(plan["disk"])
    have = [(p["uuid"], p["start"], p["size"]) for p in after["parts"]]
    if have != [(p["uuid"], p["start"], p["size"]) for p in plan["partitions"]]:
        raise Refusal(f"The partition table isn't as planned; check `sfdisk -l {plan['disk']}`.")
    plan["created"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    d = os.path.join(esp, REQUEST_DIR)
    wd.write_atomic(os.path.join(d, "request.json"), plan)
    tmp = os.path.join(d, "restore.sh.tmp")
    with open(tmp, "w") as f:
        f.write(recovery_script(plan))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, os.path.join(d, "restore.sh"))
    print(f"""
Ready. Now:
  1. Shut down this Mac.
  2. Press and hold the power button until “Loading startup options” appears, choose Options,
     then Continue (log in if asked).
  3. Join a network (Wi-Fi menu, top right), then Utilities -> Terminal and type:

       {recovery_line(plan)}

  It checks the disk, asks you to type "{want}" again, then installs macOS {plan['installer']['version']}.
To undo before that: sudo aurora-restore cancel""")
    return 0


def regrow_plan(gpt, root, root_devs=None):
    """The btrfs root partition and the free space right after it."""
    devs = root_devs if root_devs is not None else wd.root_devices(root)
    if len(devs) != 1:
        raise Refusal("The root file system spans several partitions; grow it by hand.")
    node = os.path.realpath(devs[0])
    parts = gpt["parts"]
    idx = next((i for i, p in enumerate(parts) if os.path.realpath(p["node"]) == node), None)
    if idx is None:
        raise Refusal(f"The root partition {devs[0]} isn't on {gpt['disk']}.")
    rp = parts[idx]
    end = parts[idx + 1]["start"] if idx + 1 < len(parts) else gpt["last"]
    free = (end - rp["start"] - rp["size"]) // MIB * MIB
    return rp, free


def cmd_cancel(a):
    chosen = wd.read_chosen(a.chosen)
    esp = a.esp or wd.esp_mount(chosen["esp"])
    d = os.path.join(esp, REQUEST_DIR)
    gone = [n for n in ("request.json", "restore.sh") if os.path.exists(os.path.join(d, n))]
    if a.dry_run:
        print(f"Would remove: {', '.join(gone) or 'nothing (no request)'}.")
    else:
        for n in gone:
            os.unlink(os.path.join(d, n))
        print("Removed the request." if gone else "There is no request.")
    disk = a.disk or wd.disk_of(chosen["esp"])
    gpt = wd.read_gpt(disk)
    rp, free = regrow_plan(gpt, a.root)
    if free < GIB:
        return 0
    if not a.regrow:
        print(f"{gb(free)} after the root partition {rp['node']} is free; `aurora-restore cancel "
              "--regrow` gives it back to Linux.")
        return 0
    print(f"Grow {rp['node']} and the btrfs root by {gb(free)} (to {gb(rp['size'] + free)}).")
    if a.dry_run:
        print("Dry run: nothing was changed.")
        return 0
    ss = gpt["sector"]
    number = re.search(r"(\d+)$", rp["node"]).group(1)
    run(["sfdisk", "--no-reread", "--no-tell-kernel", "-N", number, disk],
        input=f"{rp['start'] // ss},{(rp['size'] + free) // ss}\n")
    run(["partx", "--update", "--nr", number, disk])
    run(["udevadm", "settle"], check=False)
    got = int(run(["blockdev", "--getsize64", rp["node"]]).strip())
    if got != rp["size"] + free:
        raise Refusal(f"{rp['node']} is {got} bytes, expected {rp['size'] + free}; check "
                      f"`sfdisk -l {disk}`.")
    run(["btrfs", "filesystem", "resize", f"{dev_id(rp['node'], a.root)}:max", a.root])
    print("Done.")
    return 0


def cmd_dfu(a):
    print("""Repair or restore from a second computer, over USB-C in DFU mode.

  REVIVE keeps your data: it reinstalls the Mac's firmware and recoveryOS (including System
  Recovery) and leaves the disk's partitions alone. Use it when Recovery itself is broken.
  RESTORE ERASES THE WHOLE DISK, Aurora included, and installs the newest macOS and firmware.

  * Another Mac: Apple's guide, https://support.apple.com/en-us/108900 (Finder or Apple
    Configurator: "Revive" or "Restore").
  * A Linux computer: idevicerestore built from libimobiledevice's current sources (distribution
    packages from before 2026-11 are too old for macOS 27). Get the newest restore image for this
    Mac from Apple (https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml
    lists it per model), connect the DFU port with a USB-C data cable, put the Mac into DFU with
    the key combination in Apple's guide, then:

        idevicerestore --restore-mode UniversalMac_<version>_<build>_Restore.ipsw          (revive; not yet tried from Linux)
        idevicerestore --erase --restore-mode UniversalMac_<version>_<build>_Restore.ipsw  (restore; proven 2026-11)
""")
    return 0


def size_arg(s):
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([GT]?)B?", s.strip(), re.I)
    if not m:
        raise argparse.ArgumentTypeError("use e.g. 80G or 1T")
    mult = {"": GIB, "G": GIB, "T": 1 << 40}[m.group(2).upper()]
    return int(float(m.group(1)) * mult)


def main(argv=None, owner_fn=None):
    ap = argparse.ArgumentParser(prog="aurora-restore", description=__doc__.split("\n")[0])
    ap.add_argument("--chosen", default="/proc/device-tree/chosen", help=argparse.SUPPRESS)
    ap.add_argument("--dt", default="/proc/device-tree", help=argparse.SUPPRESS)
    ap.add_argument("--board", help=argparse.SUPPRESS)
    ap.add_argument("--disk", help=argparse.SUPPRESS)
    ap.add_argument("--esp", help=argparse.SUPPRESS)
    ap.add_argument("--root", default="/", help=argparse.SUPPRESS)
    ap.add_argument("--fstab", default="/etc/fstab", help=argparse.SUPPRESS)
    ap.add_argument("--cache", default=CACHE, help=argparse.SUPPRESS)
    ap.add_argument("--refresh", action="store_true", help="re-read Apple's catalog now")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("list", help="macOS versions Apple offers for this Mac")
    s.add_argument("--all", action="store_true", help="also older builds")
    for name, hlp in (("plan", "what would change (dry run)"), ("apply", "prepare it")):
        s = sub.add_parser(name, help=hlp)
        s.add_argument("version", help="e.g. 27.2.1, 26 (newest 26.x) or a build like 26B131")
        s.add_argument("--replace", action="store_true",
                       help="delete Aurora's Linux partitions in Recovery and give macOS that space")
        s.add_argument("--size", type=size_arg, help="size of the macOS container (alongside)")
        s.add_argument("--older", action="store_true", help="allow an older build")
        s.add_argument("--no-check", action="store_true", help=argparse.SUPPRESS)
        if name == "plan":
            s.add_argument("--show-script", action="store_true", help="print restore.sh too")
        else:
            s.add_argument("--dry-run", action="store_true")
            s.add_argument("--yes", action="store_true", help=argparse.SUPPRESS)
    s = sub.add_parser("cancel", help="remove a prepared request")
    s.add_argument("--regrow", action="store_true",
                   help="also give the free space after the root partition back to Linux")
    s.add_argument("--dry-run", action="store_true")
    sub.add_parser("dfu-help", help="restore from a second computer (erases everything)")
    a = ap.parse_args(argv)
    a.owner_fn = owner_fn
    try:
        return {"list": cmd_list, "plan": cmd_plan, "apply": cmd_apply, "cancel": cmd_cancel,
                "dfu-help": cmd_dfu}[a.cmd](a)
    except Refusal as e:
        print(f"aurora-restore: {e}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("\nInterrupted; nothing more was changed.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
