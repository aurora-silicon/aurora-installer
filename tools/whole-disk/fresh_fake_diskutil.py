#!/usr/bin/env python3
"""A stand-in for diskutil and newfs_msdos on one disk image, for
fresh-install-test.py. Only what aurora-fresh-install calls:

  diskutil list -plist disk0 | info -plist ID | apfs list -plist
           apfs listVolumeGroups -plist | apfs deleteContainer REF
           addPartition PREDECESSOR (apfs LABEL | %EFI% %noformat% | %Linux% %noformat%) BYTES
  newfs_msdos -F 32 -v LABEL [-I ID] /dev/rdisk0sN

Partition N is GPT entry N. The APFS view (which container holds which
volumes) lives in STATE beside the image. STATE["crash"], when set to a
command word, makes that command do its work and then exit 137, as if
Recovery stopped right after the change; it is then cleared.

usage: fresh_fake_diskutil.py IMAGE STATE (diskutil|newfs_msdos) ARGS...
"""

import json
import os
import plistlib
import subprocess
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aurora_whole_disk as wd  # noqa: E402

SS = 4096
TYPES = {wd.ISC: "Apple_APFS_ISC", wd.APFS: "Apple_APFS", wd.RECOVERY: "Apple_APFS_Recovery",
         wd.EFI: "EFI", wd.LINUX: "Linux Filesystem"}
ADD = {"apfs": wd.APFS, "%EFI%": wd.EFI, "%Linux%": wd.LINUX}
VOLS = {"isc": [("iSCPreboot", "Preboot"), ("xART", "xART"), ("Hardware", "Hardware")],
        "sfr": [("Recovery", "Recovery")],
        "macos": [("Macintosh HD", "System"), ("Data", "Data"), ("Preboot", "Preboot"),
                  ("Recovery", "Recovery"), ("Update", "Update"), ("VM", "VM")],
        "stub": [("Aurora", "System"), ("Aurora - Data", "Data"), ("Preboot", "Preboot"),
                 ("Recovery", "Recovery")]}


def die(msg, code=1):
    sys.stderr.write(msg + "\n")
    sys.exit(code)


def table(image):
    size = os.path.getsize(image)
    io = wd.FileIO(image)
    try:
        return wd.gpt_load(io, SS, size), size
    finally:
        io.close()


def entries(image):
    t, _ = table(image)
    return [(i, wd.entry_info(e)) for i, e in enumerate(t["entries"]) if e[:16] != wd.ZERO_GUID]


def store(image, fn):
    t, _ = table(image)
    ents = fn([bytes(e) for e in t["entries"]], t)
    io = wd.FileIO(image)
    try:
        wd.gpt_store(io, t, ents)
    finally:
        io.close()


def out(obj):
    sys.stdout.buffer.write(plistlib.dumps(obj))


def u5(*parts):
    return str(uuid.uuid5(uuid.NAMESPACE_OID, "/".join(parts))).upper()


