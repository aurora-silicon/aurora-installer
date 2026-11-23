#!/usr/bin/env python3
"""Runs aurora-fresh-install (the Recovery disk stage, built with
-D FRESH_WHOLE_DISK_TEST) against disk images, with fresh_fake_diskutil.py
playing diskutil and newfs_msdos on the J473's factory table.

Checks: the dry run changes nothing; without the typed phrase nothing
changes; a full run lays out iSC/stub/EFI/Boot/Root/System Recovery with the
EFI formatted FAT32 and both images written and verified; the installation
stopped right after every command it runs (and with its journal deleted)
resumes to the same layout; a wrong image digest stops it, and a corrected
run finishes; the image test's Apple-container checks hold throughout.

usage: fresh-install-test.py TOOL GPT WORKDIR   (GPT as for fresh-image-test.py)
"""

import hashlib
import importlib.util
import json
import os
import stat
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fit", os.path.join(HERE, "fresh-image-test.py"))
fit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fit)
wd = fit.wd
SS = fit.SS


def fail(msg):
    print("FAIL:", msg)
    sys.exit(1)


def setup(workdir, name, lba):
    d = os.path.join(workdir, name)
    os.makedirs(d, exist_ok=True)
    disk = fit.Disk(os.path.join(d, "disk.img"), lba)
    state = {"kinds": {}}
    for _, x in disk.entries():
        if x["type"] == wd.ISC:
            state["kinds"][x["uuid"]] = "isc"
        elif x["type"] == wd.RECOVERY:
            state["kinds"][x["uuid"]] = "sfr"
        elif x["uuid"] == disk.macos_uuid:
            state["kinds"][x["uuid"]] = "macos"
    json.dump(state, open(os.path.join(d, "state.json"), "w"))
    tools = os.path.join(d, "tools")
    os.makedirs(tools, exist_ok=True)
    for prog in ("diskutil", "newfs_msdos"):
        p = os.path.join(tools, prog)
        with open(p, "w") as f:
            f.write(f"#!/bin/sh\nexec python3 -I {HERE}/fresh_fake_diskutil.py "
                    f"{disk.path} {d}/state.json {prog} \"$@\"\n")
        os.chmod(p, stat.S_IRWXU)
    images = {}
    for role in ("boot", "root"):
        data, pin = fit.payload(role + ".img", 64 << 20)
        path = os.path.join(d, role + ".img")
        with open(path, "wb") as f:
            f.write(data)
        images[role] = {"source": path, "size": len(data), "sha256": pin}
    req = dict(fit.REQUEST, disk="disk0", espLabel="EFI - AUROR", espVolumeID="0x4f4d5801",
               boot=images["boot"], root=images["root"])
    with open(os.path.join(d, "request.json"), "w") as f:
        json.dump(req, f)
    return d, disk


def install(binary, d, disk, phrase="remove macos and all its data", dry=False, journal=True):
    j = os.path.join(d, "journal.json")
    if not journal and os.path.exists(j):
        os.unlink(j)
    cmd = [binary, "--request", os.path.join(d, "request.json"), "--journal", j,
           "--test-tools", os.path.join(d, "tools"), "--test-image", disk.path]
    if dry:
        cmd.append("--dry-run")
    return subprocess.run(cmd, input=phrase + "\n", capture_output=True, text=True, timeout=600)


def state(d):
    return json.load(open(os.path.join(d, "state.json")))


def set_crash(d, word):
    s = state(d)
    s["crash"] = word
    json.dump(s, open(os.path.join(d, "state.json"), "w"), indent=0)


