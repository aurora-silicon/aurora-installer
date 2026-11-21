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
                rc = wd.cmd_plan(a, owner=lambda node: {"recovery": True, "account": None,
                                                         "phase": None,
                                                         "problem": "no recovery account"})
            self.assertEqual(rc, 3)
            self.assertIn("macOS can't be removed yet: no recovery account", out.getvalue())
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = wd.cmd_plan(a, owner=lambda node: {"recovery": True, "account": "owner",
                                                         "phase": "finalized", "problem": None})
            self.assertEqual(rc, 0)
            self.assertIn("'/Volumes/Aurora/aura' remove-macos --dry-run", out.getvalue())
            self.assertIn("Owner for future startup changes: owner", out.getvalue())
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
        layout, start, size = wd.claim_plan(gpt, wd.read_chosen(self.chosen), record,
                                            self.inspect)
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


if __name__ == "__main__":
    unittest.main()