def main():
    image, state_path, prog, *args = sys.argv[1:]
    state = json.load(open(state_path))
    parts = entries(image)
    by_id = {f"disk0s{i + 1}": x for i, x in parts}

    def crash(word):
        if state.get("crash") == word:
            state["crash"] = None
            json.dump(state, open(state_path, "w"))
            die("stand-in stopped right after " + word, 137)

    if prog == "newfs_msdos":
        dev = args[-1]
        ident = dev.removeprefix("/dev/r")
        x = by_id.get(ident)
        if not x or x["type"] != wd.EFI:
            die(f"newfs_msdos: {dev} is not an EFI partition here")
        label = args[args.index("-v") + 1]
        vid = args[args.index("-I") + 1] if "-I" in args else None
        size = (x["last"] + 1 - x["first"]) * SS
        tmp = image + ".fat"
        with open(tmp, "wb") as f:
            f.truncate(size)
        cmd = ["mkfs.vfat", "-F", "32", "-n", label, tmp]
        if vid:
            cmd[1:1] = ["-i", vid.removeprefix("0x")]
        subprocess.run(cmd, check=True, capture_output=True)
        fd = os.open(image, os.O_RDWR)
        try:
            with open(tmp, "rb") as f:
                os.pwrite(fd, f.read(), x["first"] * SS)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.unlink(tmp)
        state.setdefault("log", []).append("newfs_msdos " + ident)
        json.dump(state, open(state_path, "w"))
        crash("newfs_msdos")
        return

    kinds = state["kinds"]
    if args[:2] == ["list", "-plist"] and args[2:] == ["disk0"]:
        out({"AllDisksAndPartitions": [{
            "DeviceIdentifier": "disk0", "Content": "GUID_partition_scheme",
            "Partitions": [{"DeviceIdentifier": k} for k in sorted(by_id, key=lambda k: by_id[k]["first"])]}]})
    elif args[:2] == ["info", "-plist"]:
        ident = args[2]
        if ident == "disk0":
            out({"DeviceIdentifier": "disk0", "Size": table(image)[1], "Internal": True})
        elif ident == "/":
            # recoveryOS's root: a RAM disk, or (state "root" = "macos") a
            # volume in the macOS container, as macOS's own Recovery would be.
            mac = [i for i, x in by_id.items() if kinds.get(x["uuid"]) == "macos"]
            if state.get("root") == "macos" and mac:
                out({"DeviceIdentifier": "disk" + str(10 + int(mac[0].rsplit("s", 1)[1])) + "s3",
                     "APFSContainerReference": "disk" + str(10 + int(mac[0].rsplit("s", 1)[1])),
                     "APFSPhysicalStores": [{"APFSPhysicalStore": mac[0]}]})
            else:
                out({"DeviceIdentifier": "disk20", "Content": "", "Internal": False})
        elif ident in by_id:
            x = by_id[ident]
            out({"DeviceIdentifier": ident, "ParentWholeDisk": "disk0", "DiskUUID": x["uuid"],
                 "Content": TYPES[x["type"]], "PartitionMapPartitionOffset": x["first"] * SS,
                 "Size": (x["last"] + 1 - x["first"]) * SS})
        else:
            die(f"Could not find disk: {ident}")
    elif args[:3] == ["apfs", "list", "-plist"]:
        cs = []
        for ident, x in by_id.items():
            kind = kinds.get(x["uuid"])
            if not kind:
                continue
            vols = []
            for name, role in VOLS[kind]:
                vid = u5("data", x["uuid"]) if role == "Data" else u5(name, x["uuid"])
                vols.append({"APFSVolumeUUID": vid, "Name": name, "Roles": [role]})
            cs.append({"APFSContainerUUID": u5("c", x["uuid"]), "ContainerReference": "disk" + str(
                10 + int(ident.rsplit("s", 1)[1])), "PhysicalStores": [{"DeviceIdentifier": ident}],
                "Volumes": vols})
        out({"Containers": cs})
    elif args[:3] == ["apfs", "listVolumeGroups", "-plist"]:
        groups = []
        for ident, x in by_id.items():
            if kinds.get(x["uuid"]) in ("macos", "stub"):
                groups.append({"APFSVolumeGroupUUID": u5("data", x["uuid"]), "Volumes": [
                    {"DiskUUID": u5("Macintosh HD" if kinds[x["uuid"]] == "macos" else "Aurora",
                                    x["uuid"])}, {"DiskUUID": u5("data", x["uuid"])}]})
        out({"Containers": [{"VolumeGroups": groups}]})
    elif args[:2] == ["apfs", "deleteContainer"]:
        ref = args[2]
        # A container reference (diskN) or the partition's GPT UUID.
        hit = [x for ident, x in by_id.items() if kinds.get(x["uuid"]) and (
            "disk" + str(10 + int(ident.rsplit("s", 1)[1])) == ref or x["uuid"] == ref.upper())]
        if len(hit) != 1 or kinds[hit[0]["uuid"]] != "macos":
            die(f"deleteContainer: {ref} is not the macOS container here")
        target = hit[0]["uuid"]
        store(image, lambda ents, t: [bytes(wd.ENTRY) if e[:16] != wd.ZERO_GUID
                                      and wd.entry_info(e)["uuid"] == target else e for e in ents])
        del kinds[target]
        state.setdefault("log", []).append("deleteContainer " + ref)
        json.dump(state, open(state_path, "w"))
        crash("deleteContainer")
    elif args[:1] == ["addPartition"]:
        pred, kind, size = args[1], args[2], int(args[-1])
        if pred not in by_id or kind not in ADD:
            die(f"addPartition: bad arguments {args}")
        start = (by_id[pred]["last"] + 1) * SS
        nxt = [x["first"] * SS for x in by_id.values() if x["first"] * SS >= start]
        if nxt and start + size > min(nxt):
            die("addPartition: not enough free space after " + pred)
        state["n"] = state.get("n", 0) + 1
        uid = u5("new", str(state["n"]))
        t, _ = table(image)
        store(image, lambda ents, _t: wd.gpt_apply(
            ents, SS, [("add", start, size, ADD[kind], args[3] if kind == "apfs" else "", uid)],
            t["primary"]["first"], t["primary"]["last"]))
        if kind == "apfs":
            kinds[uid] = "stub"
        state.setdefault("log", []).append("addPartition " + kind)
        json.dump(state, open(state_path, "w"))
        crash("addPartition " + kind)
    else:
        die(f"diskutil stand-in: unsupported {args}")
    json.dump(state, open(state_path, "w"))


if __name__ == "__main__":
    main()