def check_done(disk, label):
    ents = sorted((x for _, x in disk.entries()), key=lambda x: x["first"])
    types = [fit.TYPES[x["type"]] for x in ents]
    if types != ["Apple_APFS_ISC", "Apple_APFS", "EFI", "Linux Filesystem", "Linux Filesystem",
                 "Apple_APFS_Recovery"]:
        fail(f"{label}: layout {types}")
    for a, b in zip(ents, ents[1:]):
        if a["last"] + 1 != b["first"]:
            fail(f"{label}: gap at LBA {a['last']}")
    raw = disk.table()["entries"]
    for i, x in disk.entries():
        if x["uuid"] in disk.apple and bytes(raw[i]) != disk.apple[x["uuid"]]:
            fail(f"{label}: Apple entry changed")
    if disk.apple_hashes() != disk.apple_marks:
        fail(f"{label}: iSC or System Recovery data changed")
    esp = ents[2]
    boot = disk.pread(esp["first"] * SS, 512)
    if boot[82:90] != b"FAT32   " or boot[510:512] != b"\x55\xaa":
        fail(f"{label}: EFI partition isn't FAT32")
    if boot[67:71] != bytes.fromhex("01584d4f"):
        fail(f"{label}: EFI volume ID {boot[67:71].hex()}")
    for role, x in (("boot", ents[3]), ("root", ents[4])):
        data, pin = fit.payload(role + ".img", 64 << 20)
        if hashlib.sha256(disk.pread(x["first"] * SS, len(data))).hexdigest() != pin:
            fail(f"{label}: {role} contents")
    return [(t, x["first"], x["last"]) for t, x in zip(types, ents)]


