# SPDX-License-Identifier: MIT
# Copyright (c) 2026 The Aurora Silicon Contributors
"""aurora-whole-disk on disk images: unprivileged (a GPT in a regular file
with synthetic APFS containers). The loop-device run with a real btrfs root
is tools/whole-disk/image-test.sh."""
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "tools", "whole-disk"))
sys.path.insert(0, os.path.join(HERE, "..", "tools", "wifi-firmware"))
import apfs_ro  # noqa: E402
import aurora_whole_disk as wd  # noqa: E402
import whole_disk_fixtures as fx  # noqa: E402

MIB = 1 << 20


class Slice:
    """A partition of an image file, for apfs_ro.Device."""

    def __init__(self, path, start):
        self.path, self.start = path, start

    def pread(self, n, off):
        with open(self.path, "rb") as f:
            f.seek(self.start + off)
            return f.read(n)


@unittest.skipUnless(shutil.which("sfdisk"), "needs sfdisk")
class WholeDiskImage(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.img = os.path.join(self.dir, "disk.img")
        with open(self.img, "wb") as f:
            f.truncate(15 << 30)
        subprocess.run(["sfdisk", "--quiet", self.img], input=fx.sfdisk_script(512),
                       text=True, check=True)
        self.gpt = wd.read_gpt(self.img)
        self.byname = {p["name"]: p for p in self.gpt["parts"]}
        with open(self.img, "r+b") as f:
            for name, vols in fx.CONTENTS.items():
                f.seek(self.byname[name]["start"])
                f.write(fx.container(vols))
        self.chosen = os.path.join(self.dir, "chosen")
        os.mkdir(self.chosen)
        for k, v in {"asahi,efi-system-partition": self.byname["esp"]["uuid"].lower(),
                     "apfs-preboot-uuid": fx.STUB_GROUP.upper(),
                     "asahi,system-fw-version": "26.6.2", "asahi,os-fw-version": "13.5",
                     "asahi,iboot1-version": "mBoot-18000.161.10"}.items():
            with open(os.path.join(self.chosen, k), "wb") as f:
                f.write(v.encode() + b"\0")

    def tearDown(self):
        shutil.rmtree(self.dir)

    def inspect(self, node):
        p = next(p for p in self.gpt["parts"] if p["node"] == node)
        c = apfs_ro.Container(Slice(self.img, p["start"]))
        return [{"name": v.name, "role": v.role, "group": v.group.upper(),
                 "encrypted": v.encrypted} for v in c.volumes()]

    def test_classify_finds_macos_and_own_container(self):
        layout = wd.classify(self.gpt, wd.read_chosen(self.chosen), self.inspect)
        self.assertEqual(layout["macos"]["uuid"], self.byname["macos"]["uuid"])
        self.assertEqual(layout["own"]["uuid"], self.byname["stub"]["uuid"])
        self.assertEqual(wd.system_name(layout["macos"]), "Macintosh HD")
        self.assertEqual(layout["others"], [])

    def test_plan_text_lists_deleted_and_kept(self):
        chosen = wd.read_chosen(self.chosen)
        layout = wd.classify(self.gpt, chosen, self.inspect)
        text = wd.plan_text(self.gpt, chosen, layout)
        self.assertIn("RECOVERY WOULD DELETE", text)
        self.assertIn("“Macintosh HD”", text)
        self.assertIn("every volume in it:", text)
        for vol in ("“Data” (Data)", "“Update” (Update)", "“VM” (VM)", "“Preboot” (Preboot)"):
            self.assertIn(vol, text)
        for kept in ("Apple system container", "Aurora startup container “Aurora”",
                     "Aurora EFI partition", "Apple System Recovery", "26.6.2"):
            self.assertIn(kept, text)

    def test_plan_refuses_without_owner(self):
        a = types.SimpleNamespace(chosen=self.chosen, disk=self.img)
        orig = wd.container_info
        wd.container_info = self.inspect
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = wd.cmd_plan(a, owner=lambda node, group: {"recovery": True, "account": None,
                                                         "phase": None,
                                                         "problem": "no recovery account"})
            self.assertEqual(rc, 3)
            self.assertIn("macOS can't be removed yet: no recovery account", out.getvalue())
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = wd.cmd_plan(a, owner=lambda node, group: {"recovery": True, "account": "owner",
                                                         "phase": "finalized", "problem": None})
            self.assertEqual(rc, 0)
            self.assertIn("'/Volumes/Aurora/aura' remove-macos --dry-run", out.getvalue())
            self.assertIn("Owner for future startup changes: owner", out.getvalue())
            self.assertIn("Utilities → Remove macOS…", out.getvalue())
        finally:
            wd.container_info = orig

    def test_real_owner_state_on_synthetic_stub_refuses(self):
        # The synthetic stub has no file tree: no Aurora Recovery, so no.
        state = wd.owner_state(Slice(self.img, self.byname["stub"]["start"]))
        self.assertFalse(state["recovery"])
        self.assertTrue(state["problem"])

    def remove_macos(self):
        """What Recovery's deleteContainer leaves: no macOS partition, the
        removal record Recovery writes (MacOSRemoval.claimRecord)."""
        m = self.byname["macos"]
        n = m["node"][len(self.img):]
        subprocess.run(["sfdisk", "--quiet", "--delete", self.img, n], check=True)
        isc = self.byname["isc"]
        record = {"schema": 1, "phase": "removed", "removedPartitionUUID": m["uuid"],
                  "removedContainerUUID": "22222222-2222-4222-8222-222222222222",
                  "removedOffset": m["start"], "removedSize": m["size"],
                  "freeOffset": isc["start"] + isc["size"],
                  "freeSize": self.byname["stub"]["start"] - isc["start"] - isc["size"],
                  "installationStoreUUID": self.byname["stub"]["uuid"],
                  "espUUID": self.byname["esp"]["uuid"], "removedAt": "2026-11-21T00:00:00Z"}
        return record

    def test_claim_plan_after_removal(self):
        record = self.remove_macos()
        gpt = wd.read_gpt(self.img)
        self.gpt = gpt
        layout, start, size, resume = wd.claim_plan(gpt, wd.read_chosen(self.chosen), record,
                                                    self.inspect)
        self.assertIsNone(resume)
        self.assertIsNone(layout["macos"])
        self.assertEqual(start, self.byname["macos"]["start"])
        self.assertEqual(size, self.byname["macos"]["size"])

    def test_claim_refusals(self):
        chosen = wd.read_chosen(self.chosen)
        record = self.remove_macos()
        gpt = wd.read_gpt(self.img)
        self.gpt = gpt
        for change, text in [({"phase": "removing"}, "not one this tool knows"),
                             ({"espUUID": self.byname["boot"]["uuid"]}, "another installation"),
                             ({"removedPartitionUUID": self.byname["root"]["uuid"]},
                              "still on the disk"),
                             ({"installationStoreUUID": self.byname["root"]["uuid"]},
                              "another startup container"),
                             ({"freeOffset": self.byname["stub"]["start"]}, "no longer free")]:
            with self.subTest(change=change):
                with self.assertRaisesRegex(wd.Refusal, text):
                    wd.claim_plan(gpt, chosen, dict(record, **change), self.inspect)

    def test_claim_resumes_after_partition_added(self):
        """A claim that stopped after sfdisk --append finishes on the same
        partition; anything else over the range refuses."""
        chosen = wd.read_chosen(self.chosen)
        record = self.remove_macos()
        gpt = wd.read_gpt(self.img)
        self.gpt = gpt
        _, start, size, _ = wd.claim_plan(gpt, chosen, record, self.inspect)
        spec = (f"start={start // 512}, size={size // 512}, type={wd.LINUX}, "
                f"name=\"{wd.CLAIM_NAME}\"\n")
        subprocess.run(["sfdisk", "--quiet", "--append", self.img], input=spec, text=True,
                       check=True)
        self.gpt = wd.read_gpt(self.img)
        _, _, _, resume = wd.claim_plan(self.gpt, chosen, record, self.inspect)
        self.assertEqual((resume["start"], resume["size"]), (start, size))
        other = json.loads(json.dumps(self.gpt))
        for p in other["parts"]:
            if p["start"] == start:
                p["name"] = "someone else's"
        with self.assertRaisesRegex(wd.Refusal, "no longer free"):
            wd.claim_plan(other, chosen, record, self.inspect)

    def test_malformed_records_refuse(self):
        chosen = wd.read_chosen(self.chosen)
        record = self.remove_macos()
        gpt = wd.read_gpt(self.img)
        self.gpt = gpt
        for key in ("espUUID", "freeOffset", "installationStoreUUID", "removedPartitionUUID"):
            with self.subTest(missing=key):
                broken = {k: v for k, v in record.items() if k != key}
                with self.assertRaisesRegex(wd.Refusal, "incomplete"):
                    wd.claim_plan(gpt, chosen, broken, self.inspect)
        with self.assertRaisesRegex(wd.Refusal, "incomplete"):
            wd.claim_plan(gpt, chosen, dict(record, freeSize="lots"), self.inspect)
        with self.assertRaisesRegex(wd.Refusal, "not one this tool knows"):
            wd.claim_plan(gpt, chosen, ["schema", 1], self.inspect)
        bad = os.path.join(self.dir, "removed.json")
        with open(bad, "w") as f:
            f.write("{not json")
        with self.assertRaisesRegex(wd.Refusal, "unreadable"):
            wd.read_record(bad)

    def test_macos_container_with_extra_volumes_refuses(self):
        chosen = wd.read_chosen(self.chosen)
        for extra, text in [([("Photos", "None", None, False)], "“Photos”.*isn't part of macOS"),
                            ([("Macintosh HD 2", "System", "99999999-9999-4999-8999-999999999999", False)],
                             "2 System volumes"),
                            ([("VM 2", "VM", None, False)], "more than one VM volume")]:
            with self.subTest(extra=extra[0][0]):
                with open(self.img, "r+b") as f:
                    f.seek(self.byname["macos"]["start"])
                    f.write(fx.container(fx.MAC_VOLUMES + extra))
                with self.assertRaisesRegex(wd.Refusal, "holds macOS together with something "
                                            "else: .*" + text):
                    wd.classify(self.gpt, chosen, self.inspect)

    def test_duplicate_apple_containers_refuse(self):
        chosen = wd.read_chosen(self.chosen)
        two = json.loads(json.dumps(self.gpt))
        for p in two["parts"]:
            if p["name"] == "boot":
                p["type"] = wd.RECOVERY
        with self.assertRaisesRegex(wd.Refusal, "more than one Apple system or Recovery"):
            wd.classify(two, chosen, self.inspect)
        dup = json.loads(json.dumps(self.gpt))
        dup["parts"][4]["uuid"] = dup["parts"][5]["uuid"]
        with self.assertRaisesRegex(wd.Refusal, "share a UUID"):
            wd.classify(dup, chosen, self.inspect)

    def test_owner_needs_finalized_account_of_this_group(self):
        group = wd.norm(fx.STUB_GROUP)

        def pointer(phase, grp=fx.STUB_GROUP):
            return json.dumps({"username": "owner", "phase": phase,
                               "target": {"groupUUID": grp}}).encode()
        self.assertIsNone(wd.owner_problem(True, pointer("finalized"), group)["problem"])
        for phase, text in [("allocating", "wasn't finished"), ("creating", "wasn't finished"),
                            ("prepared", "Startup Disk"), ("awaiting-ownership", "Startup Disk"),
                            ("odd", "unknown state")]:
            with self.subTest(phase=phase):
                self.assertIn(text, wd.owner_problem(True, pointer(phase), group)["problem"])
        other = pointer("finalized", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
        self.assertIn("another installation", wd.owner_problem(True, other, group)["problem"])
        self.assertIn("unreadable", wd.owner_problem(True, b"{oops", group)["problem"])
        self.assertIn("unreadable", wd.owner_problem(True, b"[1]", group)["problem"])
        self.assertIn("no recovery account", wd.owner_problem(True, None, group)["problem"])
        self.assertIn("no Aurora Recovery", wd.owner_problem(False, pointer("finalized"),
                                                             group)["problem"])

    def test_no_macos_and_two_macos(self):
        chosen = wd.read_chosen(self.chosen)
        two = json.loads(json.dumps(self.gpt))
        # A second full macOS in what was the boot partition: ambiguous, refused.
        with open(self.img, "r+b") as f:
            f.seek(self.byname["boot"]["start"])
            f.write(fx.container(fx.MAC_VOLUMES))
        for p in two["parts"]:
            if p["name"] == "boot":
                p["type"] = wd.APFS
        with self.assertRaisesRegex(wd.Refusal, "2 macOS installations"):
            wd.classify(two, chosen, self.inspect)
        self.remove_macos()
        self.gpt = wd.read_gpt(self.img)
        self.assertIsNone(wd.classify(self.gpt, chosen, self.inspect)["macos"])

    def test_layout_refusals(self):
        chosen = wd.read_chosen(self.chosen)
        bad_first = json.loads(json.dumps(self.gpt))
        bad_first["parts"][0]["type"] = wd.APFS
        with self.assertRaisesRegex(wd.Refusal, "iSC container first"):
            wd.classify(bad_first, chosen, self.inspect)
        no_last = json.loads(json.dumps(self.gpt))
        no_last["parts"].pop()
        with self.assertRaisesRegex(wd.Refusal, "System Recovery last"):
            wd.classify(no_last, chosen, self.inspect)
        other = dict(wd.read_chosen(self.chosen), group="AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
        with self.assertRaisesRegex(wd.Refusal, "startup container isn't on this disk"):
            wd.classify(self.gpt, other, self.inspect)
        other = dict(wd.read_chosen(self.chosen), esp=self.byname["boot"]["uuid"])
        with self.assertRaisesRegex(wd.Refusal, "EFI partition isn't on this disk"):
            wd.classify(self.gpt, other, self.inspect)

    def test_chosen_required(self):
        with self.assertRaisesRegex(wd.Refusal, "device tree"):
            wd.read_chosen(os.path.join(self.dir, "none"))


U = {"isc": "11111111-0000-4000-8000-000000000001", "macos": "11111111-0000-4000-8000-000000000002",
     "stub": "11111111-0000-4000-8000-000000000003", "esp": "11111111-0000-4000-8000-000000000004",
     "boot": "11111111-0000-4000-8000-000000000005", "root": "11111111-0000-4000-8000-000000000006",
     "recovery": "11111111-0000-4000-8000-000000000007", "new": "11111111-0000-4000-8000-000000000008",
     "swap": "11111111-0000-4000-8000-000000000009"}
NR = {"isc": 1, "macos": 2, "stub": 3, "esp": 4, "boot": 5, "root": 6, "recovery": 7, "new": 2,
      "swap": 8}
TYPE = dict((n, t) for n, t, _ in fx.LAYOUT)
TYPE.update(new=wd.LINUX, swap="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F")


class V2Planner(unittest.TestCase):
    """The one-root-partition claim's decisions on partition tables as data:
    each stage a stopped claim can leave, and the refusals."""

    def setUp(self):
        # fx.LAYOUT after Recovery removed macOS, in MiB: name -> (start, size).
        self.rows, at = {}, 1
        for name, _, mib in fx.LAYOUT:
            if name != "macos":
                self.rows[name] = (at, mib)
            at += mib
        self.chosen = {"esp": wd.norm(U["esp"]), "group": wd.norm(fx.STUB_GROUP)}
        self.record = {"schema": 1, "phase": "removed", "removedPartitionUUID": U["macos"],
                       "freeOffset": 513 * MIB, "freeSize": 6144 * MIB,
                       "installationStoreUUID": U["stub"], "espUUID": U["esp"]}

    def gpt(self, rows=None, unit=MIB):
        parts = []
        for name, (start, size) in (rows or self.rows).items():
            parts.append({"node": f"/dev/d{NR[name]}", "start": start * unit, "size": size * unit,
                          "type": TYPE[name].upper(), "uuid": wd.norm(U[name]),
                          "name": wd.CLAIM_NAME if name == "new" else name, "attrs": ""})
        parts.sort(key=lambda p: p["start"])
        return {"disk": "/dev/d", "sector": 4096, "first": MIB, "last": 15 << 30, "parts": parts}

    def inspect(self, node):
        vols = {"/dev/d1": fx.ISC_VOLUMES, "/dev/d3": fx.STUB_VOLUMES, "/dev/d7": fx.RECOVERY_VOLUMES}
        return [{"name": n, "role": fx.ROLE[r], "group": (g or "0" * 8 + "-0000-0000-0000-" + "0" * 12)
                 .upper(), "encrypted": e} for n, r, g, e in vols[node]]

    def stage(self, rows=None, v2=None, devs=("/dev/d6",), record=None):
        return wd.v2_stage(self.gpt(rows), self.chosen, record or self.record, v2, devs, self.inspect)

    def test_plan_packs_partitions_after_isc(self):
        st = self.stage()
        self.assertEqual((st["stage"], st["next"]), ("initial", "stub"))
        plan = st["plan"]
        self.assertEqual({k: (m["from"] // MIB, m["to"] // MIB) for k, m in plan["moves"].items()},
                         {"stub": (6657, 513), "esp": (7681, 1537), "boot": (8193, 2049)})
        self.assertEqual(plan["newRoot"], {"start": 3073 * MIB, "size": 6144 * MIB})
        self.assertEqual(plan["root"], {"uuid": wd.norm(U["root"]), "name": "root",
                                        "start": 9217 * MIB, "end": 13313 * MIB})

    def walk(self, migrate=True):
        """Every state a claim passes through, with the stage it must give."""
        plan = self.stage()["plan"]
        v2 = dict(self.record, phase="moving-stub", v2=plan, migrate=migrate)
        rows = dict(self.rows)
        out = []
        for k in wd.MOVED:
            rows[k] = (plan["moves"][k]["to"] // MIB, rows[k][1])
            out.append((dict(rows), ("/dev/d6",)))
        rows["new"] = (3073, 6144)
        out.append((dict(rows), ("/dev/d6",)))
        out.append((dict(rows), ("/dev/d6", "/dev/d2")))
        if migrate:
            out.append((dict(rows), ("/dev/d2",)))
            del rows["root"]
            rows["new"] = (3073, 6144 + 4096)
            merged = dict(rows)
            out.append((merged, ("/dev/d2",)))
        return plan, v2, out

    def test_each_stopped_state_continues(self):
        plan, v2, states = self.walk()
        want = ["move", "move", "root-create", "root-add", "root-remove", "root-merge",
                "root-resize"]
        got = []
        for rows, devs in states:
            if "new" in rows and "root" not in rows:
                # The merged entry has the old root's GPT UUID and name.
                gpt = self.gpt(rows)
                for p in gpt["parts"]:
                    if p["node"] == "/dev/d2":
                        p["uuid"], p["name"] = wd.norm(U["root"]), "root"
                st = wd.v2_stage(gpt, self.chosen, self.record, v2, devs, self.inspect)
            else:
                st = self.stage(rows, v2, devs)
            got.append(st["stage"])
        self.assertEqual(got, want)
        self.assertEqual(self.stage(states[0][0], v2)["next"], "esp")
        self.assertEqual(self.stage(states[1][0], v2)["next"], "boot")

    def test_root_kept_on_two_devices_finishes_without_migrating(self):
        _, v2, states = self.walk(migrate=False)
        rows, devs = states[-1]
        self.assertEqual(self.stage(rows, v2, devs)["stage"], "finish")
        with self.assertRaisesRegex(wd.Refusal, "devices aren't the ones"):
            self.stage(rows, v2, ("/dev/d2",))

    def test_initial_with_record_of_a_stopped_copy(self):
        plan = self.stage()["plan"]
        v2 = dict(self.record, phase="moving-stub", v2=plan)
        self.assertEqual(self.stage(v2=v2)["stage"], "initial")
        other = json.loads(json.dumps(plan))
        other["moves"]["stub"]["to"] += MIB
        with self.assertRaisesRegex(wd.Refusal, "another plan"):
            self.stage(v2=dict(v2, v2=other))

    def test_moved_state_needs_matching_record(self):
        plan, v2, states = self.walk()
        rows = states[0][0]
        with self.assertRaisesRegex(wd.Refusal, "no claim record"):
            self.stage(rows)
        bad = json.loads(json.dumps(v2))
        bad["v2"]["moves"]["esp"]["from"] += MIB
        with self.assertRaisesRegex(wd.Refusal, "EFI partition isn't where claimed.json says"):
            self.stage(rows, bad)
        out_of_order = dict(self.rows, esp=(1537, 512))
        with self.assertRaisesRegex(wd.Refusal, "aren't where a claim|isn't the first"):
            self.stage(out_of_order, v2)
        strange = dict(rows, root=(9217, 4000))
        with self.assertRaisesRegex(wd.Refusal, "root partition changed"):
            self.stage(strange, v2)

    def test_refusals_before_anything_moves(self):
        cases = [
            # The hole after the stub, not before it, with no claim that moved it.
            (dict(self.rows, stub=(513, 1024)), {"freeOffset": 1537 * MIB, "freeSize": 6144 * MIB},
             ("/dev/d6",), "no claim record"),
            # Recovery's record names other space than the hole before the stub.
            (self.rows, {"freeOffset": 9217 * MIB}, ("/dev/d6",),
             "directly before the startup container"),
            # Another partition between /boot and root.
            (dict(self.rows, swap=(9217, 1024), root=(10241, 3072)), {}, ("/dev/d6",),
             "has 5 partitions|aren't Linux"),
            # A gap between ESP and /boot.
            (dict(self.rows, boot=(8200, 1017)), {}, ("/dev/d6",), "next to each other"),
            # The root on two devices already.
            (self.rows, {}, ("/dev/d6", "/dev/d9"), "exactly one partition"),
            # /boot is part of the root file system.
            (self.rows, {}, ("/dev/d6", "/dev/d5"), "separate /boot"),
        ]
        for rows, change, devs, text in cases:
            with self.subTest(text=text):
                with self.assertRaisesRegex(wd.Refusal, text):
                    self.stage(rows, None, devs, dict(self.record, **change))

    def test_stub_bigger_than_hole_refuses(self):
        rows = {"isc": (1, 512), "stub": (1537, 2048), "esp": (3585, 512), "boot": (4097, 1024),
                "root": (5121, 4096), "recovery": (9217, 1024)}
        record = dict(self.record, freeSize=1024 * MIB)
        with self.assertRaisesRegex(wd.Refusal, "overlap"):
            self.stage(rows, None, ("/dev/d6",), record)

    def test_real_m2_offsets(self):
        """The lab M2's table (4096-byte sectors, iSC ending off a MiB
        boundary): targets are 1 MiB aligned and nothing overlaps."""
        s = 4096
        rows = {"isc": (6, 128000), "stub": (44100394, 610304), "esp": (44710698, 128000),
                "boot": (44838698, 262144), "root": (45100842, 14867712),
                "recovery": (59968630, 1310709)}
        record = dict(self.record, freeOffset=128006 * s, freeSize=(44100394 - 128006) * s)
        gpt = self.gpt(rows, unit=s)
        st = wd.v2_stage(gpt, self.chosen, record, None, ("/dev/d6",), self.inspect)
        moves = st["plan"]["moves"]
        self.assertTrue(all(m["to"] % MIB == 0 for m in moves.values()))
        self.assertEqual(moves["stub"]["to"], 501 * MIB)  # 128006 sectors rounded up
        self.assertEqual(st["plan"]["root"]["end"], (45100842 + 14867712) * s)
        self.assertEqual(st["plan"]["newRoot"]["start"],
                         wd.align_up(moves["boot"]["to"] + 262144 * s))

    def test_gpt_script_changes_only_named_entries(self):
        dump = ("label: gpt\nlabel-id: 3865F65C-AB41-466F-895F-491BB3AD52EF\ndevice: /dev/d\n"
                "unit: sectors\nfirst-lba: 256\nlast-lba: 262138\nsector-size: 4096\n\n"
                f"/dev/d2 : start=        3000, size=        1000, type={wd.LINUX}, "
                f"uuid={U['new']}, name=\"{wd.CLAIM_NAME}\"\n"
                f"/dev/d5 : start=         256, size=        2560, type={wd.LINUX}, "
                f"uuid={U['boot']}, name=\"boot, the one\", attrs=\"GUID:63\"\n"
                f"/dev/d6 : start=        4000, size=        2560, type={wd.LINUX}, "
                f"uuid={U['root']}, name=\"root\"\n")
        out = wd.gpt_script(dump, 4096, {
            wd.norm(U["root"]): None,
            wd.norm(U["new"]): {"uuid": wd.norm(U["root"]), "name": "root", "attrs": "",
                                "size": 3560 * 4096}})
        lines = out.splitlines()
        self.assertIn("first-lba: 256", lines)
        self.assertIn(f"/dev/d5 : start=         256, size=        2560, type={wd.LINUX}, "
                      f"uuid={U['boot']}, name=\"boot, the one\", attrs=\"GUID:63\"", lines)
        self.assertIn(f"/dev/d2 : start=3000, size=3560, type={wd.LINUX}, "
                      f"uuid={wd.norm(U['root'])}, name=\"root\"", lines)
        self.assertFalse(any(line.startswith("/dev/d6") for line in lines))
        with self.assertRaisesRegex(wd.Refusal, "changed while"):
            wd.gpt_script(dump, 4096, {wd.norm(U["esp"]): None})
        with self.assertRaisesRegex(wd.Refusal, "sector boundary"):
            wd.gpt_script(dump, 4096, {wd.norm(U["new"]): {"start": 4097}})

    def test_root_references(self):
        part = {"uuid": wd.norm(U["root"]), "name": "root", "node": "/dev/nvme0n1p6"}
        fs = "UUID=45d65ea5-9879-4d4a-9724-32ad24eed778 / btrfs subvol=root 0 0\n"
        self.assertEqual(wd.root_references([("/etc/fstab", fs),
                                             ("/proc/cmdline", "root=UUID=45d6 ro rhgb")], part), [])
        for text in (f"root=PARTUUID={U['root']} rw", "PARTLABEL=root / btrfs defaults 0 0",
                     'PARTLABEL="root" / btrfs', "root=/dev/nvme0n1p6",
                     f"/dev/disk/by-partuuid/{U['root']} / btrfs"):
            with self.subTest(text=text):
                self.assertTrue(wd.root_references([("f", text)], part))
        self.assertEqual(wd.root_references([("f", "root=/dev/nvme0n1p60 PARTLABEL=rootfs")],
                                            part), [])

    def test_root_fits(self):
        self.assertTrue(wd.root_fits(4 << 30, 6 << 30))
        self.assertFalse(wd.root_fits(int(5.5 * (1 << 30)), 6 << 30))

    def test_move_gate(self):
        self.assertTrue(wd.move_gate(self.gpt(), self.chosen))
        plan, v2, states = self.walk()
        self.assertTrue(wd.move_gate(self.gpt(states[0][0]), self.chosen))
        self.assertTrue(wd.move_gate(self.gpt(states[1][0]), self.chosen))
        self.assertFalse(wd.move_gate(self.gpt(states[2][0]), self.chosen))
        with_macos = dict(self.rows, macos=(513, 6144))
        self.assertFalse(wd.move_gate(self.gpt(with_macos), self.chosen))


if __name__ == "__main__":
    unittest.main()