def main():
    binary, gpt_path, workdir = sys.argv[1:4]
    lba = fit.table_bytes(gpt_path)
    lines = []

    d, disk = setup(workdir, "full", lba)
    before = disk.pread(0, 8 * SS)
    p = install(binary, d, disk, dry=True)
    if p.returncode or "Dry run" not in p.stdout or disk.pread(0, 8 * SS) != before:
        fail(f"dry run: {p.returncode} {p.stdout} {p.stderr}")
    lines.append("dry run: plan printed, table unchanged")
    p = install(binary, d, disk, phrase="no")
    if p.returncode == 0 or disk.pread(0, 8 * SS) != before or state(d).get("log"):
        fail(f"wrong phrase went ahead: {p.stdout} {p.stderr}")
    lines.append(f"wrong phrase: exit {p.returncode}, no command run, table unchanged")
    p = install(binary, d, disk)
    if p.returncode:
        fail(f"full run exit {p.returncode}: {p.stdout}\n{p.stderr}")
    golden = check_done(disk, "full run")
    commands = state(d)["log"]
    lines.append("full run: " + " | ".join(commands))
    for t, a, b in golden:
        lines.append(f"  {t:22} LBA {a:>9} .. {b:>9}")
    p = install(binary, d, disk)
    if p.returncode or state(d)["log"] != commands:
        fail(f"second run changed something: {state(d)['log']}")
    lines.append("run again on the finished disk: nothing to do, no command run")
    # A finished (or used) disk with no journal: nothing may be formatted or
    # written, and no phrase was asked. Mark root and check it survives.
    root = sorted((x for _, x in disk.entries()), key=lambda x: x["first"])[4]
    disk.pwrite(root["first"] * SS, b"USED ROOT".ljust(SS, b"\0"))
    p = install(binary, d, disk, journal=False, phrase="")
    if p.returncode != 2 or state(d)["log"] != commands or \
            disk.pread(root["first"] * SS, 9) != b"USED ROOT":
        fail(f"finished disk without journal: {p.returncode} {p.stderr}")
    lines.append("finished, used disk with no journal: refused (exit 2), nothing formatted or written")

    # Stop right after each command, then resume (with and without journal).
    words = ["deleteContainer", "addPartition apfs", "addPartition %EFI%",
             "addPartition %Linux%", "newfs_msdos"]
    for word in words:
        for journal in (True, False):
            d, disk = setup(workdir, f"crash-{word.replace(' ', '-').replace('%', '')}-{journal}", lba)
            set_crash(d, word)
            p = install(binary, d, disk)
            if p.returncode == 0:
                fail(f"crash at {word} not seen")
            before_log = list(state(d)["log"])
            p = install(binary, d, disk, journal=journal)
            if not journal and word != "deleteContainer":
                # A partition on the disk that no journal says this
                # installation made is never written: refused, nothing run.
                if p.returncode != 2 or state(d)["log"] != before_log:
                    fail(f"no journal after {word}: {p.returncode} {state(d)['log']} {p.stderr}")
                lines.append(f"stopped right after {word}, journal lost: refused (exit 2), "
                             "no command run")
                continue
            if p.returncode:
                fail(f"resume after {word} (journal={journal}): {p.stdout}\n{p.stderr}")
            got = check_done(disk, f"resume after {word}")
            if got != golden:
                fail(f"resume after {word}: layout differs")
            log = state(d)["log"]
            deletes = [c for c in log if c.startswith("deleteContainer")]
            if len(deletes) != 1:
                fail(f"resume after {word}: macOS deleted {len(deletes)} times")
            lines.append(f"stopped right after {word}, resumed {'with' if journal else 'without'} "
                         f"journal: same layout, macOS deleted once ({len(log)} commands)")

    # macOS's own Recovery lives in the container that would go: refused.
    d, disk = setup(workdir, "from-macos-recovery", lba)
    st = state(d)
    st["root"] = "macos"
    json.dump(st, open(os.path.join(d, "state.json"), "w"))
    before = disk.pread(0, 8 * SS)
    p = install(binary, d, disk)
    if p.returncode != 2 or disk.pread(0, 8 * SS) != before or state(d).get("log"):
        fail(f"run from macOS's Recovery: {p.returncode} {p.stderr}")
    lines.append("run from macOS's own Recovery: refused (exit 2), no command run")

    # A wrong digest stops before the journal marks root as written.
    d, disk = setup(workdir, "bad-digest", lba)
    req = json.load(open(os.path.join(d, "request.json")))
    good = req["root"]["sha256"]
    req["root"]["sha256"] = "0" * 64
    json.dump(req, open(os.path.join(d, "request.json"), "w"))
    p = install(binary, d, disk)
    if p.returncode != 1 or "SHA-256" not in p.stderr:
        fail(f"bad digest: {p.returncode} {p.stderr}")
    j = json.load(open(os.path.join(d, "journal.json")))
    if "root" in j["written"]:
        fail("bad digest marked written")
    req["root"]["sha256"] = good
    json.dump(req, open(os.path.join(d, "request.json"), "w"))
    p = install(binary, d, disk)
    if p.returncode or check_done(disk, "after bad digest") != golden:
        fail(f"retry after bad digest: {p.stderr}")
    lines.append("wrong root.img digest: stopped (exit 1, root not marked written); "
                 "retry with the right pin finished, same layout")

    # A disk that already holds Aurora beside macOS refuses.
    d, disk = setup(workdir, "refuse", lba)
    t = disk.table()
    mac = next(x for _, x in disk.entries() if x["uuid"] == disk.macos_uuid)
    import struct

    def shrink(ents, _t):
        out = []
        for e in ents:
            if e[:16] != wd.ZERO_GUID and wd.entry_info(e)["uuid"] == disk.macos_uuid:
                e = bytearray(e)
                struct.pack_into("<Q", e, 40, mac["last"] - (8 << 30) // SS)
                e = bytes(e)
            out.append(e)
        return out
    disk.edit(shrink)
    disk.edit(lambda ents, _t: wd.gpt_apply(
        ents, SS, [("add", (mac["last"] - (8 << 30) // SS + 1) * SS, 8 << 30, wd.LINUX, "",
                    "36D0EBB8-8585-473E-8ACF-0E63AA658687")],
        t["primary"]["first"], t["primary"]["last"]))
    before = disk.pread(0, 8 * SS)
    p = install(binary, d, disk)
    if p.returncode != 2 or disk.pread(0, 8 * SS) != before or state(d).get("log"):
        fail(f"extra partition: {p.returncode} {p.stderr}")
    lines.append("Linux partition beside macOS: refused (exit 2), no command run")

    for name in os.listdir(workdir):
        for f in ("disk.img", "boot.img", "root.img"):
            q = os.path.join(workdir, name, f)
            if os.path.exists(q):
                os.unlink(q)
    print("\n".join(lines))
    print(f"fresh-install-test: PASS ({len(lines)} lines)")


if __name__ == "__main__":
    main()
